// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Immutable native ETH fee jar that makes Sherwood BUY moves and burns the output.
/// @dev Only the three enabled hook callbacks are implemented. No owner, approvals or upgrades.
contract SherwoodPlayerHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    error NotPoolManager();
    error NotSelf();
    error InvalidConfiguration();
    error WrongPool();
    error Busy();
    error PartialFill();
    error InvalidBuyback();

    uint256 public constant THRESHOLD = 0.005 ether;
    uint256 public constant FEE_DENOMINATOR = 100;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant SHERWOOD = 0xc33c907127b94303F578d6Be551C36F45939e0cC;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    // Bound external game execution so a failing game cannot exhaust the parent swap's gas.
    uint256 public constant BUYBACK_GAS = 2_000_000;
    uint256 public constant GAS_RESERVE = 150_000;

    IPoolManager public immutable poolManager;
    address public immutable token;
    PoolId public immutable poolId;
    bool private busy;

    event FeeCollected(uint256 amount, bool deferred);
    event FeesRedeemed(uint256 amount);
    event BuybackSucceeded(address indexed player, uint256 ethSpent, uint256 imdBurned);
    event BuybackFailed(address indexed player, uint256 ethAttempted);
    event BuybackDeferred(address indexed player, uint256 ethHeld);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0) || token_ == IMD) {
            revert InvalidConfiguration();
        }
        poolManager = manager_;
        token = token_;
        poolId = PoolKey(
                Currency.wrap(address(0)), Currency.wrap(token_), POOL_FEE, TICK_SPACING, IHooks(address(this))
            )
            .toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (busy) revert Busy();
        _redeem();
        // Native ETH is always currency0. It is specified on exact-input buys and exact-output sells.
        bool nativeSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 fee;
        if (nativeSpecified) {
            fee = _fee(_specified(params), params.amountSpecified < 0);
            // The specified delta is signed int128 in v4. Bound before narrowing.
            if (fee > uint256(uint128(type(int128).max))) revert InvalidConfiguration();
            _collect(fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        if (busy) revert Busy();
        bool nativeSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 fee;
        if (nativeSpecified) {
            // A specified fee was reserved before the trade. Refuse partial native fills rather
            // than taxing an unexecuted budget. Unspecified native fills are charged on actual ETH.
            uint256 reserved = _fee(_specified(params), params.amountSpecified < 0);
            int256 expected = params.amountSpecified + int256(reserved);
            if (int256(delta.amount0()) != expected) revert PartialFill();
        } else {
            int128 ethDelta = delta.amount0();
            uint256 amount = ethDelta < 0 ? uint256(-int256(ethDelta)) : uint256(int256(ethDelta));
            fee = _fee(amount, params.amountSpecified < 0);
            _collect(fee);
        }
        _attemptBuyback();
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @notice Anyone may realize deferred ETH claims into the jar, without choosing a player.
    /// @dev Buybacks only happen in swap callbacks, so this cannot steal a triggering swap's move.
    function redeemFees() external {
        if (busy) revert Busy();
        busy = true;
        poolManager.unlock("");
        busy = false;
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (!busy) revert Busy();
        _redeem();
        return "";
    }

    /// @dev External self-call is a rollback boundary around ALL game, settlement and burn effects.
    /// Called while the manager is already unlocked; never nests unlock().
    function executeBuyback(uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (!busy || amount < THRESHOLD || amount != address(this).balance) revert InvalidBuyback();
        // Prepay: Sherwood's beforeSwap takes its pot fee before the swap router settles.
        // _attemptBuyback only gets here with no currency synced, so this reset clears nothing.
        poolManager.sync(Currency.wrap(address(0)));
        poolManager.settle{value: amount}();
        BalanceDelta delta = poolManager.swap(
            sherwoodPool(),
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            "" // Sherwood v2 defaults to BUY and attributes the move to tx.origin.
        );
        if (int256(delta.amount0()) != -int256(amount) || delta.amount1() <= 0) revert InvalidBuyback();
        uint256 output = uint256(uint128(delta.amount1()));
        poolManager.take(Currency.wrap(IMD), BURN, output);
        emit BuybackSucceeded(tx.origin, amount, output);
    }

    function sherwoodPool() public pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 9000, 180, IHooks(SHERWOOD));
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _specified(SwapParams calldata params) private pure returns (uint256) {
        return params.amountSpecified < 0 ? uint256(-(params.amountSpecified + 1)) + 1 : uint256(params.amountSpecified);
    }

    /// @dev The fee is 1% of the gross ETH leg in every swap mode. On exact input the ETH amount
    /// is already gross; on exact output it excludes the fee, so gross up: fee = amount / 99 makes
    /// fee == (amount + fee) / 100 exactly under floor division.
    function _fee(uint256 ethAmount, bool exactInput) private pure returns (uint256) {
        return exactInput ? ethAmount / FEE_DENOMINATOR : ethAmount / (FEE_DENOMINATOR - 1);
    }

    function _collect(uint256 fee) private {
        if (fee == 0) return;
        bool deferred = address(poolManager).balance < fee;
        if (deferred) poolManager.mint(address(this), 0, fee);
        else poolManager.take(Currency.wrap(address(0)), address(this), fee);
        emit FeeCollected(fee, deferred);
    }

    function _redeem() private {
        uint256 amount = poolManager.balanceOf(address(this), 0);
        uint256 available = address(poolManager).balance;
        if (amount > available) amount = available;
        if (amount == 0) return;
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        emit FeesRedeemed(amount);
    }

    function _attemptBuyback() private {
        uint256 amount = address(this).balance;
        if (amount < THRESHOLD || gasleft() <= GAS_RESERVE) return;
        // The prepayment below needs the manager's single synced-currency slot. A router that
        // synced its ERC-20 input before this swap and settles after it would lose that sync, so
        // its unlock would revert CurrencyNotSettled. Leave the jar alone and retry on a later swap.
        if (!poolManager.getSyncedCurrency().isAddressZero()) {
            emit BuybackDeferred(tx.origin, amount);
            return;
        }
        busy = true;
        bytes memory payload = abi.encodeCall(this.executeBuyback, (amount));
        bool ok;
        // Discard untrusted revert data to prevent a return-data memory bomb.
        uint256 budget = gasleft() - GAS_RESERVE;
        if (budget > BUYBACK_GAS) budget = BUYBACK_GAS;
        assembly ("memory-safe") {
            ok := call(budget, address(), 0, add(payload, 32), mload(payload), 0, 0)
        }
        busy = false;
        if (!ok) emit BuybackFailed(tx.origin, amount);
    }

    receive() external payable {}
}

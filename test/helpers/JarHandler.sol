// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SherwoodPlayerHook} from "src/SherwoodPlayerHook.sol";
import {Quiver} from "src/Quiver.sol";
import {MockSherwood} from "./MockSherwood.sol";
import {PoolDriver} from "./PoolDriver.sol";
import {SettlementProbe} from "./SettlementProbe.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Makes fully backed native ERC-6909 donations, without editing manager storage/balances.
contract ClaimDonor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(address recipient) external payable {
        manager.unlock(abi.encode(recipient, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(Currency.wrap(address(0)));
        manager.settle{value: amount}();
        manager.mint(recipient, 0, amount);
        require(manager.getNonzeroDeltaCount() == 0, "unbacked donation");
        return "";
    }
}

/// @dev Each router represents a separately funded trader. Native donations use a
/// finite initial balance; no deal/storage edits occur during random sequences.
contract JarHandler is Test {
    using PoolIdLibrary for PoolKey;

    SherwoodPlayerHook public immutable hook;
    IPoolManager public immutable manager;
    MockSherwood public immutable game;
    Quiver public immutable imd;
    PoolDriver public immutable liquidityProvider;
    ClaimDonor public immutable donor;
    SettlementProbe[3] public routers;
    address[3] public actors;
    PoolKey private key;

    uint256 public totalFees;
    uint256 public totalDonations;
    uint256 public totalSpent;
    uint256 public totalBurned;
    uint256 public successfulBuys;
    uint256 public failedBuys;
    uint256 public trades;
    uint256 public redemptions;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    constructor(
        SherwoodPlayerHook hook_,
        MockSherwood game_,
        PoolDriver provider_,
        PoolKey memory key_,
        SettlementProbe[3] memory routers_,
        address[3] memory actors_
    ) {
        hook = hook_;
        manager = hook_.poolManager();
        game = game_;
        imd = Quiver(hook_.IMD());
        liquidityProvider = provider_;
        key = key_;
        routers = routers_;
        actors = actors_;
        donor = new ClaimDonor(manager);
    }

    function trade(uint8 who, bool buy, bool exactInput, uint96 raw, uint8 rawMode) external {
        uint256 amount = bound(raw, 100, 0.75 ether);
        uint256 mode = bound(rawMode, 0, 3);
        // Exercise both early failures and failures after the pot payment and AMM swap.
        game.setMode(mode == 0 ? 0 : mode == 1 ? 1 : mode == 2 ? 5 : 6);
        uint256 previousPlays = game.plays();
        uint256 previousBurn = imd.balanceOf(hook.BURN());
        uint256 previousGameETH = address(game).balance;
        uint256 assetsBefore = address(hook).balance + manager.balanceOf(address(hook), 0);
        uint256 index = uint256(who) % 3;
        SwapParams[] memory params = new SwapParams[](1);
        params[0] = SwapParams(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.recordLogs();
        vm.prank(actors[index], actors[index]);
        BalanceDelta[] memory results = routers[index].batch(key, params, true, false);
        int128 poolETH = _executedETH(vm.getRecordedLogs());
        uint256 basis = buy == exactInput ? amount : _abs(poolETH);
        uint256 fee = basis / 100;
        assertEq(int256(poolETH) - int256(results[0].amount0()), int256(fee), "wrong native fee");
        totalFees += fee;
        ++trades;

        uint256 available = assetsBefore + fee;
        if (available >= 0.005 ether && mode == 0) {
            assertEq(game.plays(), previousPlays + 1, "eligible buy must execute");
            assertEq(game.player(), actors[index], "tipping trader must be credited");
            assertEq(game.declared(), available, "buy must spend the entire jar");
            uint256 burned = imd.balanceOf(hook.BURN()) - previousBurn;
            assertGt(burned, 0, "successful buy must burn actual output");
            assertEq(address(hook).balance, 0);
            totalSpent += available;
            totalBurned += burned;
            ++successfulBuys;
        } else {
            assertEq(game.plays(), previousPlays, "failed or ineligible play persisted");
            assertEq(imd.balanceOf(hook.BURN()), previousBurn, "failed buy leaked tokens");
            assertEq(address(game).balance, previousGameETH, "failed buy leaked ETH");
            if (available >= 0.005 ether) ++failedBuys;
        }
        assertEq(manager.balanceOf(address(hook), 0), 0, "funded manager must redeem claims");
        assertEq(address(hook).balance + totalSpent, totalFees + totalDonations);
    }

    function donateETH(uint96 raw) external {
        uint256 amount = bound(raw, 0, 0.01 ether);
        uint256 beforePlays = game.plays();
        uint256 beforeAssets = address(hook).balance + manager.balanceOf(address(hook), 0);
        (bool ok,) = address(hook).call{value: amount}("");
        assertTrue(ok);
        totalDonations += amount;
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), beforeAssets + amount);
        assertEq(game.plays(), beforePlays, "donor must not trigger a move");
    }

    function donateClaims(uint96 raw) external {
        uint256 amount = bound(raw, 0, 0.01 ether);
        uint256 beforeClaims = manager.balanceOf(address(hook), 0);
        uint256 beforeETH = address(hook).balance;
        donor.donate{value: amount}(address(hook));
        totalDonations += amount;
        assertEq(manager.balanceOf(address(hook), 0), beforeClaims + amount);
        assertEq(address(hook).balance, beforeETH);
    }

    function redeem(uint8 who) external {
        uint256 beforeAssets = address(hook).balance + manager.balanceOf(address(hook), 0);
        uint256 beforePlays = game.plays();
        address actor = actors[uint256(who) % 3];
        uint256 actorBalance = actor.balance;
        vm.prank(actor, actor);
        hook.redeemFees();
        ++redemptions;
        assertEq(address(hook).balance, beforeAssets, "redemption must realize all backed claims");
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(game.plays(), beforePlays, "keeper must not claim a move");
        assertEq(actor.balance, actorBalance, "keeper must not receive jar ETH");
    }

    function collectLPFees() external {
        uint256 beforeAssets = address(hook).balance + manager.balanceOf(address(hook), 0);
        uint256 beforePlays = game.plays();
        BalanceDelta delta = liquidityProvider.modify(key, -60000, 60000, 0);
        assertGe(delta.amount0(), 0);
        assertGe(delta.amount1(), 0);
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), beforeAssets);
        assertEq(game.plays(), beforePlays);
    }

    function unauthorizedBuy(uint8 who, uint256 amount) external {
        vm.prank(actors[uint256(who) % 3]);
        vm.expectRevert(SherwoodPlayerHook.NotSelf.selector);
        hook.executeBuyback(amount);
    }

    function _executedETH(Vm.Log[] memory logs) private view returns (int128) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
            ) {
                (int128 amount0,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return amount0;
            }
        }
        revert("missing project swap");
    }

    function _abs(int128 n) private pure returns (uint256) {
        return n < 0 ? uint256(-int256(n)) : uint256(int256(n));
    }

    receive() external payable {}
}

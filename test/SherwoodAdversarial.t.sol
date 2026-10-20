// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SettlementProbe} from "./helpers/SettlementProbe.sol";
import {SherwoodPlayerHook} from "src/SherwoodPlayerHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Keep deployment and its revert in an external EVM call. Forge 1.8 may
/// implement a top-level `new` via deployCode, whose failure otherwise ends the test.
contract HookConstructionProbe {
    function deploy(IPoolManager manager, address token) external returns (address deployed) {
        bytes memory code = abi.encodePacked(type(SherwoodPlayerHook).creationCode, abi.encode(manager, token));
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }
}

contract SherwoodAdversarialTest is HookFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant SUCCESS_EVENT = keccak256("BuybackSucceeded(address,uint256,uint256)");
    bytes32 constant FAILURE_EVENT = keccak256("BuybackFailed(address,uint256)");

    function test_constructorRejectsInvalidInputsAndIncorrectAddressFlags() public {
        HookConstructionProbe deployer = new HookConstructionProbe();
        _assertConstructionRevert(
            deployer,
            IPoolManager(address(0)),
            address(token),
            abi.encodeWithSelector(SherwoodPlayerHook.InvalidConfiguration.selector)
        );
        _assertConstructionRevert(
            deployer, manager, address(0), abi.encodeWithSelector(SherwoodPlayerHook.InvalidConfiguration.selector)
        );
        _assertConstructionRevert(
            deployer, manager, hook.IMD(), abi.encodeWithSelector(SherwoodPlayerHook.InvalidConfiguration.selector)
        );

        // Ordinary CREATE is deliberately placed at an address with the wrong low bits.
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK == hook.FLAGS()) {
            vm.setNonce(address(deployer), vm.getNonce(address(deployer)) + 1);
            predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        }
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != hook.FLAGS());
        _assertConstructionRevert(
            deployer, manager, address(token), abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted)
        );
    }

    function test_poolParametersAndAllPermissionBitsArePinned() public view {
        PoolKey memory target = hook.sherwoodPool();
        assertEq(Currency.unwrap(target.currency0), address(0));
        assertEq(Currency.unwrap(target.currency1), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        assertEq(address(target.hooks), 0xc33c907127b94303F578d6Be551C36F45939e0cC);
        assertEq(target.fee, 9000);
        assertEq(target.tickSpacing, 180);
        assertEq(hook.BURN(), 0x000000000000000000000000000000000000dEaD);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everyPoolKeyFieldIsAuthenticated(uint8 rawField) public {
        PoolKey memory wrong = key;
        uint256 field = bound(rawField, 0, 4);
        if (field == 0) wrong.currency0 = Currency.wrap(address(token));
        if (field == 1) wrong.currency1 = Currency.wrap(address(imd));
        if (field == 2) wrong.fee++;
        if (field == 3) wrong.tickSpacing++;
        if (field == 4) wrong.hooks = IHooks(address(game));
        SwapParams memory params = SwapParams(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.startPrank(address(manager));
        vm.expectRevert(SherwoodPlayerHook.WrongPool.selector);
        hook.beforeInitialize(address(driver), wrong, PRICE);
        vm.expectRevert(SherwoodPlayerHook.WrongPool.selector);
        hook.beforeSwap(address(driver), wrong, params, "");
        vm.expectRevert(SherwoodPlayerHook.WrongPool.selector);
        hook.afterSwap(address(driver), wrong, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_unlockCallbackRequiresAnActiveRedemption() public {
        vm.prank(address(manager));
        vm.expectRevert(SherwoodPlayerHook.Busy.selector);
        hook.unlockCallback("");
    }

    function test_nativeFeeRejectsSignedExtremesWithoutPanicking() public {
        vm.startPrank(address(manager));
        vm.expectRevert(SherwoodPlayerHook.InvalidConfiguration.selector);
        hook.beforeSwap(address(driver), key, SwapParams(true, type(int256).min, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(SherwoodPlayerHook.InvalidConfiguration.selector);
        hook.beforeSwap(address(driver), key, SwapParams(false, type(int256).max, TickMath.MAX_SQRT_PRICE - 1), "");
        vm.stopPrank();
        assertEq(address(hook).balance, 0);
    }

    function test_zeroSwapDoesNotRedeemOrSpendAnExistingJar() public {
        vm.deal(address(hook), 0.005 ether);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        driver.swap(key, SwapParams(true, 0, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(game.plays(), 0);
    }

    function test_oneWeiBelowThresholdAndOneWeiFeeBoundary() public {
        vm.deal(address(hook), 0.005 ether - 1);
        _swap(true, -99);
        assertEq(address(hook).balance, 0.005 ether - 1);
        assertEq(game.plays(), 0);
        _swap(true, -100);
        assertEq(game.plays(), 1);
        assertEq(game.declared(), 0.005 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_oneWeiTradeRetriesAFundedJarWithoutChargingDust() public {
        vm.deal(address(hook), 0.005 ether);
        _swap(true, -1);
        assertEq(game.plays(), 1);
        assertEq(game.declared(), 0.005 ether);
        assertEq(address(hook).balance, 0);
        assertGt(imd.balanceOf(hook.BURN()), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_executedSwapAndWalletBalancesExplainEveryFee(bool buy, bool exactInput, uint96 raw) public {
        uint256 amount = bound(raw, 100, 0.4 ether);
        uint256 beforeETH = address(driver).balance;
        uint256 beforeToken = token.balanceOf(address(driver));
        vm.recordLogs();
        BalanceDelta result = _swap(buy, exactInput ? -int256(amount) : int256(amount));
        (int128 poolETH, int128 poolToken, uint24 lpFee) = _projectSwap(vm.getRecordedLogs());
        uint256 fee = address(hook).balance;
        assertEq(int256(poolETH) - int256(result.amount0()), int256(fee), "fee must only debit ETH");
        assertEq(result.amount1(), poolToken, "hook must not tax QUIVER");
        assertEq(int256(address(driver).balance) - int256(beforeETH), int256(result.amount0()));
        assertEq(int256(token.balanceOf(address(driver))) - int256(beforeToken), int256(result.amount1()));
        assertEq(lpFee, 12500, "hook must not override the launch LP fee");
        uint256 basis = (buy == exactInput) ? amount : _abs(poolETH);
        assertLe(fee * 100, basis);
        assertLt(basis, (fee + 1) * 100, "fee rounds down by less than one wei");
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(game.plays(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_buyThenSellCannotCreateETH(uint96 raw, bool gameFails) public {
        uint256 amount = bound(raw, 10000, 2 ether);
        game.setMode(gameFails ? 1 : 0);
        uint256 beforeETH = address(driver).balance;
        uint256 beforeTokens = token.balanceOf(address(driver));
        BalanceDelta bought = _swap(true, -int256(amount));
        assertGt(bought.amount1(), 0);
        _swap(false, -int256(bought.amount1()));
        assertEq(token.balanceOf(address(driver)), beforeTokens);
        assertLt(address(driver).balance, beforeETH, "round trip creates ETH");
    }

    function test_lateAndMalformedGameFailuresRollBackThenRetry() public {
        // Each failure happens with a valid, liquid target pool.
        for (uint256 mode = 4; mode <= 7; ++mode) {
            game.setMode(mode);
            bytes32 beforePool = _targetState();
            uint256 beforeIMD = imd.balanceOf(address(manager));
            uint256 beforeBurn = imd.balanceOf(hook.BURN());
            uint256 beforeGameETH = address(game).balance;
            uint256 beforePlays = game.plays();
            vm.recordLogs();
            BalanceDelta result = _swap(true, -0.5 ether);
            assertGt(result.amount1(), 0, "game failure must not stop trading");
            assertEq(address(hook).balance, 0.005 ether);
            assertEq(_targetState(), beforePool, "target price/fees must roll back");
            assertEq(imd.balanceOf(address(manager)), beforeIMD);
            assertEq(imd.balanceOf(hook.BURN()), beforeBurn);
            assertEq(address(game).balance, beforeGameETH);
            assertEq(game.plays(), beforePlays);
            _assertOutcome(vm.getRecordedLogs(), FAILURE_EVENT, PLAYER, 0.005 ether);

            game.setMode(0);
            _swap(true, -100);
            assertEq(game.plays(), beforePlays + 1, "guard must reset after failure");
            assertEq(game.declared(), 0.005 ether + 1);
            assertEq(address(hook).balance, 0);
            assertGt(imd.balanceOf(hook.BURN()), beforeBurn);
        }
    }

    function test_falseReturnFromBurnTransferRollsBackTheAMMAndGame() public {
        bytes32 beforePool = _targetState();
        uint256 beforeIMD = imd.balanceOf(address(manager));
        vm.mockCall(hook.IMD(), abi.encodeWithSignature("transfer(address,uint256)"), abi.encode(false));
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(_targetState(), beforePool);
        assertEq(imd.balanceOf(address(manager)), beforeIMD);
        assertEq(game.plays(), 0);
        assertEq(address(game).balance, 0);
        assertEq(imd.balanceOf(hook.BURN()), 0);
        vm.clearMockedCalls();
        _swap(false, -0.01 ether);
        assertEq(game.plays(), 1);
        assertEq(address(hook).balance, 0);
        assertGt(imd.balanceOf(hook.BURN()), 0);
    }

    function test_partialBuybackIsAtomicAndRecoversWhenLiquidityReturns() public {
        driver.modify(hook.sherwoodPool(), -59940, 59940, -10000 ether);
        driver.modify(hook.sherwoodPool(), -59940, 59940, 0.000001 ether);
        game.setMode(8); // The game accepts partial fills; validation must be in OUR hook.
        bytes32 beforePool = _targetState();
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(_targetState(), beforePool);
        assertEq(game.plays(), 0);
        assertEq(address(game).balance, 0);
        assertEq(imd.balanceOf(hook.BURN()), 0);
        driver.modify(hook.sherwoodPool(), -59940, 59940, 10000 ether);
        _swap(true, -100);
        assertEq(game.plays(), 1);
        assertEq(game.declared(), 0.005 ether + 1);
        assertEq(address(hook).balance, 0);
    }

    function test_buybackRejectsFullETHConsumptionWithoutAnyIMD() public {
        game.setMode(9);
        bytes32 beforePool = _targetState();
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether, "zero-output buy must retain the jar");
        assertEq(_targetState(), beforePool);
        assertEq(game.plays(), 0);
        assertEq(address(game).balance, 0, "game cannot consume ETH without delivering IMD");
        assertEq(imd.balanceOf(hook.BURN()), 0);
        game.setMode(0);
        _swap(true, -100);
        assertEq(game.plays(), 1);
        assertEq(address(hook).balance, 0);
        assertGt(imd.balanceOf(hook.BURN()), 0);
    }

    function test_gameCannotRecursivelyTradeTheProjectPool() public {
        game.setReentry(
            address(manager),
            abi.encodeCall(manager.swap, (key, SwapParams(true, -100, TickMath.MIN_SQRT_PRICE + 1), bytes("")))
        );
        game.setMode(3);
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(game.plays(), 0);
        game.setMode(0);
        _swap(true, -100);
        assertEq(game.plays(), 1);
        assertEq(address(hook).balance, 0);
    }

    function test_repeatedBuybacksWithinOneUnlockSettleEvenAfterERC20Sync() public {
        SettlementProbe probe = new SettlementProbe(manager, hook.IMD());
        vm.deal(address(probe), 2 ether);
        SwapParams[] memory params = new SwapParams[](2);
        params[0] = SwapParams(true, -0.5 ether, TickMath.MIN_SQRT_PRICE + 1);
        params[1] = params[0];
        vm.prank(PLAYER, PLAYER);
        BalanceDelta[] memory deltas = probe.batch(key, params, true, true);
        assertEq(probe.settledSwaps(), 2);
        assertEq(game.plays(), 2, "busy flag must reset within the transaction");
        assertEq(game.player(), PLAYER);
        assertEq(game.declared(), 0.005 ether);
        assertEq(address(hook).balance, 0);
        assertEq(address(probe).balance, 1 ether);
        assertEq(token.balanceOf(address(probe)), uint256(int256(deltas[0].amount1()) + int256(deltas[1].amount1())));
    }

    function test_successEventMatchesTheFullJarAndActualBurn() public {
        vm.deal(address(hook), 0.0123 ether);
        uint256 beforeBurn = imd.balanceOf(hook.BURN());
        vm.recordLogs();
        _swap(true, -0.1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertOutcome(logs, SUCCESS_EVENT, PLAYER, 0.0133 ether);
        uint256 eventBurn;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == SUCCESS_EVENT) {
                (, eventBurn) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(eventBurn, imd.balanceOf(hook.BURN()) - beforeBurn);
        assertGt(eventBurn, 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(PLAYER), 0);
    }

    function _projectSwap(Vm.Log[] memory logs) internal view returns (int128 amount0, int128 amount1, uint24 fee) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
            ) {
                (amount0, amount1,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (amount0, amount1, fee);
            }
        }
        revert("project Swap event missing");
    }

    function _assertOutcome(Vm.Log[] memory logs, bytes32 signature, address player, uint256 spent) internal view {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != signature) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), player);
            assertEq(abi.decode(logs[i].data, (uint256)), spent);
            ++matches;
        }
        assertEq(matches, 1, "one outcome per attempt");
    }

    function _targetState() internal view returns (bytes32) {
        PoolId id = hook.sherwoodPool().toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(id);
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, fee0, fee1, manager.getLiquidity(id)));
    }

    function _abs(int128 n) internal pure returns (uint256) {
        return n < 0 ? uint256(-int256(n)) : uint256(int256(n));
    }

    function _assertConstructionRevert(HookConstructionProbe deployer, IPoolManager m, address t, bytes memory expected)
        internal
    {
        (bool ok, bytes memory reason) = address(deployer).call(abi.encodeCall(deployer.deploy, (m, t)));
        assertFalse(ok, "invalid constructor accepted");
        assertEq(reason, expected, "wrong constructor rejection");
    }
}

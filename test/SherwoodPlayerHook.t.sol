// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Quiver} from "../src/Quiver.sol";
import {SherwoodPlayerHook} from "../src/SherwoodPlayerHook.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {MockSherwood} from "./helpers/MockSherwood.sol";
import {PrepayRouter} from "./helpers/PrepayRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

import {HookFixture} from "./helpers/HookFixture.sol";

contract SherwoodPlayerHookTest is HookFixture {
    using TransientStateLibrary for IPoolManager;

    function test_permissionsAndInitialization() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.FLAGS());
    }

    function test_unauthorizedCallbacksAndHelpers() public {
        vm.expectRevert(SherwoodPlayerHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.expectRevert(SherwoodPlayerHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(SherwoodPlayerHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), "");
        vm.expectRevert(SherwoodPlayerHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(SherwoodPlayerHook.NotSelf.selector);
        hook.executeBuyback(0.005 ether);
    }

    function test_wrongPoolRejected() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, PRICE);
        wrong = key;
        wrong.tickSpacing = 180;
        vm.expectRevert();
        manager.initialize(wrong, PRICE);
    }

    function test_exactInputBuyFee() public {
        BalanceDelta delta = _swap(true, -0.1 ether);
        assertEq(delta.amount0(), -0.1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(address(hook).balance, 0.001 ether);
        assertEq(game.plays(), 0);
    }

    function test_exactOutputBuyFee() public {
        BalanceDelta delta = _swap(true, 0.1 ether);
        uint256 paid = uint256(-int256(delta.amount0()));
        uint256 fee = address(hook).balance;
        assertEq(fee, paid / 100);
        assertEq(fee, (paid - fee) / 99);
        assertEq(delta.amount1(), 0.1 ether);
    }

    function test_exactInputSellFee() public {
        uint256 beforeETH = address(driver).balance;
        BalanceDelta delta = _swap(false, -0.1 ether);
        uint256 net = uint256(int256(delta.amount0()));
        uint256 fee = address(hook).balance;
        assertEq(fee, (net + fee) / 100);
        assertEq(address(driver).balance - beforeETH, net);
        assertEq(delta.amount1(), -0.1 ether);
    }

    function test_exactOutputSellFee() public {
        uint256 poolETH = address(manager).balance;
        BalanceDelta delta = _swap(false, 0.1 ether);
        assertEq(delta.amount0(), 0.1 ether);
        uint256 fee = address(hook).balance;
        assertEq(fee, uint256(0.1 ether) / 99);
        // The pool paid the requested output plus the fee; the fee is 1% of that gross leg.
        assertEq(poolETH - address(manager).balance, 0.1 ether + fee);
        assertEq(fee, (0.1 ether + fee) / 100);
        assertLt(delta.amount1(), 0);
    }

    function test_feeBaseIsGrossETHInEveryMode() public {
        // Exact-input sell: the pool pays gross G, the seller nets G - G/100.
        BalanceDelta sellIn = _swap(false, -0.1 ether);
        uint256 feeIn = address(hook).balance;
        uint256 grossIn = uint256(int256(sellIn.amount0())) + feeIn;
        assertEq(feeIn, grossIn / 100);
        // Exact-output sell for that same net: the pool pays the same gross and the jar gets the same fee.
        uint256 jar = address(hook).balance;
        BalanceDelta sellOut = _swap(false, int256(uint256(int256(sellIn.amount0()))));
        uint256 feeOut = address(hook).balance - jar;
        assertEq(sellOut.amount0(), sellIn.amount0());
        assertEq(feeOut, uint256(int256(sellOut.amount0())) / 99);
        assertApproxEqAbs(feeOut, feeIn, 2); // Only the AMM path's wei rounding differs.
    }

    function test_prepayingRouterSellSucceedsAndDefersBuyback() public {
        PrepayRouter router = new PrepayRouter(manager);
        token.transfer(address(router), 10 ether);
        vm.deal(address(hook), 0.005 ether);
        uint256 routerETH = address(router).balance;
        // Deferred after this sell's own fee joined the jar, attributed to the originating signer.
        vm.expectEmit(true, false, false, false, address(hook));
        emit SherwoodPlayerHook.BuybackDeferred(address(0xB0B), 0);
        vm.prank(address(0xB0B), address(0xB0B));
        BalanceDelta delta = router.sell(key, 0.1 ether);
        assertGt(delta.amount0(), 0);
        assertEq(address(router).balance - routerETH, uint256(int256(delta.amount0())));
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(game.plays(), 0);
        // The sell's own fee joined the jar; nothing was spent or lost.
        uint256 fee = address(hook).balance - 0.005 ether;
        assertEq(fee, (uint256(int256(delta.amount0())) + fee) / 100);
        // A router that leaves the slot clear runs the buyback with the jar intact.
        uint256 jar = address(hook).balance;
        _swap(true, -0.01 ether);
        assertEq(game.plays(), 1);
        assertEq(game.player(), PLAYER);
        assertEq(game.declared(), jar + 0.0001 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_prepayingRouterSellWithEmptyJarIsUnaffected() public {
        PrepayRouter router = new PrepayRouter(manager);
        token.transfer(address(router), 10 ether);
        BalanceDelta delta = router.sell(key, 0.1 ether);
        assertGt(delta.amount0(), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(address(hook).balance, (uint256(int256(delta.amount0())) + address(hook).balance) / 100);
    }

    function test_thresholdCrossingBuysAllAndBurns() public {
        _swap(true, -0.49 ether);
        assertEq(address(hook).balance, 0.0049 ether);
        uint256 burnBefore = imd.balanceOf(hook.BURN());
        _swap(true, -0.02 ether);
        assertEq(address(hook).balance, 0);
        assertEq(game.plays(), 1);
        assertEq(game.player(), PLAYER);
        assertEq(game.declared(), 0.0051 ether);
        assertEq(game.limit(), TickMath.MIN_SQRT_PRICE + 1);
        assertGt(imd.balanceOf(hook.BURN()), burnBefore);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(PLAYER), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_exactThresholdTriggers() public {
        _swap(true, -0.5 ether);
        assertEq(game.plays(), 1);
        assertEq(game.declared(), hook.THRESHOLD());
        assertEq(address(hook).balance, 0);
    }

    function test_failureKeepsJarAndNextTraderRetries() public {
        game.setMode(1);
        BalanceDelta delta = _swap(true, -0.5 ether);
        assertGt(delta.amount1(), 0);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(game.plays(), 0);
        game.setMode(0);
        address later = address(0xB0B);
        vm.prank(later, later);
        driver.swap(key, SwapParams(false, -0.01 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(game.plays(), 1);
        assertEq(game.player(), later);
        assertGt(game.declared(), 0.005 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_gameOutOfGasDoesNotRevertTrade() public {
        game.setMode(2);
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(game.plays(), 0);
    }

    function test_reentrantRedemptionIsIsolated() public {
        game.setReentry(address(hook), abi.encodeCall(hook.redeemFees, ()));
        game.setMode(3);
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(game.plays(), 0);
        game.setMode(0);
        _swap(true, -0.01 ether);
        assertEq(game.plays(), 1);
    }

    function test_failedBurnRollsBackGameAndSettlement() public {
        vm.mockCallRevert(
            hook.IMD(), abi.encodeWithSignature("transfer(address,uint256)", hook.BURN(), uint256(1)), "failure"
        );
        // Match all transfer calls regardless of the computed output amount.
        vm.mockCallRevert(hook.IMD(), abi.encodeWithSignature("transfer(address,uint256)"), "failure");
        uint256 gameBalance = hook.SHERWOOD().balance;
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0.005 ether);
        assertEq(game.plays(), 0);
        assertEq(hook.SHERWOOD().balance, gameBalance);
        vm.clearMockedCalls();
        _swap(true, -0.01 ether);
        assertEq(game.plays(), 1);
    }

    function test_factoryZeroLiquidityFeeCollection() public {
        _swap(true, -0.1 ether);
        BalanceDelta delta = driver.modify(key, -60000, 60000, 0);
        assertGe(delta.amount0(), 0);
        assertGe(delta.amount1(), 0);
    }

    function _freshTokenOnlyPool() internal {
        manager = new PoolManager(address(this));
        hook = _deployHook(manager, address(token));
        driver = new PoolDriver(manager);
        vm.deal(address(driver), 100 ether);
        token.transfer(address(driver), 100000 ether);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, PRICE);
        driver.modify(key, -60000, 0, 1000 ether);
        assertEq(address(manager).balance, 0);
    }

    function test_freshTokenOnlyPoolDefersFeeWithoutReverting() public {
        _freshTokenOnlyPool();
        BalanceDelta delta = _swap(true, -0.1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.001 ether);
        assertEq(address(manager).balance, 0.1 ether);
        hook.redeemFees();
        assertEq(address(hook).balance, 0.001 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_laterSwapAutomaticallyRedeemsDeferredFee() public {
        _freshTokenOnlyPool();
        _swap(true, -0.1 ether);
        _swap(true, -0.1 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(hook).balance, 0.002 ether);
    }

    function test_partialClaimRedemptionAndNoKeeperPlayer() public {
        _freshTokenOnlyPool();
        _swap(true, -0.1 ether);
        vm.deal(address(manager), 0.0004 ether);
        hook.redeemFees();
        assertEq(address(hook).balance, 0.0004 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.0006 ether);
        hook.redeemFees(); // No manager cash; no revert, no fabricated credit.
        assertEq(manager.balanceOf(address(hook), 0), 0.0006 ether);
    }

    function test_missingSherwoodPoolIsRetriable() public {
        _freshTokenOnlyPool();
        _swap(true, -0.5 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.005 ether);
        hook.redeemFees();
        _swap(true, -0.01 ether);
        assertEq(address(hook).balance, 0.0051 ether);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_unspecifiedNativePartialSellUsesActualETH() public {
        uint160 boundPrice = PRICE + PRICE / 100000;
        vm.prank(PLAYER, PLAYER);
        BalanceDelta delta = driver.swap(key, SwapParams(false, -1 ether, boundPrice));
        assertLt(uint256(-int256(delta.amount1())), 1 ether);
        uint256 net = uint256(int256(delta.amount0()));
        assertEq(address(hook).balance, (net + address(hook).balance) / 100);
    }

    function test_specifiedNativePartialFillRevertsAtomically() public {
        uint256 beforeBalance = address(hook).balance;
        vm.expectRevert();
        driver.swap(key, SwapParams(true, -1 ether, PRICE - PRICE / 100000));
        assertEq(address(hook).balance, beforeBalance);
        assertEq(game.plays(), 0);
    }

    function test_donationsIncludedAndRedemptionCannotTriggerBuyback() public {
        vm.deal(address(hook), 0.01 ether);
        hook.redeemFees();
        assertEq(game.plays(), 0);
        _swap(true, -0.01 ether);
        assertEq(game.declared(), 0.0101 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_zeroFeeDustDoesNotCreateCredit() public {
        _swap(true, -99);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_hookHasNoOwnerOrAdmin() public {
        (bool owner,) = address(hook).call(abi.encodeWithSignature("owner()"));
        (bool setter,) = address(hook).call(abi.encodeWithSignature("setThreshold(uint256)", 1));
        (bool withdraw,) = address(hook).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(owner || setter || withdraw);
    }

    function testFuzz_feeConservation(bool buy, bool exactInput, uint96 raw) public {
        uint256 amount = bound(uint256(raw), 10000, 0.4 ether);
        uint256 initialETH = address(manager).balance + address(driver).balance + address(hook).balance;
        uint256 initialTokens = token.balanceOf(address(manager)) + token.balanceOf(address(driver));
        BalanceDelta delta = _swap(buy, exactInput ? -int256(amount) : int256(amount));
        uint256 fee = address(hook).balance;
        // The trader's ETH delta includes the fee on buys and excludes it on sells; the gross ETH
        // leg between trader and pool is taxed at exactly 1% in all four modes.
        uint256 userETH = delta.amount0() < 0 ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0()));
        uint256 gross = buy ? userETH : userETH + fee;
        assertEq(fee, gross / 100);
        if (exactInput == buy) assertEq(fee, exactInput ? amount / 100 : amount / 99);
        assertEq(address(manager).balance + address(driver).balance + fee, initialETH);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(driver)), initialTokens);
    }
}

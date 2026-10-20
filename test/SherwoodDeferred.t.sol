// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SettlementProbe} from "./helpers/SettlementProbe.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {MockSherwood} from "./helpers/MockSherwood.sol";
import {Quiver} from "src/Quiver.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Both pools are genuinely seeded with tokens only: no vm.deal on PoolManager.
contract SherwoodDeferredTest is HookFixture {
    function setUp() public override {
        manager = new PoolManager(address(this));
        token = new Quiver();
        hook = _deployHook(manager, address(token));
        driver = new PoolDriver(manager);
        vm.deal(address(driver), 100 ether);
        token.transfer(address(driver), 1_000_000 ether);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, PRICE);
        driver.modify(key, -60000, 0, 10000 ether);
        vm.etch(hook.IMD(), address(new Quiver()).code);
        imd = Quiver(hook.IMD());
        deal(address(imd), address(driver), 1_000_000 ether);
        vm.etch(hook.SHERWOOD(), address(new MockSherwood(manager)).code);
        game = MockSherwood(payable(hook.SHERWOOD()));
        manager.initialize(hook.sherwoodPool(), PRICE);
        driver.modify(hook.sherwoodPool(), -59940, 0, 10000 ether);
        assertEq(address(manager).balance, 0, "fixture must start without manager ETH");
    }

    function test_nextTraderRealizesDeferredFeesAndPlays() public {
        _swap(true, -0.5 ether);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.005 ether);
        assertEq(game.plays(), 0);
        address laterTrader = makeAddr("later trader");
        vm.prank(laterTrader, laterTrader);
        driver.swap(key, SwapParams(true, -100, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(game.plays(), 1);
        assertEq(game.player(), laterTrader);
        assertEq(game.declared(), 0.005 ether + 1);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertGt(imd.balanceOf(hook.BURN()), 0);
    }

    function test_batchAccumulatesClaimsUntilTheRouterSettles() public {
        SettlementProbe probe = new SettlementProbe(manager, hook.IMD());
        vm.deal(address(probe), 1 ether);
        SwapParams[] memory params = new SwapParams[](2);
        params[0] = SwapParams(true, -0.3 ether, TickMath.MIN_SQRT_PRICE + 1);
        params[1] = params[0];
        probe.batch(key, params, false, true);
        assertEq(probe.settledSwaps(), 2);
        assertEq(address(manager).balance, 0.6 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.006 ether);
        assertEq(address(hook).balance, 0);
        assertEq(game.plays(), 0);
        _swap(true, -100);
        assertEq(game.declared(), 0.006 ether + 1);
        assertEq(game.plays(), 1);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_prepaidBuybackWorksWithNoManagerETHBeforeTheTrade() public {
        vm.deal(address(hook), 0.005 ether);
        _swap(true, -0.1 ether);
        assertEq(game.plays(), 1, "pot fee must be funded by the prepaid jar");
        assertEq(game.declared(), 0.005 ether);
        assertEq(address(game).balance, 0.00025 ether);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.001 ether);
        assertGt(imd.balanceOf(hook.BURN()), 0);
        hook.redeemFees();
        assertEq(address(hook).balance, 0.001 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(game.plays(), 1, "redemption must not make another move");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_firstBuyClaimIsBackedAndRedemptionIsIdempotent(uint96 raw, bool exactInput) public {
        uint256 amount = bound(raw, 100, 0.8 ether);
        uint256 beforeETH = address(driver).balance;
        BalanceDelta delta = _swap(true, exactInput ? -int256(amount) : int256(amount));
        uint256 paid = uint256(-int256(delta.amount0()));
        uint256 claim = manager.balanceOf(address(hook), 0);
        uint256 basis = exactInput ? amount : paid - claim;
        assertEq(address(hook).balance, 0);
        assertEq(address(manager).balance, paid);
        assertEq(address(driver).balance, beforeETH - paid);
        assertLe(claim * 100, basis);
        assertLt(basis, (claim + 1) * 100);
        vm.prank(makeAddr("permissionless keeper"));
        hook.redeemFees();
        assertEq(address(hook).balance, claim);
        assertEq(address(manager).balance, paid - claim);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        hook.redeemFees();
        assertEq(address(hook).balance, claim);
        assertEq(address(manager).balance, paid - claim);
        assertEq(game.plays(), 0, "redemption alone cannot choose the player");
    }
}

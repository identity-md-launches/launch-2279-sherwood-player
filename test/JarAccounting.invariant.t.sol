// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {JarHandler} from "./helpers/JarHandler.sol";
import {SettlementProbe} from "./helpers/SettlementProbe.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract JarAccountingInvariantTest is HookFixture {
    JarHandler handler;
    SettlementProbe[3] routers;
    uint256 initialETH;
    uint256 initialIMD;
    uint256 fixedSupply;

    function setUp() public override {
        super.setUp();
        address[3] memory actors = [makeAddr("trader one"), makeAddr("trader two"), makeAddr("trader three")];
        for (uint256 i; i < 3; ++i) {
            routers[i] = new SettlementProbe(manager, hook.IMD());
            vm.deal(address(routers[i]), 1000 ether);
            token.transfer(address(routers[i]), 1000 ether);
        }
        handler = new JarHandler(hook, game, driver, key, routers, actors);
        vm.deal(address(handler), 100 ether);
        initialETH = _allETH();
        initialIMD = imd.balanceOf(address(manager)) + imd.balanceOf(address(driver));
        fixedSupply = token.totalSupply();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.donateETH.selector;
        selectors[2] = handler.donateClaims.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.collectLPFees.selector;
        selectors[5] = handler.unauthorizedBuy.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyWeiIsStillInTheJarAClaimOrASuccessfulBuy() public view {
        assertEq(
            address(hook).balance + manager.balanceOf(address(hook), 0) + handler.totalSpent(),
            handler.totalFees() + handler.totalDonations(),
            "fee/donation value lost or counted twice"
        );
        assertEq(_allETH(), initialETH, "native ETH escaped the closed system");
    }

    function invariant_everySuccessfulBuyBurnsItsOutputAndNoOtherCallDoes() public view {
        assertEq(game.plays(), handler.successfulBuys());
        assertEq(imd.balanceOf(hook.BURN()), handler.totalBurned());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(driver)) + imd.balanceOf(hook.BURN()), initialIMD
        );
    }

    function invariant_projectSupplyAndBalancesAreConserved() public view {
        uint256 sum =
            token.balanceOf(address(this)) + token.balanceOf(address(driver)) + token.balanceOf(address(manager));
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(address(routers[i]));
        }
        assertEq(sum, fixedSupply);
        assertEq(token.totalSupply(), fixedSupply);
        assertEq(token.balanceOf(address(hook)), 0, "fee collected in QUIVER");
    }

    function test_handlerExercisesFailuresClaimsRedemptionsAndRecovery() public {
        handler.trade(0, true, true, 0.5 ether, 1);
        assertEq(handler.failedBuys(), 1);
        handler.donateClaims(0.002 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.002 ether);
        handler.redeem(1);
        handler.donateETH(0.001 ether);
        handler.unauthorizedBuy(2, 0.008 ether);
        handler.trade(2, true, true, 100, 0);
        assertEq(handler.successfulBuys(), 1);
        assertEq(handler.totalSpent(), 0.008 ether + 1);
        handler.collectLPFees();
        invariant_everyWeiIsStillInTheJarAClaimOrASuccessfulBuy();
        invariant_everySuccessfulBuyBurnsItsOutputAndNoOtherCallDoes();
        invariant_projectSupplyAndBalancesAreConserved();
    }

    function _allETH() internal view returns (uint256 sum) {
        sum = address(manager).balance + address(driver).balance + address(hook).balance + address(game).balance
            + address(handler).balance + address(handler.donor()).balance;
        for (uint256 i; i < 3; ++i) {
            sum += address(routers[i]).balance;
        }
    }
}

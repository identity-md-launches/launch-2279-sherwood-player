// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {MockSherwood} from "./helpers/MockSherwood.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SwapHandler is Test {
    PoolDriver immutable driver;
    MockSherwood immutable game;
    PoolKey key;
    uint256 public completed;

    constructor(PoolDriver driver_, MockSherwood game_, PoolKey memory key_) {
        driver = driver_;
        game = game_;
        key = key_;
    }

    function trade(bool buy, bool exactInput, uint96 raw, bool gameFails) external {
        uint256 amount = bound(uint256(raw), 10000, 0.2 ether);
        game.setMode(gameFails ? 1 : 0);
        driver.swap(
            key,
            SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        completed++;
    }
}

contract SherwoodInvariants is HookFixture {
    using TransientStateLibrary for IPoolManager;
    uint256 initialETH;
    uint256 initialQuiver;
    uint256 initialIMD;
    SwapHandler handler;

    function setUp() public override {
        super.setUp();
        initialETH = address(manager).balance + address(driver).balance + address(hook).balance + address(game).balance;
        initialQuiver = token.balanceOf(address(manager)) + token.balanceOf(address(driver));
        initialIMD = imd.balanceOf(address(manager)) + imd.balanceOf(address(driver)) + imd.balanceOf(hook.BURN());
        handler = new SwapHandler(driver, game, key);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.trade.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ETHConservedAcrossAllPoolsJarAndGame() public view {
        assertEq(
            address(manager).balance + address(driver).balance + address(hook).balance + address(game).balance,
            initialETH
        );
    }

    function invariant_tokensConservedAndNoIMDRetained() public view {
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(driver)), initialQuiver);
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(driver)) + imd.balanceOf(hook.BURN()), initialIMD
        );
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function invariant_allFlashAccountingSettled() public view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0); // This fixture's manager is fully funded.
    }
}

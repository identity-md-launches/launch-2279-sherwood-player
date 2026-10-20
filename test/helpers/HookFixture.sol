// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Quiver} from "../../src/Quiver.sol";
import {SherwoodPlayerHook} from "../../src/SherwoodPlayerHook.sol";
import {PoolDriver} from "./PoolDriver.sol";
import {MockSherwood} from "./MockSherwood.sol";
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

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager manager;
    Quiver token;
    Quiver imd;
    SherwoodPlayerHook hook;
    PoolDriver driver;
    MockSherwood game;
    PoolKey key;
    uint160 constant PRICE = 79228162514264337593543950336;
    address constant PLAYER = address(0xA11CE);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        token = new Quiver();
        hook = _deployHook(manager, address(token));
        driver = new PoolDriver(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, PRICE);
        vm.deal(address(driver), 100_000 ether);
        token.transfer(address(driver), 500_000_000 ether);
        driver.modify(key, -60000, 60000, 10000 ether);
        // A standard ERC-20 at the immutable target token address and a faithful game-hook mock.
        vm.etch(hook.IMD(), address(new Quiver()).code);
        imd = Quiver(hook.IMD());
        deal(address(imd), address(driver), 1_000_000 ether);
        vm.etch(hook.SHERWOOD(), address(new MockSherwood(manager)).code);
        game = MockSherwood(payable(hook.SHERWOOD()));
        manager.initialize(hook.sherwoodPool(), PRICE);
        driver.modify(hook.sherwoodPool(), -59940, 59940, 10000 ether);
    }

    function _deployHook(IPoolManager m, address t) internal returns (SherwoodPlayerHook deployed) {
        bytes memory code = abi.encodePacked(type(SherwoodPlayerHook).creationCode, abi.encode(m, t));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200000; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x20cc) continue;
            bytes32 salt = bytes32(i);
            address at;
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            require(at != address(0));
            return SherwoodPlayerHook(payable(at));
        }
        revert("salt exhausted");
    }

    function _swap(bool buy, int256 amount) internal returns (BalanceDelta delta) {
        vm.prank(PLAYER, PLAYER);
        delta =
            driver.swap(key, SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0, "unsettled hook ETH");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(hook.IMD())), 0, "unsettled hook IMD");
        assertEq(manager.getNonzeroDeltaCount(), 0, "unsettled unlock");
    }
}

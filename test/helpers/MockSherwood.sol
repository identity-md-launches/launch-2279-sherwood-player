// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @dev Models v2's ETH pot fee, tx.origin attribution, exact-input rule and BUY hook data.
/// Deliberately adversarial modes exercise the caller's rollback and gas isolation.
contract MockSherwood {
    IPoolManager public immutable manager;
    uint256 public mode;
    uint256 public plays;
    address public player;
    uint256 public declared;
    uint160 public limit;
    address public reentry;
    bytes public reentryData;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function setMode(uint256 mode_) external {
        mode = mode_;
    }

    function setReentry(address target, bytes calldata data) external {
        reentry = target;
        reentryData = data;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        require(msg.sender == address(manager));
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager));
        require(params.zeroForOne && params.amountSpecified < 0 && data.length == 0);
        if (mode == 1) revert("GAME_FAILED");
        if (mode == 2) {
            assembly { for {} 1 {} {} }
        }
        if (mode == 3) {
            (bool ok,) = reentry.call(reentryData);
            require(ok, "REENTRY_FAILED");
        }
        declared = uint256(-params.amountSpecified);
        limit = params.sqrtPriceLimitX96;
        player = tx.origin;
        plays++;
        uint256 fee = declared / 20;
        manager.take(key.currency0, address(this), fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        view
        returns (bytes4, int128)
    {
        require(msg.sender == address(manager));
        uint256 amount = uint256(-params.amountSpecified);
        require(uint256(-int256(delta.amount0())) + amount / 20 == amount, "PARTIAL_GAME_FILL");
        return (IHooks.afterSwap.selector, 0);
    }

    receive() external payable {}
}

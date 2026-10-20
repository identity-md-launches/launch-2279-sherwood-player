// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Prefunded test driver. Never used in production; no external user's allowance is used.
contract PoolDriver is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(lower, upper, liquidity))), (BalanceDelta));
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool liquidity, PoolKey memory key, bytes memory args) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (liquidity) {
            (int24 lower, int24 upper, int256 amount) = abi.decode(args, (int24, int24, int256));
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, amount, bytes32(0)), "");
        } else {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(-int256(amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed));
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}

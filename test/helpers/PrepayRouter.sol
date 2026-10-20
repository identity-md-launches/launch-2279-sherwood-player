// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Sells QUIVER with the manager's synced-currency slot occupied across the swap:
/// sync(QUIVER) -> transfer -> swap -> settle() -> take(ETH). Prefunded test router only.
contract PrepayRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function sell(PoolKey memory key, uint256 amount) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, amount)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));
        manager.sync(key.currency1);
        require(IERC20(Currency.unwrap(key.currency1)).transfer(address(manager), amount));
        BalanceDelta delta = manager.swap(key, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), "");
        manager.settle();
        manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        return abi.encode(delta);
    }

    receive() external payable {}
}

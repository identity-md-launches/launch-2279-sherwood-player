// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Prefunded test router. All batch operations and transient-state assertions
/// execute inside ONE unlock callback, before Foundry can clear transient storage.
contract SettlementProbe is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address public immutable imd;
    uint256 public settledSwaps;

    constructor(IPoolManager manager_, address imd_) {
        manager = manager_;
        imd = imd_;
    }

    function batch(PoolKey memory key, SwapParams[] memory params, bool syncTokenFirst, bool deferSettlement)
        external
        returns (BalanceDelta[] memory)
    {
        return abi.decode(manager.unlock(abi.encode(key, params, syncTokenFirst, deferSettlement)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, SwapParams[] memory params, bool syncTokenFirst, bool deferSettlement) =
            abi.decode(data, (PoolKey, SwapParams[], bool, bool));
        BalanceDelta[] memory deltas = new BalanceDelta[](params.length);
        int256 total0;
        int256 total1;
        for (uint256 i; i < params.length; ++i) {
            if (syncTokenFirst) manager.sync(key.currency1);
            deltas[i] = manager.swap(key, params[i], "");
            // The hook must settle its own debt even while this router still owes its input.
            require(manager.isUnlocked(), "lock closed during callback");
            require(manager.currencyDelta(address(key.hooks), key.currency0) == 0, "hook ETH debt");
            require(manager.currencyDelta(address(key.hooks), key.currency1) == 0, "hook QUIVER debt");
            require(manager.currencyDelta(address(key.hooks), Currency.wrap(imd)) == 0, "hook IMD debt");
            total0 += deltas[i].amount0();
            total1 += deltas[i].amount1();
            if (!deferSettlement) {
                _settle(key.currency0, deltas[i].amount0());
                _settle(key.currency1, deltas[i].amount1());
                require(manager.getNonzeroDeltaCount() == 0, "unsettled swap");
            }
            ++settledSwaps;
        }
        if (deferSettlement) {
            _settle(key.currency0, total0);
            _settle(key.currency1, total1);
        }
        require(manager.getNonzeroDeltaCount() == 0, "unsettled batch");
        return abi.encode(deltas);
    }

    function _settle(Currency currency, int256 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed), "transfer failed");
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }

    receive() external payable {}
}

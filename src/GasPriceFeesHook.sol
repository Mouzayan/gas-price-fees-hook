// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Keeping track of the moving average gas price
    uint128 public movingAverageGasPrice;
    // How many times has the moving average been updated?
    // Needed as the denominator to update it the next time based on the moving average formula
    uint104 public movingAverageGasPriceCount;

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // 0.5%

    error MustUseDynamicFee();

    // initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        updateMovingAverage();
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `SwapFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        // If we wanted to generally update LP fee for a longer-term than per-swap
        // poolManager.updateDynamicLPFee(key, fee);

        // bitwise OR operation btwn the computed fee value and a uint24 bitmask
        // LPFeeLibrary.OVERRIDE_FEE_FLAG is a flag (specific bit pattern) defined in
        // LPFeeLibrary, that can be set to indicate some condition or behavior.
        // The OR operation combines the bits of fee and LPFeeLibrary.OVERRIDE_FEE_FLAG.
        // The purpose of the flag is to embed additional information into the fee value
        // by “marking” it with a specific flag.
        // The base fee remains unchanged.
        // The flag is added as a metadata marker in unused bits of the uint24.
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function _afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    // update moving average gas price
    // A moving average is a statistical method used to calculate the average value
    // of a data set over time, with each new value updating the average.
    // the moving average gas price tracks an average gas price across transactions,
    // updated every time the function is called.
    // This formula updates the moving average without requiring the storage of
    // individual past gas prices.
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice); // Get the Current Gas Price

        // new Average = ((old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++; // Increment the Transaction Count
    }

    // The multiplication by 1.1 and division by 0.9 introduces thresholds
    // or buffers around the movingAverageGasPrice. These thresholds are used to
    // determine whether the gasPrice is significantly above or below the moving average,
    // instead of reacting to minor deviations.
    // Without thresholds, small deviations in gasPrice around movingAverageGasPrice
    // could cause unnecessary changes to the fees.
    // Multipliers like 1.1 (10% above) and 0.9 (10% below) introduce a buffer zone,
    // ensuring that fee adjustments are only triggered by meaningful gas price changes.
    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // if gasPrice > movingAverageGasPrice * 1.1, then half the fees
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }

        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }

        return BASE_FEE;
    }
}

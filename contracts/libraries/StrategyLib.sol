// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    StrategyType,
    StrategyInput,
    Strategy,
    BPS_DENOMINATOR,
    MAX_STRATEGIES,
    MIN_STRATEGY_BPS
} from "../types/VaultTypes.sol";

/**
 * @title StrategyLib
 * @notice Library for strategy allocation logic and validation
 * @dev Uses types from VaultTypes.sol for consistency across the system
 */
library StrategyLib {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when allocations don't sum to 100%
    error InvalidAllocationSum(uint256 actual, uint256 expected);

    /// @notice Thrown when allocation is below minimum
    error StrategyBelowMinimum(uint16 allocation, uint16 minimum);

    /// @notice Thrown when too many strategies are configured
    error TooManyStrategies(uint8 count, uint8 maximum);

    /// @notice Thrown when adapter address is zero for non-PERPS strategy
    error ZeroAdapterAddress();

    /// @notice Thrown when adapter address is duplicated
    error DuplicateStrategy(address adapter);

    /// @notice Thrown when PERPS strategy is misconfigured
    error InvalidPerpsStrategy();

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate strategy inputs - allocations sum to 100%, no duplicates, within limits
     * @param inputs Array of StrategyInput structs
     * @return totalBps The total allocation in basis points (should be 10000)
     */
    function validateStrategyInputs(StrategyInput[] calldata inputs) internal pure returns (uint16 totalBps) {
        uint256 length = inputs.length;

        if (length == 0) {
            revert TooManyStrategies(0, MAX_STRATEGIES);
        }

        if (length > MAX_STRATEGIES) {
            // casting to uint8 is safe because MAX_STRATEGIES <= type(uint8).max
            // forge-lint: disable-next-line(unsafe-typecast)
            revert TooManyStrategies(uint8(length), MAX_STRATEGIES);
        }

        bool perpsSeen;

        for (uint256 i = 0; i < length; i++) {
            StrategyInput calldata input = inputs[i];

            if (input.strategyType == StrategyType.PERPS) {
                if (perpsSeen) revert InvalidPerpsStrategy();
                if (input.adapter != address(0)) revert InvalidPerpsStrategy();
                perpsSeen = true;
            } else {
                if (input.adapter == address(0)) revert ZeroAdapterAddress();
            }

            if (input.active && input.targetBps < MIN_STRATEGY_BPS) {
                revert StrategyBelowMinimum(input.targetBps, MIN_STRATEGY_BPS);
            }

            if (input.active) {
                totalBps += input.targetBps;
            }

            if (input.adapter != address(0)) {
                for (uint256 j = i + 1; j < length; j++) {
                    if (input.adapter == inputs[j].adapter && input.adapter != address(0)) {
                        revert DuplicateStrategy(input.adapter);
                    }
                }
            }
        }

        if (totalBps != BPS_DENOMINATOR) {
            revert InvalidAllocationSum(totalBps, BPS_DENOMINATOR);
        }

        return totalBps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALCULATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate target amounts for each strategy based on deployable capital
     * @param deployableAssets Total deployable assets (totalAssets minus reserve)
     * @param strategies Array of Strategy structs
     * @return targets Array of target amounts aligned to strategies array
     */
    function calculateTargetAmounts(
        uint256 deployableAssets,
        Strategy[] memory strategies
    ) internal pure returns (uint256[] memory targets) {
        uint256 length = strategies.length;
        targets = new uint256[](length);

        uint256 allocated;
        uint256 lastActive = type(uint256).max;

        for (uint256 i = 0; i < length; i++) {
            if (strategies[i].active) {
                lastActive = i;
            }
        }

        if (lastActive == type(uint256).max) {
            return targets;
        }

        for (uint256 i = 0; i < length; i++) {
            if (!strategies[i].active) {
                targets[i] = 0;
                continue;
            }

            if (i == lastActive) {
                targets[i] = deployableAssets - allocated;
            } else {
                targets[i] = (deployableAssets * strategies[i].targetBps) / BPS_DENOMINATOR;
            }
            allocated += targets[i];
        }

        return targets;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Convert basis points to percentage string (for display)
     * @param bps Basis points value
     * @return whole Whole number percentage
     * @return decimal Decimal part (2 digits)
     */
    function bpsToPercentage(uint16 bps) internal pure returns (uint16 whole, uint16 decimal) {
        whole = bps / 100;
        decimal = bps % 100;
        return (whole, decimal);
    }
}

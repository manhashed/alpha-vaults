// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strategy, StrategyInput} from "../types/VaultTypes.sol";

/**
 * @title IAlphaVault
 * @notice Interface for the AlphaVault - an epoch-based ERC-4626 index vault.
 *
 * @dev ARCHITECTURE
 * ================
 * - Deposits and withdrawals are queued and settled in epochs.
 * - Withdrawals are processed in full-only batches (no partial payouts).
 * - Strategy registry enforces fixed composition across ERC4626, PERPS, and VAULT layers.
 */
interface IAlphaVault is IERC4626 {
    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a deposit is queued
    event DepositQueued(address indexed depositor, address indexed receiver, uint256 assets, uint256 fee, uint256 indexed epoch);

    /// @notice Emitted when shares are minted for a queued deposit
    event DepositSettled(address indexed receiver, uint256 assets, uint256 shares, uint256 indexed epoch);

    /// @notice Emitted when a withdrawal is queued
    event WithdrawalQueued(address indexed owner, address indexed receiver, uint256 assets, uint256 fee, uint256 shares, uint256 indexed epoch);

    /// @notice Emitted when a queued withdrawal is processed
    event WithdrawalProcessed(address indexed owner, address indexed receiver, uint256 assets, uint256 fee, uint256 indexed epoch);

    /// @notice Emitted when an epoch is settled
    event EpochSettled(uint256 indexed epoch, uint256 depositAssets, uint256 withdrawAssets, uint256 sharesMinted);

    /// @notice Emitted when strategy registry is updated
    event StrategyRegistryUpdated(StrategyInput[] strategies);

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when reserve configuration is updated
    event ReserveConfigUpdated(uint16 floorBps, uint16 targetBps, uint16 ceilBps);

    /// @notice Emitted when deposit fee is updated
    event DepositFeeUpdated(uint16 oldFee, uint16 newFee);

    /// @notice Emitted when withdrawal fee is updated
    event WithdrawFeeUpdated(uint16 oldFee, uint16 newFee);

    /// @notice Emitted when CoreDepositor address is updated
    event CoreDepositorUpdated(address indexed oldCoreDepositor, address indexed newCoreDepositor);

    /// @notice Emitted when deployment pause flag changes
    event DeploymentPaused(bool paused);

    /// @notice Emitted when deployment configuration is updated
    event DeploymentConfigUpdated(uint256 interval, uint256 maxBatchAmount);

    /// @notice Emitted when deployment operator is updated
    event DeploymentOperatorUpdated(address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when a deployment batch executes
    event DeploymentExecuted(uint256 assetsDeployed, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error InvalidAmount();
    error InvalidTreasury();
    error StrategyRegistryEmpty();
    error StrategyNotFound();
    error FeeTooHigh(uint16 fee, uint16 maxFee);
    error ReserveConfigInvalid();
    error InsufficientWithdrawableLiquidity(uint256 required, uint256 available);
    error DeploymentTooSoon(uint256 nextAllowedTimestamp);
    error DeploymentUnauthorized();

    // ═══════════════════════════════════════════════════════════════════════════
    // EPOCH FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get current epoch ID based on timestamp
    function getCurrentEpoch() external view returns (uint256 epochId);

    /// @notice Get seconds until current epoch ends
    function getTimeUntilNextEpoch() external view returns (uint256 seconds_);

    /// @notice Settle an epoch - process all deposits and withdrawals
    function settleEpoch(uint256 epochId) external;

    /// @notice Get epoch summary (deposit assets, withdrawal requests, settled status)
    function getEpochSummary(uint256 epochId) external view returns (
        uint256 pendingDepositAssets,
        uint256 withdrawalCount,
        bool settled
    );

    /// @notice Get pending deposits count for epoch
    function getEpochDepositCount(uint256 epochId) external view returns (uint256 count);

    /// @notice Get pending withdrawals count for epoch
    function getEpochWithdrawalCount(uint256 epochId) external view returns (uint256 count);

    // ═══════════════════════════════════════════════════════════════════════════
    // STRATEGY & ADAPTER VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get strategy registry
    function getStrategies() external view returns (Strategy[] memory strategies);

    /// @notice Get withdrawable liquidity (L1 + L2 + L3)
    function getWithdrawableLiquidity() external view returns (uint256 assets);

    /// @notice Get reserve configuration (floor/target/ceiling bps)
    function getReserveConfig() external view returns (uint16 floorBps, uint16 targetBps, uint16 ceilBps);

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Execute a deployment batch (L1 -> strategies). Non-atomic, keeper-driven.
    function deployBatch() external returns (uint256 deployedAssets);

    /// @notice Process queued withdrawals using current liquidity (after epoch end).
    function processQueuedWithdrawals() external returns (uint256 assetsPaid);

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update strategy registry (replaces entire set)
    function setStrategies(StrategyInput[] calldata inputs) external;

    /// @notice Set treasury address
    function setTreasury(address newTreasury) external;

    /// @notice Set epoch length in seconds
    function setEpochLength(uint256 epochLength) external;

    /// @notice Set deposit fee in basis points (max 1000 = 10%)
    function setDepositFee(uint16 depositFeeBps) external;

    /// @notice Set withdrawal fee in basis points (max 1000 = 10%)
    function setWithdrawFee(uint16 withdrawFeeBps) external;

    /// @notice Set reserve configuration (floor/target/ceiling bps)
    function setReserveConfig(uint16 floorBps, uint16 targetBps, uint16 ceilBps) external;

    /// @notice Set CoreDepositor address
    function setCoreDepositor(address coreDepositor) external;

    /// @notice Set deployment cadence and max batch amount
    function setDeploymentConfig(uint256 interval, uint256 maxBatchAmount) external;

    /// @notice Set deployment operator (keeper / Cowriter)
    function setDeploymentOperator(address operator) external;

    /// @notice Get current fees
    function getFees() external view returns (uint16 depositFee, uint16 withdrawFee);
}

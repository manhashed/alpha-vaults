// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title VaultTypes
 * @notice Shared types, enums, and structs for the Alphavaults system
 *
 * @dev ARCHITECTURE OVERVIEW
 * =========================
 * - Single ERC4626 vault on HyperEVM.
 * - Fixed strategy composition across ERC4626, PERPS, and VAULT layers.
 * - Epoch-based batching for deposits and withdrawals.
 * - All withdrawals are all-or-nothing and processed in batches.
 */

// ═══════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Strategy types for allocation layers
enum StrategyType {
    ERC4626, // HyperEVM ERC4626 protocols (L2)
    PERPS,   // HyperCore perps USDC balance (L3)
    VAULT    // HyperCore trading vaults (L4)
}

// ═══════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Strategy configuration entry
/// @param adapter Address of adapter (zero for PERPS)
/// @param targetBps Target allocation in basis points (10000 = 100%)
/// @param strategyType Strategy category (ERC4626 | PERPS | VAULT)
/// @param active Whether this strategy is active
struct Strategy {
    address adapter;
    uint16 targetBps;
    StrategyType strategyType;
    bool active;
}

/// @notice Input for adding/updating strategies
struct StrategyInput {
    address adapter;
    uint16 targetBps;
    StrategyType strategyType;
    bool active;
}

/// @notice Withdrawal request stored in queue
struct WithdrawalRequest {
    address owner;
    address receiver;
    uint256 assets;
    uint256 shares;
    uint256 epoch;
}

// ═══════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Basis points denominator (100% = 10000)
uint16 constant BPS_DENOMINATOR = 10_000;

/// @dev Maximum number of strategies
uint8 constant MAX_STRATEGIES = 12;

/// @dev Minimum allocation for an active strategy (0.1% = 10 bps)
uint16 constant MIN_STRATEGY_BPS = 10;

/// @dev USDC decimals
uint8 constant USDC_DECIMALS = 6;

/// @dev Default epoch length (weekly)
uint256 constant DEFAULT_EPOCH_LENGTH = 7 days;

/// @dev Default deployment interval (daily)
uint256 constant DEFAULT_DEPLOYMENT_INTERVAL = 1 days;

/// @dev Default deposit fee (1% = 100 bps)
uint16 constant DEFAULT_DEPOSIT_FEE_BPS = 100;

/// @dev Default withdrawal fee (1% = 100 bps)
uint16 constant DEFAULT_WITHDRAW_FEE_BPS = 100;

/// @dev Maximum allowed fee (10% = 1000 bps)
uint16 constant MAX_FEE_BPS = 1_000;

/// @dev Liquidity reserve configuration (35%–45% of totalAssets)
uint16 constant DEFAULT_RESERVE_FLOOR_BPS = 3_500;
uint16 constant DEFAULT_RESERVE_TARGET_BPS = 4_000;
uint16 constant DEFAULT_RESERVE_CEIL_BPS = 4_500;

/// @dev Default perp DEX index (HyperCore)
uint32 constant DEFAULT_PERP_DEX_INDEX = 0;

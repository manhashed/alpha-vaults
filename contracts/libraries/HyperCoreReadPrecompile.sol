// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title HyperCoreReadPrecompile
 * @notice Library for reading HyperCore state via L1 read precompiles
 * @dev Based on official L1Read.sol reference. Precompile addresses 0x800-0x811.
 *      Read precompiles for TVL (Vault equity, Spot balance, Perp PnL)
 * 
 * PRECOMPILE ADDRESSES (from L1Read.sol):
 * =======================================
 * 0x801: spotBalance(address user, uint64 token) → SpotBalance
 * 0x802: userVaultEquity(address user, address vault) → UserVaultEquity  
 * 0x80F: accountMarginSummary(uint32 perpDexIndex, address user) → AccountMarginSummary
 */
library HyperCoreReadPrecompile {
    // ═══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS (gas-efficient error handling)
    // ═══════════════════════════════════════════════════════════════════════════

    error SpotBalancePrecompileCallFailed();
    error VaultEquityPrecompileCallFailed();
    error AccountMarginSummaryPrecompileCallFailed();

    /// @notice HyperCore USD scale (10^8)
    uint64 constant USD_SCALE = 1e8;

    /// @notice USDC decimals on HyperEVM (10^6)
    uint64 constant USDC_DECIMALS = 1e6;

    // ═══════════════════════════════════════════════════════════════════════════
    // PRECOMPILE ADDRESSES (from L1Read.sol)
    // ═══════════════════════════════════════════════════════════════════════════

    address constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address constant VAULT_EQUITY_PRECOMPILE = 0x0000000000000000000000000000000000000802;
    address constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS (matching L1Read.sol)
    // ═══════════════════════════════════════════════════════════════════════════

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct UserVaultEquity {
        uint64 equity;
        uint64 lockedUntilTimestamp;
    }

    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // READ FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Query spot balance for a token
     * @param user The user address
     * @param tokenId Token ID (0 = USDC)
     * @return balance The total spot balance
     */
    function getSpotBalance(address user, uint64 tokenId) internal view returns (uint64 balance) {
        (bool success, bytes memory result) = SPOT_BALANCE_PRECOMPILE.staticcall(
            abi.encode(user, tokenId)
        );
        if (!success || result.length == 0) revert SpotBalancePrecompileCallFailed();
        SpotBalance memory spotBal = abi.decode(result, (SpotBalance));
        return spotBal.total;
    }

    /**
     * @notice Query user's equity in a vault
     * @param user The user address
     * @param vault The vault address
     * @return equity The user's equity in the vault
     * @return lockedUntilTimestamp When the equity unlocks
     */
    function getUserVaultEquity(
        address user, 
        address vault
    ) internal view returns (uint64 equity, uint64 lockedUntilTimestamp) {
        (bool success, bytes memory result) = VAULT_EQUITY_PRECOMPILE.staticcall(
            abi.encode(user, vault)
        );
        if (!success || result.length == 0) revert VaultEquityPrecompileCallFailed();
        UserVaultEquity memory vaultEquity = abi.decode(result, (UserVaultEquity));
        return (vaultEquity.equity, vaultEquity.lockedUntilTimestamp);
    }

    /**
     * @notice Query account margin summary (perp equity and PnL)
     * @param perpDexIndex The perp DEX index (usually 0)
     * @param user The user address
     * @return accountValue The account value (includes unrealized PnL)
     * @return rawUsd The raw USD 
     */
    function getAccountMarginSummary(
        uint32 perpDexIndex, 
        address user
    ) internal view returns (int64 accountValue, int64 rawUsd) {
        (bool success, bytes memory result) = ACCOUNT_MARGIN_SUMMARY_PRECOMPILE.staticcall(
            abi.encode(perpDexIndex, user)
        );
        if (!success || result.length == 0) revert AccountMarginSummaryPrecompileCallFailed();
        AccountMarginSummary memory summary = abi.decode(result, (AccountMarginSummary));
        return (summary.accountValue, summary.rawUsd);
    }

    /**
     * @notice Get perps raw USDC balance (scaled 10^8)
     * @param perpDexIndex The perp DEX index (usually 0)
     * @param user The user address
     * @return rawUsd Raw USD balance (signed, 10^8 scale)
     */
    function getPerpsRawUsd(
        uint32 perpDexIndex,
        address user
    ) internal view returns (int64 rawUsd) {
        (, int64 rawUsd_) = getAccountMarginSummary(perpDexIndex, user);
        return rawUsd_;
    }

    /**
     * @notice Get perps USDC balance in HyperEVM decimals (10^6)
     * @param perpDexIndex The perp DEX index (usually 0)
     * @param user The user address
     * @return balance USDC balance (signed, 10^6 scale)
     */
    function getPerpsUsdcBalance(
        uint32 perpDexIndex,
        address user
    ) internal view returns (int256 balance) {
        int64 rawUsd = getPerpsRawUsd(perpDexIndex, user);
        return (int256(rawUsd) * int256(uint256(USDC_DECIMALS))) / int256(uint256(USD_SCALE));
    }

    /**
     * @notice Convert HyperCore USD scale (1e8) to USDC decimals (1e6)
     * @param scaledAmount Amount in 1e8 scale
     * @return usdcAmount Amount in 1e6 scale
     */
    function scaleCoreToUSDC(uint64 scaledAmount) internal pure returns (uint256 usdcAmount) {
        return (uint256(scaledAmount) * uint256(USDC_DECIMALS)) / uint256(USD_SCALE);
    }
}

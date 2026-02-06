// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IHyperCoreRead
 * @notice Interface for reading HyperCore state via precompiles
 * @dev Based on official L1Read.sol reference from Hyperliquid.
 *      https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore
 * 
 * PRECOMPILE ADDRESSES (from L1Read.sol):
 * =======================================
 * 0x801: spotBalance(address user, uint64 token) → SpotBalance
 * 0x802: userVaultEquity(address user, address vault) → UserVaultEquity  
 * 0x80F: accountMarginSummary(uint32 perpDexIndex, address user) → AccountMarginSummary
 */
interface IHyperCoreRead {
    
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
    // SPOT BALANCE (Precompile 0x801)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the spot balance for a specific token
     * @param user The address to query
     * @param tokenId The token ID (0 = USDC, 150 = HYPE mainnet, 1105 = HYPE testnet)
     * @return balance The SpotBalance struct with total, hold, and entryNtl
     */
    function getSpotBalance(address user, uint64 tokenId) external view returns (SpotBalance memory balance);

    // ═══════════════════════════════════════════════════════════════════════════
    // USER VAULT EQUITY (Precompile 0x802)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get user's equity in a HyperCore vault (HLP, trading vault)
     * @param user The depositor address
     * @param vault The vault address
     * @return vaultEquity The UserVaultEquity struct with equity and lockup timestamp
     */
    function getUserVaultEquity(address user, address vault) external view returns (UserVaultEquity memory vaultEquity);

    // ═══════════════════════════════════════════════════════════════════════════
    // ACCOUNT MARGIN SUMMARY (Precompile 0x80F)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get account margin summary (perp equity and PnL)
     * @param perpDexIndex The perp DEX index (usually 0)
     * @param user The address to query
     * @return summary The AccountMarginSummary with accountValue, marginUsed, ntlPos, rawUsd
     */
    function getAccountMarginSummary(uint32 perpDexIndex, address user) external view returns (AccountMarginSummary memory summary);
}

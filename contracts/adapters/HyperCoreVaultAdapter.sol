// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseVaultAdapter} from "./BaseVaultAdapter.sol";
import {HyperCoreReadPrecompile} from "../libraries/HyperCoreReadPrecompile.sol";

/**
 * @title HyperCoreVaultAdapter
 * @notice Read-only adapter for HyperCore vaults (HLP + trading vaults).
 * @dev Reports vault equity and lockup status for the AlphaVault address.
 */
contract HyperCoreVaultAdapter is BaseVaultAdapter {
    /// @notice The HyperCore vault address (HLP or trading vault)
    address public hypercoreVault;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the adapter
     * @param asset_ USDC token address
     * @param vault_ AlphaVault address (used as HyperCore account)
     * @param hypercoreVault_ HyperCore vault address (HLP or trading vault)
     * @param name_ Human-readable adapter name
     * @param owner_ Owner for admin functions
     */
    function initialize(
        address asset_,
        address vault_,
        address hypercoreVault_,
        string memory name_,
        address owner_
    ) external initializer {
        if (hypercoreVault_ == address(0)) revert ZeroAddress();

        __BaseVaultAdapter_init(asset_, vault_, hypercoreVault_, name_, owner_);
        hypercoreVault = hypercoreVault_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS - READ ONLY
    // ═══════════════════════════════════════════════════════════════════════════

    function deposit(uint256) external override onlyVault returns (uint256) {
        revert ProtocolOperationFailed();
    }

    function withdraw(uint256) external override onlyVault returns (uint256) {
        revert ProtocolOperationFailed();
    }

    /**
     * @notice Get TVL from HyperCore vault equity (USDC 6 decimals)
     */
    function getTVL() external view override returns (uint256 tvl) {
        (uint64 equity,) = HyperCoreReadPrecompile.getUserVaultEquity(_vault, hypercoreVault);
        return HyperCoreReadPrecompile.scaleCoreToUSDC(equity);
    }

    /**
     * @notice Get maximum withdrawable amount right now
     * @return maxAmount Vault equity if unlocked, 0 if locked
     */
    function maxWithdraw() external view override returns (uint256 maxAmount) {
        uint256 unlockTime = getUnlockTime();
        if (unlockTime != 0 && block.timestamp < unlockTime) {
            return 0;
        }
        return this.getTVL();
    }

    /**
     * @notice HyperCore doesn't use receipt tokens
     */
    function getReceiptToken() external pure override returns (address) {
        return address(0);
    }

    /**
     * @notice Get the underlying HyperCore vault address
     */
    function getUnderlyingVault() external view returns (address) {
        return hypercoreVault;
    }

    /**
     * @notice Get the unlock timestamp for the current position
     */
    function getUnlockTime() public view returns (uint256 unlockTime) {
        (, uint64 lockedUntil) = HyperCoreReadPrecompile.getUserVaultEquity(_vault, hypercoreVault);
        return _normalizeLockedUntil(lockedUntil);
    }

    /**
     * @notice Check if withdrawal is currently possible
     * @return isUnlocked_ True if funds can be withdrawn
     * @return timeRemaining Seconds until unlock (0 if already unlocked)
     */
    function isUnlocked() external view returns (bool isUnlocked_, uint256 timeRemaining) {
        uint256 unlockTime = getUnlockTime();
        if (unlockTime == 0 || block.timestamp >= unlockTime) {
            return (true, 0);
        }
        return (false, unlockTime - block.timestamp);
    }

    function _normalizeLockedUntil(uint64 lockedUntil) internal pure returns (uint256) {
        if (lockedUntil == 0) return 0;

        uint256 normalized = lockedUntil;

        // Normalize milliseconds to seconds when necessary
        if (normalized > 1e12) {
            normalized = normalized / 1000;
        }

        // Sentinel values beyond year 2100 are treated as unlocked
        if (normalized > 4_102_444_800) {
            return 0;
        }

        return normalized;
    }
}

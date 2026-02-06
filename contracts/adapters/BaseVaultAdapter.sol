// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultAdapter} from "../interfaces/IVaultAdapter.sol";

/**
 * @title BaseVaultAdapter
 * @notice Abstract base contract for all vault adapters in the Alphavaults system.
 * @dev Provides common functionality:
 *      - Ownership (only AlphaVault can deposit/withdraw)
 *      - Pausable functionality
 *      - Asset (USDC) storage and management
 *
 * VAULT-ONLY CUSTODY MODEL:
 * -------------------------
 * Adapters are stateless executors. They should not hold assets between calls.
 * All receipt tokens (protocol shares, aTokens, etc.) belong to AlphaVault.
 */
abstract contract BaseVaultAdapter is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IVaultAdapter
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The underlying asset (USDC)
    IERC20 internal _asset;

    /// @notice The AlphaVault that owns this adapter
    address internal _vault;

    /// @notice The underlying protocol address (Felix vault, HyperCore vaults, etc.)
    address internal _underlyingProtocol;

    /// @notice Human-readable adapter name
    string internal _name;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Restricts function calls to the vault only
    modifier onlyVault() {
        if (msg.sender != _vault) revert Unauthorized();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize base adapter
     * @param asset_ The underlying asset (USDC address)
     * @param vault_ The AlphaVault that owns this adapter
     * @param underlyingProtocol_ The protocol this adapter wraps
     * @param name_ Human-readable adapter name
     * @param owner_ Initial owner (typically deployer, can transfer to vault)
     */
    function __BaseVaultAdapter_init(
        address asset_,
        address vault_,
        address underlyingProtocol_,
        string memory name_,
        address owner_
    ) internal onlyInitializing {
        if (asset_ == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        // NOTE: underlyingProtocol_ may be zero for adapters that don't wrap
        // a single external protocol address.

        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();

        _asset = IERC20(asset_);
        _vault = vault_;
        _underlyingProtocol = underlyingProtocol_;
        _name = name_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IVaultAdapter - VIEW FUNCTIONS (Common implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultAdapter
    function asset() external view override returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IVaultAdapter
    function vault() external view override returns (address) {
        return _vault;
    }

    /// @inheritdoc IVaultAdapter
    function underlyingProtocol() external view override returns (address) {
        return _underlyingProtocol;
    }

    /// @inheritdoc IVaultAdapter
    function paused() public view override(IVaultAdapter, PausableUpgradeable) returns (bool) {
        return PausableUpgradeable.paused();
    }

    /// @inheritdoc IVaultAdapter
    function getName() external view override returns (string memory) {
        return _name;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IVaultAdapter - DEFAULTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultAdapter
    /// @dev Default: maxWithdraw equals current TVL
    function maxWithdraw() external view virtual override returns (uint256) {
        return this.getTVL();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT FUNCTIONS (Must be implemented by child adapters)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultAdapter
    function deposit(uint256 amount) external virtual override returns (uint256 protocolShares);

    /// @inheritdoc IVaultAdapter
    function withdraw(uint256 amount) external virtual override returns (uint256 actualAmount);

    /// @inheritdoc IVaultAdapter
    function getTVL() external view virtual override returns (uint256 tvl);

    /// @inheritdoc IVaultAdapter
    /// @dev Default: returns zero address. Override in child adapters to return
    ///      the protocol-specific receipt token (Felix shares, aToken, etc.).
    ///      HyperCore adapters may return zero as positions are tracked via precompiles.
    function getReceiptToken() external view virtual override returns (address) {
        return address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause the adapter
     * @dev Only owner can pause. When paused, deposits/withdrawals revert.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the adapter
     * @dev Only owner can unpause.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update the vault address
     * @dev Only owner can change. Use with caution.
     * @param newVault New AlphaVault address
     */
    function setVault(address newVault) external onlyOwner {
        if (newVault == address(0)) revert ZeroAddress();
        address oldVault = _vault;
        _vault = newVault;
        emit VaultUpdated(oldVault, newVault);
    }

    /**
     * @notice Emergency recover stuck USDC to owner
     * @dev In vault-only custody model, adapters hold ZERO tokens normally.
     *      This function recovers any USDC that may have gotten stuck due to
     *      failed transactions, donation attacks, or other edge cases.
     *      Child adapters should override to also handle protocol-specific tokens.
     */
    function emergencyWithdraw() external virtual onlyOwner nonReentrant {
        // Transfer any stuck USDC to owner (should be zero in normal operation)
        uint256 balance = _asset.balanceOf(address(this));
        if (balance > 0) {
            _asset.safeTransfer(owner(), balance);
        }
    }

    /**
     * @notice Recover any tokens sent directly to adapter (donation attack protection)
     * @dev In vault-only custody model, adapters should NEVER hold tokens.
     *      This allows owner to recover any mistakenly sent or donated tokens.
     *      Donations are not counted in getTVL() (TVL reads vault's balance).
     * @param token Address of token to recover
     * @param to Address to send recovered tokens
     * @return recovered Amount of tokens recovered
     */
    function recoverTokens(address token, address to) external onlyOwner nonReentrant returns (uint256 recovered) {
        if (to == address(0)) revert ZeroAddress();
        recovered = IERC20(token).balanceOf(address(this));
        if (recovered > 0) {
            IERC20(token).safeTransfer(to, recovered);
            emit TokensRecovered(token, to, recovered);
        }
    }
}

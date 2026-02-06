// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseVaultAdapter} from "./BaseVaultAdapter.sol";

/**
 * @title FelixAdapter
 * @notice Adapter for Felix ERC-4626 vault integration with AlphaVault.
 * @dev Stateless executor that deposits/withdraws on behalf of AlphaVault.
 *      This is a SYNC adapter - withdrawals are immediate with no lockup.
 *
 * VAULT-ONLY CUSTODY MODEL:
 * -------------------------
 * This adapter NEVER holds assets. All receipt tokens (Felix shares) are held
 * by AlphaVault. The adapter acts as a stateless execution layer:
 *   - Deposits: Receives USDC, deposits to Felix with vault as receiver
 *   - Withdrawals: Receives shares from vault, redeems to vault
 *   - TVL: Reads vault's Felix share balance
 *
 * PROTOCOL DETAILS:
 * -----------------
 * - Felix is an ERC-4626 compliant vault on HyperEVM
 * - Underlying asset: USDC
 * - Share token: Felix vault shares (held by AlphaVault)
 * - Yield: Accrues through share price appreciation
 *
 * ADAPTER FLOW:
 * -------------
 * Deposit:
 *   1. AlphaVault transfers USDC to this adapter
 *   2. Adapter approves Felix vault
 *   3. Adapter calls felixVault.deposit(assets, vault) - shares go to VAULT
 *   4. Adapter returns with zero balance
 *
 * Withdraw:
 *   1. AlphaVault transfers Felix shares to this adapter
 *   2. AlphaVault calls adapter.withdraw(amount)
 *   3. Adapter redeems shares, sending USDC to vault
 *   4. Adapter returns with zero balance
 *
 * TVL:
 *   - getTVL() = felixVault.convertToAssets(vault's share balance)
 */
contract FelixAdapter is BaseVaultAdapter {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Reference to the Felix ERC-4626 vault
    IERC4626 public felixVault;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Felix adapter
     * @param asset_ USDC token address
     * @param vault_ AlphaVault address (owner of this adapter)
     * @param felixVault_ Felix ERC-4626 vault address (network-specific)
     * @param owner_ Initial owner for admin functions
     */
    function initialize(
        address asset_,
        address vault_,
        address felixVault_,
        address owner_
    ) external initializer {
        if (felixVault_ == address(0)) revert ZeroAddress();
        
        __BaseVaultAdapter_init(
            asset_,
            vault_,
            felixVault_,
            "Felix Lending",
            owner_
        );

        felixVault = IERC4626(felixVault_);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IVaultAdapter - CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDC into Felix vault on behalf of AlphaVault
     * @dev USDC must already be transferred to this adapter before calling.
     *      Felix shares are sent directly to AlphaVault (not this adapter).
     *      Only callable by the vault.
     * @param amount Amount of USDC to deposit (6 decimals)
     * @return protocolShares Amount of Felix vault shares sent to vault
     */
    function deposit(uint256 amount)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 protocolShares)
    {
        if (amount == 0) revert InvalidAmount();

        // Verify we have the USDC
        uint256 balance = _asset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Approve Felix vault to spend USDC
        _asset.safeIncreaseAllowance(address(felixVault), amount);

        // Deposit to Felix vault, shares go directly to AlphaVault (not this adapter)
        protocolShares = felixVault.deposit(amount, _vault);

        if (protocolShares == 0) revert ProtocolOperationFailed();

        emit Deposited(msg.sender, amount, protocolShares);
    }

    /**
     * @notice Withdraw USDC from Felix vault on behalf of AlphaVault
     * @dev AlphaVault must transfer Felix shares to this adapter BEFORE calling.
     *      Adapter withdraws EXACT amount requested and returns excess shares to vault.
     *      Only callable by the vault.
     * @param amount Amount of USDC to withdraw (6 decimals)
     * @return actualAmount Actual USDC amount withdrawn
     */
    function withdraw(uint256 amount)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 actualAmount)
    {
        if (amount == 0) revert InvalidAmount();

        // AlphaVault transfers shares to adapter before calling withdraw()
        // Check we have enough shares (transferred from vault)
        uint256 sharesNeeded = felixVault.previewWithdraw(amount);
        uint256 sharesBalance = felixVault.balanceOf(address(this));
        if (sharesBalance < sharesNeeded) revert InsufficientBalance();

        // Withdraw EXACT amount requested - burns only shares needed, USDC to vault
        // CRITICAL: Use withdraw() not redeem() to ensure exact amount accounting
        uint256 sharesBurned = felixVault.withdraw(amount, _vault, address(this));

        if (sharesBurned == 0) revert ProtocolOperationFailed();

        // Return any excess shares to vault (maintains vault-only custody)
        uint256 excessShares = sharesBalance - sharesBurned;
        if (excessShares > 0) {
            IERC20(address(felixVault)).safeTransfer(_vault, excessShares);
        }

        actualAmount = amount;
        emit Withdrawn(msg.sender, actualAmount, sharesBurned);
    }

    /**
     * @notice Get total value locked in Felix vault (in USDC)
     * @dev Reads AlphaVault's Felix share balance and converts to USDC.
     *      Adapter itself holds zero shares - all positions belong to vault.
     * @return tvl Total value in USDC (6 decimals)
     */
    function getTVL() external view override returns (uint256 tvl) {
        // Read vault's Felix share balance (not adapter's)
        uint256 shares = felixVault.balanceOf(_vault);
        if (shares == 0) return 0;
        tvl = felixVault.convertToAssets(shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the receipt token address (Felix vault shares)
     * @dev AlphaVault holds these shares; adapter is a stateless executor
     * @return receiptToken The Felix vault share token address
     */
    function getReceiptToken() external view override returns (address receiptToken) {
        return address(felixVault);
    }

    /**
     * @notice Get vault's Felix share balance (the position this adapter manages)
     * @dev Adapter holds zero shares; positions belong to AlphaVault
     * @return shares Number of Felix vault shares held by AlphaVault
     */
    function getVaultShares() external view returns (uint256 shares) {
        return felixVault.balanceOf(_vault);
    }

    /**
     * @notice Preview deposit - how many shares for given assets
     * @param assets USDC amount to deposit
     * @return shares Expected Felix vault shares
     */
    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        return felixVault.previewDeposit(assets);
    }

    /**
     * @notice Preview withdraw - how many shares needed for given assets
     * @param assets USDC amount to withdraw
     * @return shares Felix vault shares needed
     */
    function previewWithdraw(uint256 assets) external view returns (uint256 shares) {
        return felixVault.previewWithdraw(assets);
    }

    /**
     * @notice Preview redeem - how many assets for given shares
     * @param shares Felix vault shares to redeem
     * @return assets Expected USDC amount
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        return felixVault.previewRedeem(shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EMERGENCY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emergency recover any stuck tokens
     * @dev In normal operation, adapter holds zero tokens (vault-only custody).
     *      This function recovers any tokens that may have gotten stuck due to
     *      failed transactions, donation attacks, or other edge cases.
     *      Redeems any Felix shares and transfers all USDC to owner.
     */
    function emergencyWithdraw() external override onlyOwner nonReentrant {
        // Redeem any Felix shares that may be stuck in adapter
        // (should be zero in normal operation)
        uint256 shares = felixVault.balanceOf(address(this));
        if (shares > 0) {
            felixVault.redeem(shares, owner(), address(this));
        }

        // Transfer any USDC balance to owner
        // (should be zero in normal operation)
        uint256 usdcBalance = _asset.balanceOf(address(this));
        if (usdcBalance > 0) {
            _asset.safeTransfer(owner(), usdcBalance);
        }
    }
}

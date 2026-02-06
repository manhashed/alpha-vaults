// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVaultAdapter
 * @notice Standard interface for strategy adapters in the Alphavaults system.
 * @dev Adapters wrap protocol-specific logic for ERC4626 and HyperCore vaults.
 */
interface IVaultAdapter {
    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when assets are deposited into the underlying protocol
    event Deposited(address indexed caller, uint256 amount, uint256 protocolShares);

    /// @notice Emitted when assets are withdrawn from the underlying protocol
    event Withdrawn(address indexed caller, uint256 amount, uint256 protocolShares);

    /// @notice Emitted when tokens are recovered by owner (donation protection)
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when vault address is updated
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when deposit amount is zero or invalid
    error InvalidAmount();

    /// @notice Thrown when withdrawal amount exceeds available balance
    error InsufficientBalance();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when the underlying protocol operation fails
    error ProtocolOperationFailed();

    /// @notice Thrown when adapter is paused
    error AdapterPaused();

    /// @notice Thrown when withdrawal is still in lockup period
    error WithdrawalLocked(uint256 unlockTime);

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDC into the underlying protocol
     * @dev The adapter should already have USDC transferred to it before calling this.
     *      The caller (AlphaVault) is responsible for transferring USDC.
     * @param amount The amount of USDC to deposit (6 decimals)
     * @return protocolShares The amount of protocol shares/tokens received
     */
    function deposit(uint256 amount) external returns (uint256 protocolShares);

    /**
     * @notice Withdraw USDC from the underlying protocol
     * @dev Read-only adapters should revert; ERC4626 adapters should return actual USDC.
     * @param amount The amount of USDC to withdraw (6 decimals)
     * @return actualAmount The actual amount of USDC withdrawn
     */
    function withdraw(uint256 amount) external returns (uint256 actualAmount);

    /**
     * @notice Get the total value locked in this adapter in USDC terms
     * @dev This is the primary method for TVL aggregation.
     *      Must return the current value, not the deposited value.
     *      Should account for:
     *      - Protocol share price appreciation/depreciation
     *      - Accrued yield
     *      - Any pending withdrawals
     * @return tvl The total value in USDC (6 decimals)
     */
    function getTVL() external view returns (uint256 tvl);

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the underlying asset (should be USDC)
     * @return asset The address of the underlying asset
     */
    function asset() external view returns (address asset);

    /**
     * @notice Get the vault that owns this adapter
     * @return vault The address of the AlphaVault
     */
    function vault() external view returns (address vault);

    /**
     * @notice Get the underlying protocol address
     * @return protocol The address of the underlying protocol (vault/pool/etc)
     */
    function underlyingProtocol() external view returns (address protocol);

    /**
     * @notice Get the maximum amount that can be withdrawn immediately
     * @dev For sync adapters, this equals getTVL().
     *      For async adapters, this may be less due to liquidity constraints.
     * @return maxAmount The maximum withdrawable amount in USDC (6 decimals)
     */
    function maxWithdraw() external view returns (uint256 maxAmount);

    /**
     * @notice Check if the adapter is currently paused
     * @return isPaused True if the adapter is paused
     */
    function paused() external view returns (bool isPaused);

    // ═══════════════════════════════════════════════════════════════════════════
    // ADAPTER METADATA (Vault fetches these to build its registry)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the human-readable name of this adapter
     * @dev Used by vault to display adapter info without storing name on-chain
     * @return name The adapter name (e.g., "Felix Lending", "HLP Vault")
     */
    function getName() external view returns (string memory name);

    /**
     * @notice Get the receipt token address for this adapter's positions
     * @dev Returns the token that represents positions in the underlying protocol:
     *      - Felix: Felix vault share token (ERC-4626 shares)
     *      - HyperCore: Zero address (positions tracked via precompiles)
     *      AlphaVault holds these receipt tokens; adapters are stateless executors.
     * @return receiptToken The receipt token address, or zero if not applicable
     */
    function getReceiptToken() external view returns (address receiptToken);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


/**
 * @title HyperCoreWritePrecompile
 * @notice Library for writing to HyperCore via CoreWriter precompile
 * @dev Minimal CoreWriter wrapper used by AlphaVault.
 *      Only exposes: sendAsset (perps -> spot) and vaultTransfer.
 *      CoreWriter address: 0x3333...3333
 *
 *      SCALING:
 *      ========
 *      - USD/prices/sizes: 10^8 scale (e.g., 1.23 USDC → 123000000)
 *      - USDC native: 10^6 scale (must convert to 10^8 for HyperCore)
 */
library HyperCoreWritePrecompile {

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice CoreWriter precompile address
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @notice USDC token ID on HyperCore
    uint64 constant USDC_TOKEN_ID = 0;

    /// @notice USD scale for HyperCore (10^8)
    uint64 constant USD_SCALE = 1e8;

    /// @notice USDC native decimals (10^6)
    uint64 constant USDC_DECIMALS = 1e6;

    /// @notice Spot DEX sentinel (uint32::MAX)
    uint32 public constant SPOT_DEX = type(uint32).max;

    // ═══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error CoreWriterActionFailed();
    error InvalidAmount();
    error AmountOverflow();


    // ═══════════════════════════════════════════════════════════════════════════
    // COWRITER ACTION 13 - SEND ASSET
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Send an asset between HyperCore perps and spot (Cowriter Action 13)
     * @dev Uses sendAsset action (ID 0x0D). For spot, use sourceDex or destinationDex = uint32::MAX.
     * @param destination Recipient address
     * @param subAccount Optional subAccount (zero for main)
     * @param sourceDex Source DEX index (0 for perps)
     * @param destinationDex Destination DEX index (uint32::MAX for spot)
     * @param token Token ID (0 for USDC)
     * @param weiAmount Amount in token native scale
     */
    function sendAsset(
        address destination,
        address subAccount,
        uint32 sourceDex,
        uint32 destinationDex,
        uint64 token,
        uint64 weiAmount
    ) internal {
        if (destination == address(0)) revert InvalidAmount();
        if (weiAmount == 0) revert InvalidAmount();

        bytes memory encoded = abi.encode(destination, subAccount, sourceDex, destinationDex, token, weiAmount);
        _executeAction(0x00000d, encoded);
    }


    /**
     * @notice Generic vault transfer (deposit or withdraw)
     * @param vault The vault address
     * @param isDeposit True for deposit, false for withdraw
     * @param usdAmount Amount in scaled USD (10^8)
     */
    function vaultTransfer(address vault, bool isDeposit, uint64 usdAmount) internal {
        if (usdAmount == 0) revert InvalidAmount();
        bytes memory encoded = abi.encode(vault, isDeposit, usdAmount);
        _executeAction(0x000002, encoded);
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Convert USDC amount from native decimals (10^6) to HyperCore scale (10^8)
     * @param usdcAmount Amount in USDC native decimals
     * @return scaledAmount Amount in HyperCore scale (10^8)
     */
    function scaleUSDCToCore(uint256 usdcAmount) internal pure returns (uint64 scaledAmount) {
        uint256 scaled = usdcAmount * USD_SCALE / USDC_DECIMALS;
        if (scaled > type(uint64).max) revert AmountOverflow();
        // casting to uint64 is safe because of overflow check above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(scaled);
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Internal executor for CoreWriter actions
     * @dev Encodes version (0x01) + 3-byte ID + fields
     * @param actionId 3-byte action ID (e.g., 0x000001)
     * @param encoded ABI-encoded action fields
     */
    function _executeAction(uint24 actionId, bytes memory encoded) private {
        bytes memory data = new bytes(4 + encoded.length);
        data[0] = 0x01; // Version
        // casting is safe because actionId is uint24 (3 bytes)
        // forge-lint: disable-next-line(unsafe-typecast)
        data[1] = bytes1(uint8(actionId >> 16)); // ID byte 1
        // forge-lint: disable-next-line(unsafe-typecast)
        data[2] = bytes1(uint8(actionId >> 8));  // ID byte 2
        // forge-lint: disable-next-line(unsafe-typecast)
        data[3] = bytes1(uint8(actionId));       // ID byte 3

        for (uint256 i = 0; i < encoded.length; i++) {
            data[4 + i] = encoded[i];
        }

        (bool success, ) = CORE_WRITER.call(abi.encodeWithSignature("sendRawAction(bytes)", data));
        if (!success) revert CoreWriterActionFailed();
    }
}

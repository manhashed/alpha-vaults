// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICoreDepositor
/// @notice Minimal interface for Circle CoreDepositor (HyperEVM -> HyperCore perps)
interface ICoreDepositor {
    /// @notice Deposit USDC to HyperCore (perps only)
    /// @param amount USDC amount in native decimals (10^6)
    /// @param destinationDex Perp DEX index (0 for perps)
    function deposit(uint256 amount, uint32 destinationDex) external;
}

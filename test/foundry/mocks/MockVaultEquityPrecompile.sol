// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockVaultEquityPrecompile
 * @notice Mock implementation of HyperCore's 0x802 userVaultEquity precompile
 * @dev Deploy this contract, then use vm.etch() to inject its bytecode at 0x802
 */
contract MockVaultEquityPrecompile {
    struct UserVaultEquity {
        uint64 equity;
        uint64 lockedUntilTimestamp;
    }

    mapping(address => mapping(address => UserVaultEquity)) public vaultEquity;

    function setVaultEquity(
        address user, 
        address vault, 
        uint64 equity, 
        uint64 lockedUntil
    ) external {
        vaultEquity[user][vault] = UserVaultEquity(equity, lockedUntil);
    }

    function getVaultEquity(address user, address vault) external view returns (UserVaultEquity memory) {
        return vaultEquity[user][vault];
    }

    /// @notice Fallback to handle staticcall with abi.encode(address, address)
    fallback(bytes calldata data) external returns (bytes memory) {
        (address user, address vault) = abi.decode(data, (address, address));
        return abi.encode(vaultEquity[user][vault]);
    }
}

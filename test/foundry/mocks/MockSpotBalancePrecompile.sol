// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockSpotBalancePrecompile
 * @notice Mock implementation of HyperCore's 0x801 spotBalance precompile
 * @dev Deploy this contract, then use vm.etch() to inject its bytecode at 0x801
 * 
 * Usage in Foundry tests:
 *   MockSpotBalancePrecompile mock = new MockSpotBalancePrecompile();
 *   vm.etch(0x0000000000000000000000000000000000000801, address(mock).code);
 *   mock.setSpotBalance(user, tokenId, total, hold, entryNtl);
 */
contract MockSpotBalancePrecompile {
    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    mapping(address => mapping(uint64 => SpotBalance)) public spotBalances;

    function setSpotBalance(
        address user, 
        uint64 tokenId, 
        uint64 total, 
        uint64 hold, 
        uint64 entryNtl
    ) external {
        spotBalances[user][tokenId] = SpotBalance(total, hold, entryNtl);
    }

    function getSpotBalance(address user, uint64 tokenId) external view returns (SpotBalance memory) {
        return spotBalances[user][tokenId];
    }

    /// @notice Fallback to handle staticcall with abi.encode(address, uint64)
    fallback(bytes calldata data) external returns (bytes memory) {
        (address user, uint64 tokenId) = abi.decode(data, (address, uint64));
        return abi.encode(spotBalances[user][tokenId]);
    }
}

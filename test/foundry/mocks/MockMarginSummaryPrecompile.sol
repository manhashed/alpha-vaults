// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockMarginSummaryPrecompile
 * @notice Mock implementation of HyperCore's 0x80F accountMarginSummary precompile
 * @dev Deploy this contract, then use vm.etch() to inject its bytecode at 0x80F
 */
contract MockMarginSummaryPrecompile {
    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    mapping(uint32 => mapping(address => AccountMarginSummary)) public marginSummary;

    function setMarginSummary(
        uint32 perpDexIndex,
        address user, 
        int64 accountValue, 
        uint64 marginUsed,
        uint64 ntlPos,
        int64 rawUsd
    ) external {
        marginSummary[perpDexIndex][user] = AccountMarginSummary(accountValue, marginUsed, ntlPos, rawUsd);
    }

    function getMarginSummary(uint32 perpDexIndex, address user) external view returns (AccountMarginSummary memory) {
        return marginSummary[perpDexIndex][user];
    }

    /// @notice Fallback to handle staticcall with abi.encode(uint32, address)
    fallback(bytes calldata data) external returns (bytes memory) {
        (uint32 perpDexIndex, address user) = abi.decode(data, (uint32, address));
        return abi.encode(marginSummary[perpDexIndex][user]);
    }
}

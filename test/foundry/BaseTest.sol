// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMarginSummaryPrecompile} from "./mocks/MockMarginSummaryPrecompile.sol";

/**
 * @title BaseTest
 * @notice Base test contract with common setup, utilities, and constants
 * @dev All test contracts should inherit from this
 */
abstract contract BaseTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - MAINNET
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant MAINNET_CHAIN_ID = 999;
    string public constant MAINNET_RPC = "https://rpc.hyperliquid.xyz/evm";

    // Mainnet addresses
    address public constant MAINNET_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address public constant MAINNET_FELIX_VAULT = 0x8A862fD6c12f9ad34C9c2ff45AB2b6712e8CEa27;

    // HyperCore precompile addresses
    address internal constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE =
        0x000000000000000000000000000000000000080F;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - TESTNET
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant TESTNET_CHAIN_ID = 998;
    string public constant TESTNET_RPC = "https://rpc.hyperliquid-testnet.xyz/evm";

    // Testnet addresses
    address public constant TESTNET_USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - GENERAL
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant ONE_USDC = 10 ** USDC_DECIMALS;
    uint256 public constant MILLION_USDC = 1_000_000 * ONE_USDC;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST ACTORS
    // ═══════════════════════════════════════════════════════════════════════════

    address public owner;
    address public alice;
    address public bob;
    address public charlie;
    address public keeper;
    address public treasury;

    // ═══════════════════════════════════════════════════════════════════════════
    // MOCK TOKENS
    // ═══════════════════════════════════════════════════════════════════════════

    IERC20 public usdc;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Create labeled addresses for test actors
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        keeper = makeAddr("keeper");
        treasury = makeAddr("treasury");

        // Label well-known addresses
        vm.label(MAINNET_USDC, "USDC_Mainnet");
        vm.label(TESTNET_USDC, "USDC_Testnet");
        vm.label(MAINNET_FELIX_VAULT, "Felix_Vault");

        // Mock HyperCore accountMarginSummary precompile for local tests
        MockMarginSummaryPrecompile marginImpl = new MockMarginSummaryPrecompile();
        vm.etch(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, address(marginImpl).code);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deal USDC to an address (works with mock or forked USDC)
     * @param to Address to receive USDC
     * @param amount Amount of USDC (with decimals)
     */
    function dealUSDC(address to, uint256 amount) internal {
        deal(address(usdc), to, amount);
    }

    /**
     * @notice Approve USDC spending for a spender
     * @param spender Address to approve
     * @param amount Amount to approve
     */
    function approveUSDC(address spender, uint256 amount) internal {
        usdc.approve(spender, amount);
    }

    /**
     * @notice Get USDC balance of an address
     * @param account Address to check
     * @return balance USDC balance
     */
    function getUSDCBalance(address account) internal view returns (uint256 balance) {
        return usdc.balanceOf(account);
    }

    /**
     * @notice Convert human-readable USDC amount to wei
     * @param amount Human readable amount (e.g., 1000 for $1000)
     * @return amountWei Amount in USDC decimals
     */
    function toUSDC(uint256 amount) internal pure returns (uint256 amountWei) {
        return amount * ONE_USDC;
    }

    /**
     * @notice Convert USDC wei to human-readable amount
     * @param amountWei Amount in USDC decimals
     * @return amount Human readable amount
     */
    function fromUSDC(uint256 amountWei) internal pure returns (uint256 amount) {
        return amountWei / ONE_USDC;
    }

    /**
     * @notice Calculate percentage in basis points
     * @param amount Base amount
     * @param bps Basis points (e.g., 5000 = 50%)
     * @return result Calculated amount
     */
    function bpsOf(uint256 amount, uint16 bps) internal pure returns (uint256 result) {
        return (amount * bps) / BPS_DENOMINATOR;
    }

    /**
     * @notice Assert two values are approximately equal within tolerance
     * @param a First value
     * @param b Second value
     * @param toleranceBps Tolerance in basis points
     */
    function assertApproxEqBps(uint256 a, uint256 b, uint16 toleranceBps) internal pure {
        uint256 tolerance = bpsOf(b, toleranceBps);
        if (a > b) {
            require(a - b <= tolerance, "Values not approximately equal");
        } else {
            require(b - a <= tolerance, "Values not approximately equal");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FORK HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Fork mainnet at latest block
     * @return forkId The fork ID
     */
    function forkMainnet() internal returns (uint256 forkId) {
        forkId = vm.createFork(MAINNET_RPC);
        vm.selectFork(forkId);
        usdc = IERC20(MAINNET_USDC);
        return forkId;
    }

    /**
     * @notice Fork mainnet at specific block
     * @param blockNumber Block number to fork at
     * @return forkId The fork ID
     */
    function forkMainnetAt(uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(MAINNET_RPC, blockNumber);
        vm.selectFork(forkId);
        usdc = IERC20(MAINNET_USDC);
        return forkId;
    }

    /**
     * @notice Fork testnet at latest block
     * @return forkId The fork ID
     */
    function forkTestnet() internal returns (uint256 forkId) {
        forkId = vm.createFork(TESTNET_RPC);
        vm.selectFork(forkId);
        usdc = IERC20(TESTNET_USDC);
        return forkId;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOGGING HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function logUSDC(string memory label, uint256 amount) internal pure {
        console2.log(string.concat(label, " (USDC):"), fromUSDC(amount));
    }

    function logBps(string memory label, uint16 bps) internal pure {
        console2.log(string.concat(label, " (bps):"), bps);
    }

    function logAddress(string memory label, address addr) internal pure {
        console2.log(label, addr);
    }
}

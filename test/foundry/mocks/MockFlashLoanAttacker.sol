// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAlphaVault} from "../../../contracts/interfaces/IAlphaVault.sol";

/**
 * @title MockFlashLoanAttacker
 * @notice Mock contract to simulate flash loan attacks for security testing
 * @dev Tests TVL manipulation and sandwich attack scenarios
 */
contract MockFlashLoanAttacker {
    using SafeERC20 for IERC20;

    address public vault;
    address public usdc;
    bool public attackSucceeded;
    uint256 public profitMade;

    event AttackAttempted(uint256 depositAmount, uint256 sharesReceived, bool success);

    constructor(address _vault, address _usdc) {
        vault = _vault;
        usdc = _usdc;
    }

    /**
     * @notice Attempt to exploit TVL manipulation
     * @dev Simulates depositing large amount to manipulate share price
     * @param flashLoanAmount Amount of USDC from flash loan
     */
    function attemptTVLManipulation(uint256 flashLoanAmount) external {
        // Record initial state
        // Approve vault
        IERC20(usdc).approve(vault, flashLoanAmount);
        
        // Try to deposit
        try IAlphaVault(vault).deposit(flashLoanAmount, address(this)) returns (uint256 shares) {
            // Try to immediately withdraw to see if we profited
            IAlphaVault(vault).approve(vault, shares);
            uint256 withdrawn = IAlphaVault(vault).redeem(shares, address(this), address(this));
            
            if (withdrawn > flashLoanAmount) {
                attackSucceeded = true;
                profitMade = withdrawn - flashLoanAmount;
            }
            
            emit AttackAttempted(flashLoanAmount, shares, attackSucceeded);
        } catch {
            emit AttackAttempted(flashLoanAmount, 0, false);
        }
    }

    /**
     * @notice Attempt sandwich attack on another user's deposit
     * @param victimDeposit Expected victim deposit amount
     */
    function attemptSandwichAttack(uint256 frontRunAmount, uint256 victimDeposit) external {
        // Front-run: deposit before victim
        IERC20(usdc).approve(vault, frontRunAmount);
        
        uint256 sharesBefore = IAlphaVault(vault).deposit(frontRunAmount, address(this));
        
        // Victim deposits (simulated - would happen in between)
        // ...
        
        // Back-run: withdraw after victim
        IAlphaVault(vault).approve(vault, sharesBefore);
        uint256 withdrawn = IAlphaVault(vault).redeem(sharesBefore, address(this), address(this));
        
        if (withdrawn > frontRunAmount) {
            attackSucceeded = true;
            profitMade = withdrawn - frontRunAmount;
        }
        
        // Suppress unused variable warning
        victimDeposit;
    }

    /**
     * @notice Attempt first depositor attack (share price manipulation)
     * @param donationAmount Amount to donate directly to vault
     */
    function attemptFirstDepositorAttack(uint256 smallDeposit, uint256 donationAmount) external {
        // Step 1: Make a small deposit to become first depositor
        IERC20(usdc).approve(vault, smallDeposit);
        uint256 shares = IAlphaVault(vault).deposit(smallDeposit, address(this));
        
        // Step 2: Donate tokens directly to vault to inflate share price
        // This should NOT work if vault has proper protection
        IERC20(usdc).safeTransfer(vault, donationAmount);
        
        // Step 3: Check if our share value increased
        uint256 shareValue = IAlphaVault(vault).previewRedeem(shares);
        
        if (shareValue > smallDeposit + donationAmount) {
            attackSucceeded = true;
            profitMade = shareValue - smallDeposit - donationAmount;
        }
    }

    /**
     * @notice Reset attack state for next test
     */
    function reset() external {
        attackSucceeded = false;
        profitMade = 0;
    }

    // Allow receiving USDC
    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultAdapter} from "../../../contracts/interfaces/IVaultAdapter.sol";
import {IAlphaVault} from "../../../contracts/interfaces/IAlphaVault.sol";

/**
 * @title MockReentrantAdapter
 * @notice Mock adapter that attempts reentrancy attacks for security testing
 * @dev Tests reentrancy protection on vault functions
 */
contract MockReentrantAdapter is IVaultAdapter {
    using SafeERC20 for IERC20;

    string public name = "Reentrant Adapter";
    address public override asset;
    address public override vault;
    address public override underlyingProtocol;
    
    uint256 private _tvl;
    bool public override paused;
    bool public shouldReenter;
    bool public reentrySucceeded;
    uint256 public reentryAttempts;

    enum AttackType {
        NONE,
        REENTER_DEPOSIT,
        REENTER_WITHDRAW,
        REENTER_REDEEM
    }

    AttackType public attackType;

    event ReentrancyAttempted(AttackType attackType, bool success, uint256 attempts);

    constructor(address _asset, address _vault) {
        asset = _asset;
        vault = _vault;
        underlyingProtocol = address(this);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IVaultAdapter Implementation
    // ═══════════════════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external override returns (uint256) {
        if (shouldReenter && attackType == AttackType.REENTER_DEPOSIT) {
            _attemptReentrantDeposit(amount);
        }
        
        _tvl += amount;
        emit Deposited(msg.sender, amount, amount);
        return amount;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        if (shouldReenter && attackType == AttackType.REENTER_WITHDRAW) {
            _attemptReentrantWithdraw(amount);
        }
        
        if (amount > _tvl) revert InsufficientBalance();
        _tvl -= amount;
        
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, amount);
        return amount;
    }

    function getTVL() external view override returns (uint256) {
        return _tvl;
    }

    function maxWithdraw() external view override returns (uint256) {
        return _tvl;
    }

    function getName() external view override returns (string memory) {
        return name;
    }

    function getReceiptToken() external pure override returns (address) {
        return address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Attack Functions
    // ═══════════════════════════════════════════════════════════════════════════

    function _attemptReentrantDeposit(uint256 amount) internal {
        reentryAttempts++;
        
        // Try to call deposit again
        try IAlphaVault(vault).deposit(amount, address(this)) {
            reentrySucceeded = true;
        } catch {
            reentrySucceeded = false;
        }
        
        emit ReentrancyAttempted(AttackType.REENTER_DEPOSIT, reentrySucceeded, reentryAttempts);
    }

    function _attemptReentrantWithdraw(uint256 amount) internal {
        reentryAttempts++;
        
        // Try to call withdraw again
        try IAlphaVault(vault).withdraw(amount, address(this), address(this)) {
            reentrySucceeded = true;
        } catch {
            reentrySucceeded = false;
        }
        
        emit ReentrancyAttempted(AttackType.REENTER_WITHDRAW, reentrySucceeded, reentryAttempts);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Test Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    function setAttackConfig(bool _shouldReenter, AttackType _attackType) external {
        shouldReenter = _shouldReenter;
        attackType = _attackType;
    }

    function setTVL(uint256 newTVL) external {
        _tvl = newTVL;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    function reset() external {
        shouldReenter = false;
        reentrySucceeded = false;
        reentryAttempts = 0;
        attackType = AttackType.NONE;
    }
}

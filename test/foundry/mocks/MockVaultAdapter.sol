// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultAdapter} from "../../../contracts/interfaces/IVaultAdapter.sol";

/**
 * @title MockVaultAdapter
 * @notice Mock adapter for testing AlphaVault logic
 * @dev Simulates protocol behavior with configurable parameters
 */
contract MockVaultAdapter is IVaultAdapter {
    using SafeERC20 for IERC20;

    string public name;
    address public override asset;
    address public override vault;
    address public override underlyingProtocol;

    uint256 private _tvl;
    uint256 private _totalDeposited;
    uint256 private _yieldMultiplierBps;

    bool public override paused;
    bool private _shouldFailDeposit;
    bool private _shouldFailWithdraw;

    uint256 private _maxWithdrawAmount;
    uint256 private _lockupPeriod;
    uint256 private _lockedUntil;

    constructor(string memory _name, address _asset, address _vault, bool) {
        name = _name;
        asset = _asset;
        vault = _vault;
        underlyingProtocol = address(this);
        _yieldMultiplierBps = 10_000;
        _maxWithdrawAmount = type(uint256).max;
    }

    function deposit(uint256 amount) external override returns (uint256 protocolShares) {
        if (paused) revert AdapterPaused();
        if (amount == 0) revert InvalidAmount();
        if (_shouldFailDeposit) revert ProtocolOperationFailed();

        _totalDeposited += amount;
        _updateTVL();
        _lockedUntil = _lockupPeriod == 0 ? 0 : block.timestamp + _lockupPeriod;

        protocolShares = amount;
        emit Deposited(msg.sender, amount, protocolShares);
        return protocolShares;
    }

    function withdraw(uint256 amount) external override returns (uint256 actualAmount) {
        if (paused) revert AdapterPaused();
        if (amount == 0) revert InvalidAmount();
        if (_shouldFailWithdraw) revert ProtocolOperationFailed();
        if (amount > _tvl) revert InsufficientBalance();
        if (_lockedUntil != 0 && block.timestamp < _lockedUntil) revert WithdrawalLocked(_lockedUntil);

        actualAmount = amount;

        if (_totalDeposited >= amount) {
            _totalDeposited -= amount;
        } else {
            _totalDeposited = 0;
        }
        _updateTVL();

        IERC20(asset).safeTransfer(msg.sender, actualAmount);
        emit Withdrawn(msg.sender, actualAmount, amount);
        return actualAmount;
    }

    function getTVL() external view override returns (uint256) {
        return _tvl;
    }

    function maxWithdraw() external view override returns (uint256) {
        if (_lockedUntil != 0 && block.timestamp < _lockedUntil) return 0;
        return _maxWithdrawAmount < _tvl ? _maxWithdrawAmount : _tvl;
    }

    function getName() external view override returns (string memory) {
        return name;
    }

    function getReceiptToken() external pure override returns (address) {
        return address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function simulateYield(uint16 yieldBps) external {
        _yieldMultiplierBps = 10_000 + yieldBps;
        _updateTVL();
    }

    function simulateLoss(uint16 lossBps) external {
        _yieldMultiplierBps = 10_000 - lossBps;
        _updateTVL();
    }

    function setTVL(uint256 newTVL) external {
        _tvl = newTVL;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function setMaxWithdraw(uint256 max) external {
        _maxWithdrawAmount = max;
    }

    function setShouldFailDeposit(bool shouldFail) external {
        _shouldFailDeposit = shouldFail;
    }

    function setShouldFailWithdraw(bool shouldFail) external {
        _shouldFailWithdraw = shouldFail;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    function setLockupPeriod(uint256 lockupSeconds) external {
        _lockupPeriod = lockupSeconds;
        _lockedUntil = lockupSeconds == 0 ? 0 : block.timestamp + lockupSeconds;
    }

    function _updateTVL() internal {
        _tvl = (_totalDeposited * _yieldMultiplierBps) / 10_000;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCoreDepositor
 * @notice Mock Circle CoreDepositor for testing vault perps deposits
 */
contract MockCoreDepositor {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    uint256 public totalDeposited;
    uint256 public lastAmount;
    uint32 public lastDex;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function deposit(uint256 amount, uint32 destinationDex) external {
        lastAmount = amount;
        lastDex = destinationDex;
        totalDeposited += amount;
        asset.safeTransferFrom(msg.sender, address(this), amount);
    }
}

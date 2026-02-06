// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../../../contracts/AlphaVault.sol";
import {MockVaultAdapter} from "../mocks/MockVaultAdapter.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {StrategyType, StrategyInput} from "../../../contracts/types/VaultTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockMarginSummaryPrecompile} from "../mocks/MockMarginSummaryPrecompile.sol";

contract AlphaVaultIntegrationTest is Test {
    address constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;

    AlphaVault public vault;
    MockUSDC public usdc;
    MockVaultAdapter public adapter1;
    MockVaultAdapter public adapter2;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public treasury = makeAddr("treasury");
    address public coreDepositor = makeAddr("coreDepositor");

    uint256 constant ONE_USDC = 1e6;
    uint256 constant DEPOSIT_AMOUNT = 1000 * ONE_USDC;

    function setUp() public {
        MockMarginSummaryPrecompile marginImpl = new MockMarginSummaryPrecompile();
        vm.etch(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, address(marginImpl).code);

        usdc = new MockUSDC();

        vm.startPrank(owner);
        AlphaVault implementation = new AlphaVault();
        bytes memory initData = abi.encodeWithSelector(
            AlphaVault.initialize.selector,
            address(usdc),
            "Alpha Vault",
            "ALPHA",
            treasury,
            coreDepositor,
            owner
        );
        vault = AlphaVault(address(new ERC1967Proxy(address(implementation), initData)));

        adapter1 = new MockVaultAdapter("Adapter 1", address(usdc), address(vault), true);
        adapter2 = new MockVaultAdapter("Adapter 2", address(usdc), address(vault), true);

        StrategyInput[] memory strategies = new StrategyInput[](2);
        strategies[0] = StrategyInput({
            adapter: address(adapter1),
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        strategies[1] = StrategyInput({
            adapter: address(adapter2),
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        vault.setStrategies(strategies);

        vault.setDepositFee(0);
        vault.setWithdrawFee(0);
        vault.setReserveConfig(0, 0, 0);
        vault.setEpochLength(1 days);
        vm.stopPrank();

        usdc.mint(alice, DEPOSIT_AMOUNT * 10);
        usdc.mint(bob, DEPOSIT_AMOUNT * 10);
    }

    function _advanceEpoch() internal { vm.warp(block.timestamp + 1 days); }
    function _settleCurrentEpoch() internal { vault.settleEpoch(vault.getCurrentEpoch() - 1); }

    function test_Deposit_QueuesForEpoch() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "No shares before settlement");
        (uint256 pending, , ) = vault.getEpochSummary(vault.getCurrentEpoch());
        assertEq(pending, DEPOSIT_AMOUNT, "Deposit queued");
    }

    function test_Deposit_AutoMintOnSettle() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        _advanceEpoch();
        _settleCurrentEpoch();

        vm.prank(owner);
        vault.deployBatch();

        assertGt(vault.balanceOf(alice), 0, "Shares minted");
        assertEq(adapter1.getTVL() + adapter2.getTVL(), DEPOSIT_AMOUNT, "TVL deployed");
    }

    function test_Withdraw_BatchedAndSettled() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        _advanceEpoch();
        _settleCurrentEpoch();

        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "Shares burned");
        assertEq(vault.totalSupply(), 0, "totalSupply should burn queued shares");
        assertEq(vault.pendingWithdrawalAssets(), DEPOSIT_AMOUNT, "pending withdrawal assets mismatch");

        _advanceEpoch();
        _settleCurrentEpoch();

        assertEq(usdc.balanceOf(alice) - usdcBefore, DEPOSIT_AMOUNT, "USDC paid out");
        assertEq(vault.pendingWithdrawalAssets(), 0, "pending withdrawal assets cleared");
    }
}

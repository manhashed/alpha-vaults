// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaVault} from "../../../contracts/AlphaVault.sol";
import {IAlphaVault} from "../../../contracts/interfaces/IAlphaVault.sol";
import {StrategyType, StrategyInput} from "../../../contracts/types/VaultTypes.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVaultAdapter} from "../mocks/MockVaultAdapter.sol";
import {MockMarginSummaryPrecompile} from "../mocks/MockMarginSummaryPrecompile.sol";
import {MockCoreDepositor} from "../mocks/MockCoreDepositor.sol";

contract AlphaVaultAssetsTest is BaseTest {
    AlphaVault public vault;
    MockUSDC public mockUsdc;
    MockVaultAdapter public adapter;
    MockCoreDepositor public coreDepositor;

    function setUp() public override {
        super.setUp();

        mockUsdc = new MockUSDC();
        usdc = mockUsdc;

        coreDepositor = new MockCoreDepositor(mockUsdc);

        AlphaVault implementation = new AlphaVault();
        bytes memory initData = abi.encodeWithSelector(
            AlphaVault.initialize.selector,
            address(mockUsdc),
            "Alpha Vault",
            "ALPHAVLT",
            treasury,
            address(coreDepositor),
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = AlphaVault(address(proxy));

        adapter = new MockVaultAdapter("Adapter", address(mockUsdc), address(vault), true);

        vm.startPrank(owner);
        vault.setDepositFee(0);
        vault.setWithdrawFee(0);
        vault.setReserveConfig(0, 0, 0);
        vault.setEpochLength(1 days);
        vault.setDeploymentConfig(0, 0);
        vm.stopPrank();

        mockUsdc.mint(alice, toUSDC(100_000));
    }

    function test_TotalAssets_IncludesPerpsBalance() public {
        StrategyInput[] memory strategies = new StrategyInput[](1);
        strategies[0] = StrategyInput({
            adapter: address(adapter),
            targetBps: 10_000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        vm.prank(owner);
        vault.setStrategies(strategies);

        uint256 depositAmount = toUSDC(1_000);
        uint256 epoch0 = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(epoch0);

        MockMarginSummaryPrecompile margin = MockMarginSummaryPrecompile(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE);
        margin.setMarginSummary(0, address(vault), 0, 0, 0, int64(50_000_000_000)); // +500 USDC

        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, depositAmount + toUSDC(500), "perps balance should be included");
    }

    function test_WithdrawableLiquidity_IgnoresNegativePerps() public {
        StrategyInput[] memory strategies = new StrategyInput[](1);
        strategies[0] = StrategyInput({
            adapter: address(adapter),
            targetBps: 10_000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        vm.prank(owner);
        vault.setStrategies(strategies);

        uint256 depositAmount = toUSDC(1_000);
        uint256 epoch0 = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(epoch0);

        MockMarginSummaryPrecompile margin = MockMarginSummaryPrecompile(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE);
        margin.setMarginSummary(0, address(vault), 0, 0, 0, -int64(50_000_000_000)); // -500 USDC

        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, depositAmount - toUSDC(500), "negative perps reduce totalAssets");
        assertEq(vault.getWithdrawableLiquidity(), depositAmount, "negative perps ignored for liquidity");
    }

    function test_SetStrategies_RevertOnRemovalWithTVL() public {
        StrategyInput[] memory strategies = new StrategyInput[](1);
        strategies[0] = StrategyInput({
            adapter: address(adapter),
            targetBps: 10_000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        vm.prank(owner);
        vault.setStrategies(strategies);

        uint256 depositAmount = toUSDC(1_000);
        uint256 epoch0 = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(epoch0);

        vm.prank(owner);
        vault.deployBatch();

        StrategyInput[] memory newStrategies = new StrategyInput[](1);
        newStrategies[0] = StrategyInput({
            adapter: address(0),
            targetBps: 10_000,
            strategyType: StrategyType.PERPS,
            active: true
        });

        vm.expectRevert(IAlphaVault.StrategyNotFound.selector);
        vm.prank(owner);
        vault.setStrategies(newStrategies);
    }

    function test_PerpsStrategy_DepositsViaCoreDepositor() public {
        StrategyInput[] memory strategies = new StrategyInput[](1);
        strategies[0] = StrategyInput({
            adapter: address(0),
            targetBps: 10_000,
            strategyType: StrategyType.PERPS,
            active: true
        });
        vm.prank(owner);
        vault.setStrategies(strategies);

        uint256 depositAmount = toUSDC(1_000);
        uint256 epoch0 = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(epoch0);

        vm.prank(owner);
        vault.deployBatch();

        assertEq(coreDepositor.lastAmount(), depositAmount, "core depositor amount mismatch");
        assertEq(coreDepositor.lastDex(), 0, "core depositor dex mismatch");
        assertEq(mockUsdc.balanceOf(address(coreDepositor)), depositAmount, "core depositor balance mismatch");
    }
}

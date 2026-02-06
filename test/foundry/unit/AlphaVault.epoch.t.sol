// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaVault} from "../../../contracts/AlphaVault.sol";
import {StrategyType, StrategyInput} from "../../../contracts/types/VaultTypes.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVaultAdapter} from "../mocks/MockVaultAdapter.sol";

contract AlphaVaultEpochTest is BaseTest {
    AlphaVault public vault;
    MockUSDC public mockUsdc;
    MockVaultAdapter public adapter;

    address public coreDepositor;

    function setUp() public override {
        super.setUp();

        coreDepositor = makeAddr("coreDepositor");
        mockUsdc = new MockUSDC();
        usdc = mockUsdc;

        AlphaVault implementation = new AlphaVault();
        bytes memory initData = abi.encodeWithSelector(
            AlphaVault.initialize.selector,
            address(mockUsdc),
            "Alpha Vault",
            "ALPHAVLT",
            treasury,
            coreDepositor,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = AlphaVault(address(proxy));

        adapter = new MockVaultAdapter("Adapter", address(mockUsdc), address(vault), true);

        StrategyInput[] memory strategies = new StrategyInput[](1);
        strategies[0] = StrategyInput({
            adapter: address(adapter),
            targetBps: 10_000,
            strategyType: StrategyType.ERC4626,
            active: true
        });

        vm.startPrank(owner);
        vault.setStrategies(strategies);
        vault.setDepositFee(0);
        vault.setWithdrawFee(0);
        vault.setReserveConfig(0, 0, 0);
        vault.setEpochLength(1 days);
        vm.stopPrank();

        mockUsdc.mint(alice, toUSDC(100_000));
    }

    function test_Deposit_MintsSharesOnSettlement() public {
        vm.warp(1_000);

        uint256 depositAmount = toUSDC(1_000);
        uint256 epoch0 = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "shares should be 0 before settlement");
        assertEq(vault.epochPendingDeposits(epoch0), depositAmount, "pending deposits mismatch");

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(epoch0);

        uint256 expectedShares = vault.previewDeposit(depositAmount);
        assertEq(vault.balanceOf(alice), expectedShares, "shares minted mismatch");
        assertEq(vault.epochPendingDeposits(epoch0), 0, "epoch deposits cleared");
    }

    function test_RequestWithdrawal_PaysOnSettlement() public {
        vm.warp(10_000);

        uint256 depositAmount = toUSDC(1_000);
        uint256 depositEpochId = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(depositEpochId);

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0, "shares should be minted");

        uint256 withdrawEpochId = vault.getCurrentEpoch();
        vm.prank(alice);
        vault.withdraw(depositAmount, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "shares should be burned");
        assertEq(vault.totalSupply(), 0, "totalSupply should burn queued shares");
        assertEq(vault.pendingWithdrawalAssets(), depositAmount, "pending withdrawal assets mismatch");
        assertEq(vault.getEpochWithdrawalCount(withdrawEpochId), 1, "withdrawal count mismatch");

        uint256 aliceBefore = mockUsdc.balanceOf(alice);
        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(withdrawEpochId);

        uint256 aliceAfter = mockUsdc.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, depositAmount, "alice should receive assets");
        assertEq(vault.totalSupply(), 0, "totalSupply should be 0 after full withdrawal");
        assertEq(vault.pendingWithdrawalAssets(), 0, "pending withdrawal assets cleared");
    }

    function test_Withdrawal_LocksSharesUntilSettlement() public {
        vm.warp(15_000);

        uint256 depositAmount = toUSDC(1_000);
        uint256 depositEpochId = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(depositEpochId);
        uint256 shares = vault.balanceOf(alice);
        uint256 totalSupplyBefore = vault.totalSupply();

        uint256 withdrawEpochId = vault.getCurrentEpoch();
        vm.prank(alice);
        vault.withdraw(depositAmount, alice, alice);

        assertEq(vault.totalSupply(), totalSupplyBefore - shares, "totalSupply should burn queued shares");
        assertEq(vault.pendingWithdrawalAssets(), depositAmount, "pending withdrawal assets mismatch");
        assertEq(vault.getEpochWithdrawalCount(withdrawEpochId), 1, "withdrawal count mismatch");
    }

    function test_Withdrawal_StaysQueuedIfInsufficientLiquidity() public {
        vm.warp(20_000);

        uint256 depositAmount = toUSDC(1_000);
        uint256 depositEpochId = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(depositEpochId);

        uint256 withdrawEpochId = vault.getCurrentEpoch();
        vm.prank(alice);
        vault.withdraw(depositAmount, alice, alice);

        mockUsdc.burn(address(vault), mockUsdc.balanceOf(address(vault)));
        adapter.setTVL(0);

        uint256 aliceBefore = mockUsdc.balanceOf(alice);
        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(withdrawEpochId);

        uint256 aliceAfter = mockUsdc.balanceOf(alice);
        assertEq(aliceAfter, aliceBefore, "no payout without liquidity");
        assertEq(vault.pendingWithdrawalAssets(), depositAmount, "pending withdrawal assets stay queued");

        mockUsdc.mint(address(vault), depositAmount);
        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(withdrawEpochId + 1);

        uint256 aliceFinal = mockUsdc.balanceOf(alice);
        assertEq(aliceFinal - aliceBefore, depositAmount, "payout after liquidity restored");
        assertEq(vault.pendingWithdrawalAssets(), 0, "pending withdrawal assets cleared");
    }

    function test_Withdrawal_FifoSkipsLaterRequests() public {
        vm.warp(25_000);

        uint256 depositAmount = toUSDC(1_000);
        uint256 depositEpochId = vault.getCurrentEpoch();

        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(depositEpochId);

        uint256 withdrawEpochId = vault.getCurrentEpoch();
        vm.prank(alice);
        vault.withdraw(toUSDC(900), alice, alice);
        vm.prank(alice);
        vault.withdraw(toUSDC(100), alice, alice);

        mockUsdc.burn(address(vault), mockUsdc.balanceOf(address(vault)));
        adapter.setTVL(0);
        mockUsdc.mint(address(vault), toUSDC(100));

        uint256 aliceBefore = mockUsdc.balanceOf(alice);
        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(withdrawEpochId);

        uint256 aliceAfter = mockUsdc.balanceOf(alice);
        assertEq(aliceAfter, aliceBefore, "no payout when head request unmet");
        assertEq(vault.pendingWithdrawalAssets(), depositAmount, "all requests remain queued");

        mockUsdc.mint(address(vault), toUSDC(900));
        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(withdrawEpochId + 1);

        uint256 aliceFinal = mockUsdc.balanceOf(alice);
        assertEq(aliceFinal - aliceBefore, depositAmount, "payout once fully liquid");
        assertEq(vault.pendingWithdrawalAssets(), 0, "pending withdrawal assets cleared");
    }
}

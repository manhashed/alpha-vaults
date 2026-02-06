// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaVault} from "../../../contracts/AlphaVault.sol";
import {IAlphaVault} from "../../../contracts/interfaces/IAlphaVault.sol";
import {StrategyLib} from "../../../contracts/libraries/StrategyLib.sol";
import {StrategyType, StrategyInput} from "../../../contracts/types/VaultTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVaultAdapter} from "../mocks/MockVaultAdapter.sol";
import {MockReentrantAdapter} from "../mocks/MockReentrantAdapter.sol";
import {MockMarginSummaryPrecompile} from "../mocks/MockMarginSummaryPrecompile.sol";

contract AlphaVaultSecurityTest is Test {
    address constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;

    AlphaVault public vault;
    MockUSDC public mockUsdc;
    MockVaultAdapter public adapter1;
    MockVaultAdapter public adapter2;
    MockReentrantAdapter public reentrantAdapter;

    address public owner = makeAddr("owner");
    address public proxyAdmin = makeAddr("proxyAdmin");
    address public treasury = makeAddr("treasury");
    address public coreDepositor = makeAddr("coreDepositor");
    address public alice = makeAddr("alice");

    function setUp() public {
        MockMarginSummaryPrecompile marginImpl = new MockMarginSummaryPrecompile();
        vm.etch(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, address(marginImpl).code);

        mockUsdc = new MockUSDC();

        AlphaVault vaultImpl = new AlphaVault();
        bytes memory initData = abi.encodeWithSelector(
            AlphaVault.initialize.selector,
            address(mockUsdc),
            "Alpha Vault",
            "ALPHAVLT",
            treasury,
            coreDepositor,
            owner
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(vaultImpl),
            proxyAdmin,
            initData
        );
        vault = AlphaVault(address(proxy));

        adapter1 = new MockVaultAdapter("Adapter1", address(mockUsdc), address(vault), true);
        adapter2 = new MockVaultAdapter("Adapter2", address(mockUsdc), address(vault), true);
        reentrantAdapter = new MockReentrantAdapter(address(mockUsdc), address(vault));

        StrategyInput[] memory inputs = new StrategyInput[](2);
        inputs[0] = StrategyInput({
            adapter: address(adapter1),
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        inputs[1] = StrategyInput({
            adapter: address(adapter2),
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });

        vm.prank(owner);
        vault.setStrategies(inputs);

        vm.prank(owner);
        vault.setReserveConfig(0, 0, 0);

        vm.prank(owner);
        vault.setDepositFee(0);
        vm.prank(owner);
        vault.setWithdrawFee(0);

        mockUsdc.mint(alice, 100_000 * 1e6);
    }

    function test_OwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), newOwner);
    }

    function test_ReentrancyProtection_Deposit() public {
        StrategyInput[] memory inputs = new StrategyInput[](1);
        inputs[0] = StrategyInput({
            adapter: address(reentrantAdapter),
            targetBps: 10_000,
            strategyType: StrategyType.ERC4626,
            active: true
        });

        vm.prank(owner);
        vault.setStrategies(inputs);

        reentrantAdapter.setAttackConfig(true, MockReentrantAdapter.AttackType.REENTER_DEPOSIT);

        uint256 depositAmount = 1_000 * 1e6;
        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertFalse(reentrantAdapter.reentrySucceeded());
    }

    function test_ReentrancyProtection_Withdraw() public {
        StrategyInput[] memory inputs = new StrategyInput[](1);
        inputs[0] = StrategyInput({
            adapter: address(reentrantAdapter),
            targetBps: 10_000,
            strategyType: StrategyType.ERC4626,
            active: true
        });

        vm.prank(owner);
        vault.setStrategies(inputs);

        uint256 depositAmount = 1_000 * 1e6;
        vm.startPrank(alice);
        mockUsdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.epochLength());
        vault.settleEpoch(vault.getCurrentEpoch() - 1);

        reentrantAdapter.setAttackConfig(true, MockReentrantAdapter.AttackType.REENTER_WITHDRAW);

        vm.prank(alice);
        vault.withdraw(depositAmount, alice, alice);

        assertFalse(reentrantAdapter.reentrySucceeded());
    }

    function test_SetStrategies_RevertDuplicateAdapter() public {
        StrategyInput[] memory inputs = new StrategyInput[](2);
        inputs[0] = StrategyInput({
            adapter: address(adapter1),
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        inputs[1] = StrategyInput({
            adapter: address(adapter1),
            targetBps: 5000,
            strategyType: StrategyType.VAULT,
            active: true
        });

        vm.expectRevert(abi.encodeWithSelector(StrategyLib.DuplicateStrategy.selector, address(adapter1)));
        vm.prank(owner);
        vault.setStrategies(inputs);
    }

    function test_SetStrategies_RevertInvalidPerps() public {
        StrategyInput[] memory inputs = new StrategyInput[](1);
        inputs[0] = StrategyInput({
            adapter: address(adapter1),
            targetBps: 10_000,
            strategyType: StrategyType.PERPS,
            active: true
        });

        vm.expectRevert(StrategyLib.InvalidPerpsStrategy.selector);
        vm.prank(owner);
        vault.setStrategies(inputs);
    }

    function test_Deposit_RevertWhenNoStrategies() public {
        AlphaVault freshVault = new AlphaVault();
        bytes memory initData = abi.encodeWithSelector(
            AlphaVault.initialize.selector,
            address(mockUsdc),
            "Fresh Vault",
            "ALPHAFRESH",
            treasury,
            coreDepositor,
            owner
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(freshVault),
            proxyAdmin,
            initData
        );
        AlphaVault vaultNoStrategies = AlphaVault(address(proxy));

        vm.startPrank(alice);
        mockUsdc.approve(address(vaultNoStrategies), 100 * 1e6);
        vm.expectRevert(IAlphaVault.StrategyRegistryEmpty.selector);
        vaultNoStrategies.deposit(100 * 1e6, alice);
        vm.stopPrank();
    }
}

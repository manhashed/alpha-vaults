// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FelixAdapter} from "../../../contracts/adapters/FelixAdapter.sol";
import {IVaultAdapter} from "../../../contracts/interfaces/IVaultAdapter.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/**
 * @title MockFelixVault
 * @notice Mock ERC4626 vault for testing FelixAdapter
 */
contract MockFelixVault is ERC4626 {
    constructor(IERC20 _asset) 
        ERC4626(_asset) 
        ERC20("Mock Felix Vault", "mFELIX") 
    {}

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

/**
 * @title FelixAdapter Unit Tests
 * @notice Comprehensive unit tests for FelixAdapter
 */
contract FelixAdapterTest is BaseTest {
    using SafeERC20 for IERC20;
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    FelixAdapter public adapterImpl;
    FelixAdapter public adapter;
    MockUSDC public mockUsdc;
    MockFelixVault public felixVault;
    
    address public proxyAdmin;
    address public vaultAddress; // AlphaVault mock

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public override {
        super.setUp();

        // Create mock tokens
        mockUsdc = new MockUSDC();
        usdc = IERC20(address(mockUsdc));
        
        // Create mock Felix vault
        felixVault = new MockFelixVault(usdc);
        
        proxyAdmin = makeAddr("proxyAdmin");
        vaultAddress = makeAddr("vault"); // Mock AlphaVault

        // Deploy adapter implementation
        adapterImpl = new FelixAdapter();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            FelixAdapter.initialize.selector,
            address(mockUsdc),
            vaultAddress,
            address(felixVault),
            owner
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(adapterImpl),
            proxyAdmin,
            initData
        );
        adapter = FelixAdapter(address(proxy));

        // Fund accounts
        mockUsdc.mint(vaultAddress, toUSDC(100_000));
        mockUsdc.mint(alice, toUSDC(10_000));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Initialize_SetsCorrectState() public view {
        assertEq(adapter.asset(), address(mockUsdc));
        assertEq(adapter.vault(), vaultAddress);
        assertEq(address(adapter.felixVault()), address(felixVault));
        assertEq(adapter.getName(), "Felix Lending");
        assertEq(adapter.owner(), owner);
    }

    function test_Initialize_RevertOnZeroFelixVault() public {
        FelixAdapter newAdapter = new FelixAdapter();
        
        bytes memory initData = abi.encodeWithSelector(
            FelixAdapter.initialize.selector,
            address(mockUsdc),
            vaultAddress,
            address(0), // Zero Felix vault
            owner
        );

        vm.expectRevert(IVaultAdapter.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newAdapter), proxyAdmin, initData);
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        adapter.initialize(address(mockUsdc), vaultAddress, address(felixVault), owner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Deposit_Success() public {
        uint256 depositAmount = toUSDC(1000);

        // Transfer USDC to adapter (simulating vault behavior)
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);

        // Call deposit
        vm.prank(vaultAddress);
        uint256 shares = adapter.deposit(depositAmount);

        // Verify shares received
        assertGt(shares, 0);
        
        // Verify Felix shares went to vault (not adapter)
        assertEq(felixVault.balanceOf(vaultAddress), shares);
        assertEq(felixVault.balanceOf(address(adapter)), 0);
    }

    function test_Deposit_RevertIfNotVault() public {
        uint256 depositAmount = toUSDC(1000);

        vm.prank(alice);
        vm.expectRevert(IVaultAdapter.Unauthorized.selector);
        adapter.deposit(depositAmount);
    }

    function test_Deposit_RevertIfZeroAmount() public {
        vm.prank(vaultAddress);
        vm.expectRevert(IVaultAdapter.InvalidAmount.selector);
        adapter.deposit(0);
    }

    function test_Deposit_RevertIfInsufficientBalance() public {
        uint256 depositAmount = toUSDC(1000);

        // Don't transfer USDC to adapter
        vm.prank(vaultAddress);
        vm.expectRevert(IVaultAdapter.InsufficientBalance.selector);
        adapter.deposit(depositAmount);
    }

    function test_Deposit_RevertIfPaused() public {
        vm.prank(owner);
        adapter.pause();

        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);

        vm.prank(vaultAddress);
        vm.expectRevert();
        adapter.deposit(depositAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Withdraw_Success() public {
        // First deposit
        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);
        vm.prank(vaultAddress);
        uint256 shares = adapter.deposit(depositAmount);

        // Get vault's initial USDC balance
        uint256 vaultUsdcBefore = mockUsdc.balanceOf(vaultAddress);

        // Transfer shares to adapter for withdrawal
        vm.prank(vaultAddress);
        IERC20(address(felixVault)).safeTransfer(address(adapter), shares);

        // Withdraw
        uint256 withdrawAmount = toUSDC(500);
        vm.prank(vaultAddress);
        uint256 actualAmount = adapter.withdraw(withdrawAmount);

        // Verify withdrawal
        assertEq(actualAmount, withdrawAmount);
        assertEq(mockUsdc.balanceOf(vaultAddress), vaultUsdcBefore + withdrawAmount);
    }

    function test_Withdraw_ReturnsExcessShares() public {
        // First deposit
        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);
        vm.prank(vaultAddress);
        uint256 shares = adapter.deposit(depositAmount);

        // Transfer all shares to adapter
        vm.prank(vaultAddress);
        IERC20(address(felixVault)).safeTransfer(address(adapter), shares);

        // Withdraw partial amount
        uint256 withdrawAmount = toUSDC(500);
        vm.prank(vaultAddress);
        adapter.withdraw(withdrawAmount);

        // Verify excess shares returned to vault
        uint256 vaultSharesAfter = felixVault.balanceOf(vaultAddress);
        assertGt(vaultSharesAfter, 0);
    }

    function test_Withdraw_RevertIfNotVault() public {
        vm.prank(alice);
        vm.expectRevert(IVaultAdapter.Unauthorized.selector);
        adapter.withdraw(toUSDC(100));
    }

    function test_Withdraw_RevertIfZeroAmount() public {
        vm.prank(vaultAddress);
        vm.expectRevert(IVaultAdapter.InvalidAmount.selector);
        adapter.withdraw(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TVL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_GetTVL_ReturnsVaultShareValue() public {
        // Deposit to create position
        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);
        vm.prank(vaultAddress);
        adapter.deposit(depositAmount);

        // Check TVL equals vault's share value
        uint256 tvl = adapter.getTVL();
        uint256 vaultShares = felixVault.balanceOf(vaultAddress);
        uint256 expectedTVL = felixVault.convertToAssets(vaultShares);

        assertEq(tvl, expectedTVL);
    }

    function test_GetTVL_ZeroWhenNoPosition() public view {
        uint256 tvl = adapter.getTVL();
        assertEq(tvl, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_GetReceiptToken_ReturnsFelixVault() public view {
        assertEq(adapter.getReceiptToken(), address(felixVault));
    }

    function test_GetVaultShares_ReturnsVaultBalance() public {
        // Deposit
        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);
        vm.prank(vaultAddress);
        uint256 shares = adapter.deposit(depositAmount);

        assertEq(adapter.getVaultShares(), shares);
    }

    function test_PreviewDeposit() public view {
        uint256 assets = toUSDC(1000);
        uint256 preview = adapter.previewDeposit(assets);
        uint256 expected = felixVault.previewDeposit(assets);
        assertEq(preview, expected);
    }

    function test_PreviewWithdraw() public {
        // Need some position first
        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);
        vm.prank(vaultAddress);
        adapter.deposit(depositAmount);

        uint256 assets = toUSDC(500);
        uint256 preview = adapter.previewWithdraw(assets);
        uint256 expected = felixVault.previewWithdraw(assets);
        assertEq(preview, expected);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.pause();

        vm.prank(owner);
        adapter.pause();
        assertTrue(adapter.paused());
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(owner);
        adapter.pause();

        vm.prank(alice);
        vm.expectRevert();
        adapter.unpause();

        vm.prank(owner);
        adapter.unpause();
        assertFalse(adapter.paused());
    }

    function test_SetVault_OnlyOwner() public {
        address newVault = makeAddr("newVault");

        vm.prank(alice);
        vm.expectRevert();
        adapter.setVault(newVault);

        vm.prank(owner);
        adapter.setVault(newVault);
        assertEq(adapter.vault(), newVault);
    }

    function test_SetVault_EmitsEvent() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, true, true);
        emit IVaultAdapter.VaultUpdated(vaultAddress, newVault);

        vm.prank(owner);
        adapter.setVault(newVault);
    }

    function test_SetVault_RevertOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IVaultAdapter.ZeroAddress.selector);
        adapter.setVault(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EMERGENCY FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_EmergencyWithdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_RecoversStuckTokens() public {
        // Simulate stuck USDC in adapter
        uint256 stuckAmount = toUSDC(100);
        mockUsdc.mint(address(adapter), stuckAmount);

        uint256 ownerBalanceBefore = mockUsdc.balanceOf(owner);

        vm.prank(owner);
        adapter.emergencyWithdraw();

        assertEq(mockUsdc.balanceOf(owner), ownerBalanceBefore + stuckAmount);
        assertEq(mockUsdc.balanceOf(address(adapter)), 0);
    }

    function test_EmergencyWithdraw_RecoversStuckShares() public {
        // First deposit to create shares
        uint256 depositAmount = toUSDC(1000);
        vm.prank(vaultAddress);
        IERC20(address(mockUsdc)).safeTransfer(address(adapter), depositAmount);
        vm.prank(vaultAddress);
        uint256 shares = adapter.deposit(depositAmount);

        // Simulate stuck shares in adapter (transfer from vault)
        vm.prank(vaultAddress);
        IERC20(address(felixVault)).safeTransfer(address(adapter), shares);

        uint256 ownerBalanceBefore = mockUsdc.balanceOf(owner);

        vm.prank(owner);
        adapter.emergencyWithdraw();

        // Owner should receive redeemed USDC
        assertGt(mockUsdc.balanceOf(owner), ownerBalanceBefore);
    }

    function test_RecoverTokens_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.recoverTokens(address(mockUsdc), alice);
    }

    function test_RecoverTokens_RecoversArbitraryTokens() public {
        // Send some tokens to adapter
        mockUsdc.mint(address(adapter), toUSDC(100));

        uint256 recovered;
        vm.prank(owner);
        recovered = adapter.recoverTokens(address(mockUsdc), treasury);

        assertEq(recovered, toUSDC(100));
        assertEq(mockUsdc.balanceOf(treasury), toUSDC(100));
    }

    function test_RecoverTokens_RevertOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IVaultAdapter.ZeroAddress.selector);
        adapter.recoverTokens(address(mockUsdc), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OWNERSHIP TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_OwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        vm.prank(owner);
        adapter.transferOwnership(newOwner);

        // Ownership transferred immediately with standard Ownable
        assertEq(adapter.owner(), newOwner);
    }
}

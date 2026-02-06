// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {HyperCoreVaultAdapter} from "../../../contracts/adapters/HyperCoreVaultAdapter.sol";
import {MockVaultEquityPrecompile} from "../mocks/MockVaultEquityPrecompile.sol";

contract HyperCoreVaultAdapterTest is Test {
    address constant VAULT_EQUITY_PRECOMPILE = 0x0000000000000000000000000000000000000802;

    HyperCoreVaultAdapter public adapter;
    MockVaultEquityPrecompile public mockVaultEquity;

    address public vaultUser = address(0x1234);
    address public underlyingVault = address(0x5678);
    address public proxyAdmin = address(0x9999);

    function setUp() public {
        MockVaultEquityPrecompile vaultEquityImpl = new MockVaultEquityPrecompile();
        vm.etch(VAULT_EQUITY_PRECOMPILE, address(vaultEquityImpl).code);
        mockVaultEquity = MockVaultEquityPrecompile(VAULT_EQUITY_PRECOMPILE);

        mockVaultEquity.setVaultEquity(vaultUser, underlyingVault, 5_000_000_000_000, 0);

        HyperCoreVaultAdapter adapterImpl = new HyperCoreVaultAdapter();
        bytes memory initData = abi.encodeWithSelector(
            HyperCoreVaultAdapter.initialize.selector,
            address(0xBEEF),
            vaultUser,
            underlyingVault,
            "HyperCore Vault",
            address(0xCAFE)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(adapterImpl),
            proxyAdmin,
            initData
        );
        adapter = HyperCoreVaultAdapter(address(proxy));
    }

    function test_GetTVL_ReadsVaultEquity() public view {
        uint256 tvl = adapter.getTVL();
        assertEq(tvl, 50_000 * 1e6);
    }

    function test_GetUnlockTime_NormalizesMillis() public {
        mockVaultEquity.setVaultEquity(vaultUser, underlyingVault, 5_000_000_000_000, 1_700_000_000_000);
        uint256 unlockTime = adapter.getUnlockTime();
        assertEq(unlockTime, 1_700_000_000);
    }
}

import { ethers, upgrades } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Deploy HyperCoreVaultAdapter as a transparent proxy contract.
 *
 * Environment variables:
 *   VAULT_ADDRESS: AlphaVault address (used as HyperCore account)
 *   UNDERLYING_VAULT: HyperCore vault address (HLP or trading vault)
 *   ADAPTER_NAME: Optional adapter name
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nDeploying HyperCoreVaultAdapter on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  const vaultAddress = process.env.VAULT_ADDRESS;
  if (!vaultAddress) {
    console.error("\n❌ VAULT_ADDRESS environment variable not set!");
    process.exit(1);
  }

  const underlyingVault = process.env.UNDERLYING_VAULT || config.hlpVault;
  const adapterName = process.env.ADAPTER_NAME || "HyperCore Vault";

  if (underlyingVault === "0x0000000000000000000000000000000000000000" || underlyingVault === "0x...") {
    console.error("\n❌ UNDERLYING_VAULT not configured!");
    process.exit(1);
  }

  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    console.error("\n❌ No signer available!");
    process.exit(1);
  }
  const deployer = signers[0];

  console.log("\n📊 Adapter Configuration:");
  console.log("   Vault (Account):", vaultAddress);
  console.log("   Underlying Vault:", underlyingVault);
  console.log("   Adapter Name:", adapterName);

  console.log("\n🚀 Deploying HyperCoreVaultAdapter as Transparent Proxy...");
  const AdapterFactory = await ethers.getContractFactory("HyperCoreVaultAdapter");

  const adapter = await upgrades.deployProxy(
    AdapterFactory,
    [
      config.usdc,
      vaultAddress,
      underlyingVault,
      adapterName,
      deployer.address,
    ],
    {
      kind: "transparent",
      initializer: "initialize",
    }
  );

  await adapter.waitForDeployment();
  const proxyAddress = await adapter.getAddress();

  console.log("✅ HyperCoreVaultAdapter Proxy deployed to:", proxyAddress);

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("✅ Implementation at:", implementationAddress);

  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("✅ ProxyAdmin at:", adminAddress);

  const adapterContract = await ethers.getContractAt("HyperCoreVaultAdapter", proxyAddress);
  console.log("\n🧪 Verifying deployment...");
  console.log("   Vault:", await adapterContract.vault());
  console.log("   Underlying Vault:", await adapterContract.getUnderlyingVault());

  const deploymentInfo = {
    contract: "HyperCoreVaultAdapter",
    network: networkName,
    networkType: mainnet ? "mainnet" : "testnet",
    chainId: config.chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    proxy: proxyAddress,
    implementation: implementationAddress,
    proxyAdmin: adminAddress,
    config: {
      vault: vaultAddress,
      underlyingVault,
      name: adapterName,
    },
  };

  const fileName = `adapter-hypercore-${Date.now()}-${mainnet ? "mainnet" : "testnet"}.json`;
  const filePath = path.join(process.cwd(), "deployments", fileName);

  const deploymentsDir = path.join(process.cwd(), "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(filePath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\n📁 Deployment info saved to deployments/${fileName}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });

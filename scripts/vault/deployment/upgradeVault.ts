import { ethers, upgrades } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Upgrade AlphaVault implementation.
 *
 * Usage:
 *   npx hardhat run scripts/vault/deployment/upgradeVault.ts --network hyperEvmTestnet
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nUpgrading AlphaVault on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  const proxyAddress = process.env.VAULT_PROXY_ADDRESS;
  if (!proxyAddress) {
    console.error("\n❌ VAULT_PROXY_ADDRESS environment variable not set!");
    process.exit(1);
  }

  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    console.error("\n❌ No signer available!");
    process.exit(1);
  }
  const deployer = signers[0];

  console.log("\n📋 Configuration:");
  console.log("   Network:", mainnet ? "MAINNET" : "TESTNET");
  console.log("   Proxy Address:", proxyAddress);
  console.log("   Upgrader:", deployer.address);

  const currentImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("   Current Implementation:", currentImpl);

  const vault = await ethers.getContractAt("AlphaVault", proxyAddress);
  const totalAssets = await vault.totalAssets();
  const owner = await vault.owner();

  console.log("\n📊 Pre-upgrade State:");
  console.log("   Total Assets:", totalAssets.toString());
  console.log("   Owner:", owner);

  console.log("\n🚀 Upgrading to new implementation...");
  const VaultFactory = await ethers.getContractFactory("AlphaVault");
  const upgraded = await upgrades.upgradeProxy(proxyAddress, VaultFactory);
  await upgraded.waitForDeployment();

  const newImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("✅ Upgrade complete!");
  console.log("   New Implementation:", newImpl);

  const upgradedVault = await ethers.getContractAt("AlphaVault", proxyAddress);
  const postTotalAssets = await upgradedVault.totalAssets();
  const postOwner = await upgradedVault.owner();

  console.log("\n🧪 Verifying state preserved...");
  console.log("   Total Assets:", postTotalAssets.toString(), postTotalAssets === totalAssets ? "✅" : "❌");
  console.log("   Owner:", postOwner, postOwner === owner ? "✅" : "❌");

  const upgradeInfo = {
    contract: "AlphaVault",
    network: networkName,
    networkType: mainnet ? "mainnet" : "testnet",
    timestamp: new Date().toISOString(),
    proxy: proxyAddress,
    previousImplementation: currentImpl,
    newImplementation: newImpl,
    upgrader: deployer.address,
  };

  const fileName = `vault-upgrade-${Date.now()}-${mainnet ? "mainnet" : "testnet"}.json`;
  const filePath = path.join(process.cwd(), "deployments", fileName);

  const deploymentsDir = path.join(process.cwd(), "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(filePath, JSON.stringify(upgradeInfo, null, 2));
  console.log(`\n📁 Upgrade info saved to deployments/${fileName}`);
  console.log(`Explorer: ${config.explorerUrl}/address/${newImpl}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Upgrade failed:", error);
    process.exit(1);
  });

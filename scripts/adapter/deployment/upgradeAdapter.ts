import { ethers, upgrades } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Upgrade an adapter implementation.
 *
 * Usage:
 *   npx hardhat run scripts/adapter/deployment/upgradeAdapter.ts --network hyperEvmTestnet
 *   npx hardhat run scripts/adapter/deployment/upgradeAdapter.ts --network hyperEvmMainnet
 *
 * Environment variables:
 *   ADAPTER_PROXY_ADDRESS: Address of the adapter proxy to upgrade
 *   ADAPTER_TYPE: "felix" | "hypercore" (determines contract factory)
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nUpgrading Adapter on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  // Get proxy address and adapter type
  const proxyAddress = process.env.ADAPTER_PROXY_ADDRESS;
  const adapterType = process.env.ADAPTER_TYPE;

  if (!proxyAddress) {
    console.error("\n❌ ADAPTER_PROXY_ADDRESS environment variable not set!");
    process.exit(1);
  }

  if (!adapterType || !["felix", "hypercore"].includes(adapterType)) {
    console.error("\n❌ ADAPTER_TYPE must be 'felix' or 'hypercore'!");
    process.exit(1);
  }

  // Map adapter type to contract name
  const contractNames: Record<string, string> = {
    felix: "FelixAdapter",
    hypercore: "HyperCoreVaultAdapter",
  };
  const contractName = contractNames[adapterType];

  // Get signer
  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    console.error("\n❌ No signer available!");
    process.exit(1);
  }
  const deployer = signers[0];

  console.log("\n📋 Configuration:");
  console.log("   Network:", mainnet ? "MAINNET" : "TESTNET");
  console.log("   Adapter Type:", adapterType);
  console.log("   Contract:", contractName);
  console.log("   Proxy Address:", proxyAddress);
  console.log("   Upgrader:", deployer.address);

  // Get current implementation
  const currentImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("   Current Implementation:", currentImpl);

  // Get current state for verification (depends on adapter type)
  let preUpgradeState: Record<string, any> = {};

  if (adapterType === "felix") {
    const adapter = await ethers.getContractAt(contractName, proxyAddress);
    preUpgradeState.name = await adapter.getName();
    preUpgradeState.asset = await adapter.asset();
    preUpgradeState.vault = await adapter.vault();
    preUpgradeState.tvl = (await adapter.getTVL()).toString();
  } else if (adapterType === "hypercore") {
    const adapter = await ethers.getContractAt(contractName, proxyAddress);
    preUpgradeState.vault = await adapter.vault();
    preUpgradeState.hypercoreVault = await adapter.hypercoreVault();
  }

  console.log("\n📊 Pre-upgrade State:");
  for (const [key, value] of Object.entries(preUpgradeState)) {
    console.log(`   ${key}:`, value);
  }

  // Deploy new implementation and upgrade
  console.log("\n🚀 Upgrading to new implementation...");
  const AdapterFactory = await ethers.getContractFactory(contractName);

  const upgraded = await upgrades.upgradeProxy(proxyAddress, AdapterFactory);
  await upgraded.waitForDeployment();

  // Get new implementation address
  const newImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log("✅ Upgrade complete!");
  console.log("   New Implementation:", newImpl);

  // Verify state preserved
  console.log("\n🧪 Verifying state preserved...");
  let postUpgradeState: Record<string, any> = {};

  if (adapterType === "felix") {
    const adapter = await ethers.getContractAt(contractName, proxyAddress);
    postUpgradeState.name = await adapter.getName();
    postUpgradeState.asset = await adapter.asset();
    postUpgradeState.vault = await adapter.vault();
    postUpgradeState.tvl = (await adapter.getTVL()).toString();
  } else if (adapterType === "hypercore") {
    const adapter = await ethers.getContractAt(contractName, proxyAddress);
    postUpgradeState.vault = await adapter.vault();
    postUpgradeState.hypercoreVault = await adapter.hypercoreVault();
  }

  for (const [key, preValue] of Object.entries(preUpgradeState)) {
    const postValue = postUpgradeState[key];
    const match = String(preValue) === String(postValue);
    console.log(`   ${key}: ${postValue}`, match ? "✅" : "❌");
  }

  // Save upgrade info
  const upgradeInfo = {
    contract: contractName,
    adapterType: adapterType,
    network: networkName,
    networkType: mainnet ? "mainnet" : "testnet",
    timestamp: new Date().toISOString(),
    proxy: proxyAddress,
    previousImplementation: currentImpl,
    newImplementation: newImpl,
    upgrader: deployer.address,
  };

  const fileName = `${adapterType}-adapter-upgrade-${Date.now()}-${mainnet ? "mainnet" : "testnet"}.json`;
  const filePath = path.join(process.cwd(), "deployments", fileName);

  const deploymentsDir = path.join(process.cwd(), "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(filePath, JSON.stringify(upgradeInfo, null, 2));
  console.log(`\n📁 Upgrade info saved to deployments/${fileName}`);

  console.log("\n" + "=".repeat(70));
  console.log("Upgrade complete!");
  console.log(`Explorer: ${config.explorerUrl}/address/${newImpl}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Upgrade failed:", error);
    process.exit(1);
  });

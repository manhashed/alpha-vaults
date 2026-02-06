import { ethers, upgrades } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Deploy FelixAdapter as a transparent proxy contract.
 *
 * Usage:
 *   npx hardhat run scripts/adapter/deployment/deployFelixAdapter.ts --network hyperEvmTestnet
 *   npx hardhat run scripts/adapter/deployment/deployFelixAdapter.ts --network hyperEvmMainnet
 *
 * Environment variables:
 *   VAULT_ADDRESS: Address of the AlphaVault that will own this adapter
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nDeploying FelixAdapter on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  // Get vault address
  const vaultAddress = process.env.VAULT_ADDRESS;
  if (!vaultAddress) {
    console.error("\n❌ VAULT_ADDRESS environment variable not set!");
    console.error("   Set VAULT_ADDRESS to the AlphaVault proxy address");
    process.exit(1);
  }

  // Get signer
  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    console.error("\n❌ No signer available!");
    process.exit(1);
  }
  const deployer = signers[0];

  console.log("\n📋 Configuration:");
  console.log("   Network:", mainnet ? "MAINNET" : "TESTNET", `(${networkName})`);
  console.log("   Chain ID:", config.chainId);
  console.log("   Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("   Balance:", ethers.formatEther(balance), "HYPE");

  console.log("\n📊 Adapter Configuration:");
  console.log("   Asset (USDC):", config.usdc);
  console.log("   Vault (Owner):", vaultAddress);
  console.log("   Felix Vault:", config.felixVault);

  // Validate addresses (check for zero address and placeholder)
  if (config.usdc === "0x0000000000000000000000000000000000000000" || config.usdc === "0x...") {
    console.error("\n❌ USDC address not configured for this network!");
    console.error("   Update scripts/shared/config.ts with the correct USDC address");
    process.exit(1);
  }
  if (config.felixVault === "0x0000000000000000000000000000000000000000" || config.felixVault === "0x...") {
    console.error("\n❌ Felix Vault address not configured for this network!");
    console.error("   Update scripts/shared/config.ts with the correct Felix vault address");
    process.exit(1);
  }

  // Deploy
  console.log("\n🚀 Deploying FelixAdapter as Transparent Proxy...");
  const AdapterFactory = await ethers.getContractFactory("FelixAdapter");

  const adapter = await upgrades.deployProxy(
    AdapterFactory,
    [
      config.usdc, // asset_
      vaultAddress, // vault_
      config.felixVault, // felixVault_
      deployer.address, // owner_
    ],
    {
      kind: "transparent",
      initializer: "initialize",
    }
  );

  await adapter.waitForDeployment();
  const proxyAddress = await adapter.getAddress();

  console.log("✅ FelixAdapter Proxy deployed to:", proxyAddress);

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("✅ Implementation at:", implementationAddress);

  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("✅ ProxyAdmin at:", adminAddress);

  // Verify deployment
  console.log("\n🧪 Verifying deployment...");
  const adapterContract = await ethers.getContractAt("FelixAdapter", proxyAddress);

  const name = await adapterContract.getName();
  console.log("   Name:", name);

  const asset = await adapterContract.asset();
  console.log("   Asset:", asset);

  const vault = await adapterContract.vault();
  console.log("   Vault:", vault);

  const tvl = await adapterContract.getTVL();
  console.log("   TVL:", tvl.toString());

  // Save deployment info
  const deploymentInfo = {
    contract: "FelixAdapter",
    network: networkName,
    networkType: mainnet ? "mainnet" : "testnet",
    chainId: config.chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    proxy: proxyAddress,
    implementation: implementationAddress,
    proxyAdmin: adminAddress,
    config: {
      asset: config.usdc,
      vault: vaultAddress,
      underlyingProtocol: config.felixVault,
    },
  };

  const fileName = `felix-adapter-${mainnet ? "mainnet" : "testnet"}.json`;
  const filePath = path.join(process.cwd(), "deployments", fileName);

  const deploymentsDir = path.join(process.cwd(), "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(filePath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\n📁 Deployment info saved to deployments/${fileName}`);

  console.log("\n" + "=".repeat(70));
  console.log("Deployment complete!");
  console.log(`Explorer: ${config.explorerUrl}/address/${proxyAddress}`);

  console.log("\n📝 Next Steps:");
  console.log("   1. Add this adapter to AlphaVault using configureStrategy.ts");
  console.log(`   2. Adapter address: ${proxyAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });

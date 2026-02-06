import { ethers, upgrades } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Deploy AlphaVault as a transparent proxy contract.
 *
 * Usage:
 *   npx hardhat run scripts/vault/deployment/deployVault.ts --network hyperEvmTestnet
 *   npx hardhat run scripts/vault/deployment/deployVault.ts --network hyperEvmMainnet
 *
 * Environment variables:
 *   VAULT_NAME: Custom vault name (default: "Alphavaults Vault")
 *   VAULT_SYMBOL: Custom vault symbol (default: "ALPHAVLT")
 *   TREASURY: Treasury address (default: deployer)
 *   CORE_DEPOSITOR: Circle CoreDepositor address (default: network config)
 *   EPOCH_LENGTH: Epoch length in seconds (optional)
 *   RESERVE_FLOOR_BPS / RESERVE_TARGET_BPS / RESERVE_CEIL_BPS (optional)
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nDeploying AlphaVault on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    console.error("\n❌ No signer available!");
    console.error(`   Make sure ${mainnet ? "MAINNET_PRIVATE_KEY" : "PRIVATE_KEY"} is set in .env`);
    process.exit(1);
  }
  const deployer = signers[0];

  const vaultName = process.env.VAULT_NAME || "Alphavaults Vault";
  const vaultSymbol = process.env.VAULT_SYMBOL || "ALPHAVLT";
  const treasury = process.env.TREASURY || deployer.address;
  const coreDepositor = process.env.CORE_DEPOSITOR || config.coreDepositor;

  console.log("\n📋 Configuration:");
  console.log("   Network:", mainnet ? "MAINNET" : "TESTNET", `(${networkName})`);
  console.log("   Chain ID:", config.chainId);
  console.log("   Deployer:", deployer.address);
  console.log("   Name:", vaultName);
  console.log("   Symbol:", vaultSymbol);
  console.log("   USDC:", config.usdc);
  console.log("   Treasury:", treasury);
  console.log("   CoreDepositor:", coreDepositor);

  if (config.usdc === "0x0000000000000000000000000000000000000000" || config.usdc === "0x...") {
    console.error("\n❌ USDC address not configured for this network!");
    process.exit(1);
  }
  if (coreDepositor === "0x0000000000000000000000000000000000000000" || coreDepositor === "0x...") {
    console.error("\n❌ CoreDepositor address not configured!");
    process.exit(1);
  }

  console.log("\n🚀 Deploying AlphaVault as Transparent Proxy...");
  const VaultFactory = await ethers.getContractFactory("AlphaVault");

  const vault = await upgrades.deployProxy(
    VaultFactory,
    [
      config.usdc,
      vaultName,
      vaultSymbol,
      treasury,
      coreDepositor,
      deployer.address,
    ],
    {
      kind: "transparent",
      initializer: "initialize",
    },
  );

  await vault.waitForDeployment();
  const proxyAddress = await vault.getAddress();

  console.log("✅ Vault Proxy deployed to:", proxyAddress);

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("✅ Implementation at:", implementationAddress);

  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("✅ ProxyAdmin at:", adminAddress);

  const vaultContract = await ethers.getContractAt("AlphaVault", proxyAddress);

  const epochLength = process.env.EPOCH_LENGTH ? BigInt(process.env.EPOCH_LENGTH) : undefined;
  if (epochLength) {
    const tx = await vaultContract.setEpochLength(epochLength);
    await tx.wait();
  }

  const reserveFloor = process.env.RESERVE_FLOOR_BPS;
  const reserveTarget = process.env.RESERVE_TARGET_BPS;
  const reserveCeil = process.env.RESERVE_CEIL_BPS;
  if (reserveFloor && reserveTarget && reserveCeil) {
    const tx = await vaultContract.setReserveConfig(
      Number(reserveFloor),
      Number(reserveTarget),
      Number(reserveCeil),
    );
    await tx.wait();
  }

  const perpsConfigTx = await vaultContract.setPerpsConfig(
    config.perpDexIndex,
    config.perpsTokenId,
    config.perpsTokenScale,
    ethers.ZeroAddress,
  );
  await perpsConfigTx.wait();
  console.log("ℹ️  Vault will only be announced once fully configured.");

  const deploymentInfo = {
    contract: "AlphaVault",
    network: networkName,
    networkType: mainnet ? "mainnet" : "testnet",
    chainId: config.chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    proxy: proxyAddress,
    implementation: implementationAddress,
    proxyAdmin: adminAddress,
    config: {
      name: vaultName,
      symbol: vaultSymbol,
      asset: config.usdc,
      treasury,
      coreDepositor,
    },
  };

  const fileName = `vault-deployment-${mainnet ? "mainnet" : "testnet"}.json`;
  const filePath = path.join(process.cwd(), "deployments", fileName);

  const deploymentsDir = path.join(process.cwd(), "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(filePath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\n📁 Deployment info saved to deployments/${fileName}`);
  console.log(`Explorer: ${config.explorerUrl}/address/${proxyAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });

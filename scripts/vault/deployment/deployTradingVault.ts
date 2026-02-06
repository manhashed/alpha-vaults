import { ethers, upgrades } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Deploy AlphaVault with 50% Felix + 50% HyperCore Trading Vault.
 *
 * Usage:
 *   npx hardhat run scripts/vault/deployment/deployTradingVault.ts --network hyperEvmMainnet
 *
 * Environment variables (optional):
 *   VAULT_NAME, VAULT_SYMBOL, TREASURY
 *   VAULT_ADDRESS (skip vault deployment and reuse)
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nDeploying AlphaVault (Trading Vault 50/50) on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  const [deployer] = await ethers.getSigners();
  if (!deployer) {
    console.error("\n❌ No signer available!");
    process.exit(1);
  }

  const vaultName = process.env.VAULT_NAME || "Alphavaults Trading Vault";
  const vaultSymbol = process.env.VAULT_SYMBOL || "ALPHAT";
  const treasury = process.env.TREASURY || deployer.address;
  const existingVault = process.env.VAULT_ADDRESS || "";
  const coreDepositor = config.coreDepositor;
  const tradingVault = config.tradingVault;

  if (config.usdc === "0x..." || config.usdc === ethers.ZeroAddress) {
    throw new Error("USDC address not configured");
  }
  if (config.felixVault === "0x..." || config.felixVault === ethers.ZeroAddress) {
    throw new Error("Felix vault address not configured");
  }
  if (tradingVault === "0x..." || tradingVault === ethers.ZeroAddress) {
    throw new Error("Trading vault address not configured");
  }
  if (coreDepositor === "0x..." || coreDepositor === ethers.ZeroAddress) {
    throw new Error("CoreDepositor address not configured");
  }

  console.log("\n📋 Configuration:");
  console.log("   Network:", networkName);
  console.log("   Deployer:", deployer.address);
  console.log("   USDC:", config.usdc);
  console.log("   Felix Vault:", config.felixVault);
  console.log("   Trading Vault:", tradingVault);
  console.log("   CoreDepositor:", coreDepositor);

  let vaultAddress = existingVault;
  if (!vaultAddress) {
    const VaultFactory = await ethers.getContractFactory("AlphaVault");
    const vault = await upgrades.deployProxy(
      VaultFactory,
      [config.usdc, vaultName, vaultSymbol, treasury, coreDepositor, deployer.address],
      { kind: "transparent", initializer: "initialize" }
    );
    await vault.waitForDeployment();
    vaultAddress = await vault.getAddress();
    console.log("\n✅ AlphaVault deployed:", vaultAddress);
  } else {
    console.log("\n✅ Using existing AlphaVault:", vaultAddress);
  }

  const vaultContract = await ethers.getContractAt("AlphaVault", vaultAddress);

  if (!existingVault) {
    console.log("ℹ️  Vault is intentionally not announced until fully configured.");
  }

  // 1 day epoch for trading vault strategy
  const epochTx = await vaultContract.setEpochLength(24 * 60 * 60);
  await epochTx.wait();

  const perpsTx = await vaultContract.setPerpsConfig(
    config.perpDexIndex,
    config.perpsTokenId,
    config.perpsTokenScale,
    ethers.ZeroAddress
  );
  await perpsTx.wait();

  const FelixAdapterFactory = await ethers.getContractFactory("FelixAdapter");
  const felixAdapter = await upgrades.deployProxy(
    FelixAdapterFactory,
    [config.usdc, vaultAddress, config.felixVault, deployer.address],
    { kind: "transparent", initializer: "initialize" }
  );
  await felixAdapter.waitForDeployment();
  const felixAdapterAddress = await felixAdapter.getAddress();

  const HyperCoreAdapterFactory = await ethers.getContractFactory("HyperCoreVaultAdapter");
  const hyperCoreAdapter = await upgrades.deployProxy(
    HyperCoreAdapterFactory,
    [config.usdc, vaultAddress, tradingVault, "HyperCore Trading Vault", deployer.address],
    { kind: "transparent", initializer: "initialize" }
  );
  await hyperCoreAdapter.waitForDeployment();
  const hyperCoreAdapterAddress = await hyperCoreAdapter.getAddress();

  console.log("✅ FelixAdapter:", felixAdapterAddress);
  console.log("✅ HyperCoreVaultAdapter:", hyperCoreAdapterAddress);

  const strategies = [
    {
      adapter: felixAdapterAddress,
      targetBps: 5000,
      strategyType: 0, // ERC4626
      active: true,
    },
    {
      adapter: hyperCoreAdapterAddress,
      targetBps: 5000,
      strategyType: 2, // VAULT
      active: true,
    },
  ];

  const strategyTx = await vaultContract.setStrategies(strategies);
  await strategyTx.wait();


  const deploymentInfo = {
    network: networkName,
    chainId: config.chainId,
    timestamp: new Date().toISOString(),
    vault: vaultAddress,
    felixAdapter: felixAdapterAddress,
    hyperCoreAdapter: hyperCoreAdapterAddress,
    tradingVault,
    coreDepositor,
  };

  const fileName = `vault-trading-50-50-${mainnet ? "mainnet" : "testnet"}.json`;
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

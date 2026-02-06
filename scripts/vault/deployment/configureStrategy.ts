import { ethers } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";
import { getNetworkConfig, isMainnet } from "../../shared/config";

/**
 * Configure AlphaVault strategy registry.
 *
 * Usage:
 *   npx hardhat run scripts/vault/deployment/configureStrategy.ts --network hyperEvmTestnet
 *
 * Environment variables:
 *   VAULT_ADDRESS: Address of the deployed AlphaVault proxy
 *   STRATEGY_CONFIG: JSON string of strategy configs
 *     Example:
 *     [
 *       {"adapter":"0x...","targetBps":5000,"strategyType":0,"active":true},
 *       {"adapter":"0x...","targetBps":5000,"strategyType":0,"active":true}
 *     ]
 *
 *   STRATEGY_CONFIG_FILE: Path to JSON file with strategy configs
 */
async function main() {
  const networkName = hre.network.name;
  const config = getNetworkConfig(networkName);
  const mainnet = isMainnet(networkName);

  console.log(`\nConfiguring AlphaVault Strategies on ${mainnet ? "Mainnet" : "Testnet"}...`);
  console.log("=".repeat(70));

  const vaultAddress = process.env.VAULT_ADDRESS;
  if (!vaultAddress) {
    console.error("\n❌ VAULT_ADDRESS environment variable not set!");
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
  console.log("   Vault:", vaultAddress);
  console.log("   Caller:", deployer.address);

  const vault = await ethers.getContractAt("AlphaVault", vaultAddress);

  const owner = await vault.owner();
  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error("\n❌ Caller is not the vault owner!");
    console.error(`   Owner: ${owner}`);
    process.exit(1);
  }

  let strategyInputs: { adapter: string; targetBps: number; strategyType: number; active: boolean }[] = [];

  if (process.env.STRATEGY_CONFIG) {
    strategyInputs = JSON.parse(process.env.STRATEGY_CONFIG);
  } else if (process.env.STRATEGY_CONFIG_FILE) {
    const configPath = process.env.STRATEGY_CONFIG_FILE;
    if (!fs.existsSync(configPath)) {
      console.error(`\n❌ Config file not found: ${configPath}`);
      process.exit(1);
    }
    strategyInputs = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } else {
    console.log("\n⚠️  No strategy configuration provided!");
    console.log("   Set STRATEGY_CONFIG or STRATEGY_CONFIG_FILE");
    process.exit(1);
  }

  const totalBps = strategyInputs.reduce((sum, s) => sum + (s.active ? s.targetBps : 0), 0);
  if (totalBps !== 10000) {
    console.error(`\n❌ Active strategy allocations must sum to 10000 bps (100%)!`);
    console.error(`   Current sum: ${totalBps} bps`);
    process.exit(1);
  }

  console.log("\n📊 Strategy Configuration:");
  for (const input of strategyInputs) {
    console.log(`   ${input.adapter}: ${input.targetBps} bps (type ${input.strategyType}) active=${input.active}`);
  }

  console.log("\n🚀 Calling setStrategies...");
  const tx = await vault.setStrategies(strategyInputs);
  console.log("   Transaction hash:", tx.hash);

  const receipt = await tx.wait();
  console.log("   ✅ Transaction confirmed in block:", receipt?.blockNumber);
  console.log(`Explorer: ${config.explorerUrl}/tx/${tx.hash}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Configuration failed:", error);
    process.exit(1);
  });

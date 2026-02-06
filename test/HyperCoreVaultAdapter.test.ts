import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import type { HyperCoreVaultAdapter } from "../typechain-types";

describe("HyperCoreVaultAdapter", () => {
  let adapter: HyperCoreVaultAdapter;
  let owner: SignerWithAddress;
  let userVault: SignerWithAddress;
  let underlyingVault: SignerWithAddress;

  beforeEach(async () => {
    [owner, userVault, underlyingVault] = await ethers.getSigners();

    const AdapterFactory = await ethers.getContractFactory("HyperCoreVaultAdapter");
    adapter = (await upgrades.deployProxy(
      AdapterFactory,
      [
        owner.address, // asset (dummy)
        userVault.address, // vault (depositor)
        underlyingVault.address, // hypercore vault
        "HyperCore Vault", // name
        owner.address, // owner
      ],
      { initializer: "initialize", unsafeAllow: ["constructor"] },
    )) as unknown as HyperCoreVaultAdapter;
    await adapter.waitForDeployment();
  });

  it("initializes with correct parameters", async () => {
    expect(await adapter.vault()).to.equal(userVault.address);
    expect(await adapter.hypercoreVault()).to.equal(underlyingVault.address);
    expect(await adapter.getUnderlyingVault()).to.equal(underlyingVault.address);
  });

  it("reverts when precompile not available", async () => {
    await expect(adapter.getTVL()).to.be.revertedWithCustomError(
      adapter,
      "VaultEquityPrecompileCallFailed",
    );
  });
});

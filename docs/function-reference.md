# Function Reference (Current Architecture)

This reference summarizes how each **public/external** function behaves and the key **internal** flows.
It reflects the current codebase with:
- burn‑on‑queue withdrawals
- `pendingWithdrawalAssets` accounting
- `deployBatch()` for strategy allocation
- `settleEpoch()` for minting + withdrawal payout (HyperEVM liquidity only)

---

## AlphaVault.sol (Public / External)

### Initialization
- `initialize(asset, name, symbol, treasury, coreDepositor, owner)`
  - Sets core config, fees, reserve defaults, perps defaults, deployment cadence.

### Epoch + ERC‑4626
- `getCurrentEpoch()`
  - Returns `block.timestamp / epochLength`.
- `getTimeUntilNextEpoch()`
  - Seconds remaining in current epoch.
- `totalAssets()`
  - L1 idle (minus pending deposits) + L2 TVL + perps + vault equity − pending withdrawals.
- `deposit(assets, receiver)`
  - Transfers USDC in, applies fee, queues net assets.
- `mint(shares, receiver)`
  - Calculates required assets, applies fee, queues net assets.
- `withdraw(assets, receiver, owner)`
  - Burns shares, queues withdrawal request, increments `pendingWithdrawalAssets`.
- `redeem(shares, receiver, owner)`
  - Burns shares, queues withdrawal request, increments `pendingWithdrawalAssets`.

### Settlement & Processing
- `settleEpoch(epochId)`
  - Mints shares for queued deposits.
  - Attempts withdrawal payouts using L1 + ERC4626 liquidity only.
  - Does **not** call HyperCore.
- `processQueuedWithdrawals()`
  - Enforces reserve, retries FIFO payout queue.

### Deployment / Allocation
- `deployBatch()`
  - Keeper‑driven allocator.
  - Uses cadence (`deploymentInterval`) and batch cap (`maxDeploymentAmount`).
  - Allocates L1 → ERC4626 + PERPS, then perps → VAULTs if balance updated.

### Strategy Registry
- `setStrategies(StrategyInput[])`
  - Replaces registry; validates targets and duplicates.

### Admin Configuration
- `setTreasury(address)`
- `setEpochLength(uint256)`
- `setDepositFee(uint16)`
- `setWithdrawFee(uint16)`
- `setReserveConfig(uint16 floor, uint16 target, uint16 ceil)`
- `setCoreDepositor(address)`
- `setPerpsConfig(uint32 dex, uint64 tokenId, uint64 scale, address subAccount)`
- `setDeploymentConfig(uint256 interval, uint256 maxBatchAmount)`
- `setDeploymentOperator(address)`
- `pause()` / `unpause()`
- `recoverTokens(token, to)`

---

## AlphaVault.sol (Key Internal Logic)

- `_processWithdrawals(epochId)`
  - FIFO all‑or‑nothing. Skips when head cannot be paid.
  - Reduces `pendingWithdrawalAssets` for processed requests.
- `_prepareLiquidity(amount)`
  - Withdraws from ERC4626 adapters only.
- `_withdrawFromERC4626(amount)`
  - Pulls from adapters using receipt tokens; reverts if adapter returns 0.
- `_sendPerpsToEvm(amount)`
  - Cowriter `sendAsset` to move perps → spot (async).
- `_rebalanceAndAllocate(maxL1Deployable)`
  - Allocates to ERC4626, PERPS, then VAULTs (if perps excess).
- `_enforceReserve()`
  - If withdrawable < floor: pauses deployment, recalls VAULTs, sends perps to EVM.
  - If > ceiling: unpauses deployment.

---

## StrategyLib.sol

- `validateStrategyInputs(StrategyInput[])`
  - Ensures active targets sum to 10000 bps, no duplicates, only one PERPS.
- `calculateTargetAmounts(deployableAssets, Strategy[])`
  - Splits deployable capital across active strategies.
- `bpsToPercentage(bps)`
  - Utility for display.

---

## HyperCoreReadPrecompile.sol

- `getSpotBalance(user, tokenId)`
  - L1 spot balance (1e8 scale).
- `getUserVaultEquity(user, vault)`
  - Vault equity and lockup timestamp.
- `getAccountMarginSummary(perpDexIndex, user)`
  - Returns accountValue + rawUsd.
- `getPerpsRawUsd(perpDexIndex, user)`
  - Raw USD balance (1e8).
- `getPerpsUsdcBalance(perpDexIndex, user)`
  - Converts rawUsd to USDC decimals (1e6).
- `scaleCoreToUSDC(uint64)`
  - Utility conversion from 1e8 → 1e6.

---

## HyperCoreWritePrecompile.sol

- `sendAsset(destination, subAccount, sourceDex, destinationDex, token, weiAmount)`
  - Cowriter Action 13: perps → spot transfer (async).
- `vaultTransfer(vault, isDeposit, usdAmount)`
  - Cowriter Action 2: deposit/withdraw into HyperCore vaults (async).
- `scaleUSDCToCore(uint256)`
  - Utility conversion from 1e6 → 1e8.

---

## Adapters

### FelixAdapter.sol (ERC4626)
- `deposit(amount)` → deposits into Felix vault, shares minted to AlphaVault
- `withdraw(amount)` → redeems Felix shares to AlphaVault
- `getTVL()` → reads Felix share value for AlphaVault
- `getReceiptToken()` → returns Felix vault share token

### HyperCoreVaultAdapter.sol (Read‑Only)
- `getTVL()` → reads vault equity via precompile
- `getUnlockTime()` → reads lockup timestamp
- `maxWithdraw()` → 0 if locked, else equity

---

## ICoreDepositor.sol

- `deposit(amount, destinationDex)`
  - Circle CoreDepositor: HyperEVM USDC → HyperCore perps

# Keeper / Operator Runbook

This runbook explains how the owner/keeper should operate the vault after deployment.
It assumes the current architecture:
- deposits/withdrawals are queued
- shares are burned at withdrawal request
- `settleEpoch()` never triggers HyperCore writes
- HyperCore writes happen only in `deployBatch()` and (optionally) `processQueuedWithdrawals()`

---

## Roles

**Owner**
- Sets configuration (fees, reserve, strategies, perps config)
- Can call any keeper function

**Deployment Operator**
- Optional address set via `setDeploymentOperator()`
- Can call `deployBatch()` (and all owner functions if also owner)

**Keeper**
- Off‑chain automation that calls `settleEpoch()`, `processQueuedWithdrawals()`, and `deployBatch()`

---

## Initial Setup Checklist

1. **Set strategy registry**
   - `setStrategies(StrategyInput[])`
   - Ensure active targets sum to 10000 bps
   - PERPS must use `adapter = address(0)`

2. **Set perps configuration**
   - `setPerpsConfig(perpDexIndex, tokenId, tokenScale, subAccount)`
   - Defaults: dex = 0, tokenId = 0 (USDC), tokenScale = 1e6

3. **Set reserve policy**
   - `setReserveConfig(floorBps, targetBps, ceilBps)`
   - Floor: minimum withdrawable liquidity (L1 + ERC4626 maxWithdraw)

4. **Set deployment cadence**
   - `setDeploymentConfig(intervalSeconds, maxBatchAmount)`
   - `maxBatchAmount = 0` means no cap

5. **Set keeper address (optional)**
   - `setDeploymentOperator(keeperAddress)`

---

## Daily / Epoch Operations

### 1) Settle the previous epoch
**When:** Shortly after epoch end  
**Call:** `settleEpoch(currentEpoch - 1)`

What it does:
- Mints shares for queued deposits
- Attempts withdrawals using **L1 + ERC4626 only**
- Leaves HyperCore writes to `deployBatch` / `processQueuedWithdrawals`

If it reverts:
- `InvalidAmount` → wrong epoch ID or already settled
- Ensure epochs are processed sequentially

### 2) Retry queued withdrawals
**When:** After liquidity is expected to arrive  
**Call:** `processQueuedWithdrawals()`

What it does:
- Calls `_enforceReserve()` (may trigger perps → EVM sendAsset)
- Attempts to pay FIFO withdrawals again

If it reverts:
- `InsufficientWithdrawableLiquidity` → wait for liquidity and retry

### 3) Deploy capital into strategies
**When:** On a cadence (`deploymentInterval`)  
**Call:** `deployBatch()`

What it does:
- Allocates L1 to ERC4626 and PERPS strategies
- May transfer perps → VAULT if perps balance already updated

Important:
- Perps deposits settle **in the next block**
- VAULT transfers may need a **second** `deployBatch()` call

If it reverts:
- `DeploymentTooSoon` → wait until `lastDeploymentAt + interval`
- `DeploymentUnauthorized` → caller is not owner/operator

---

## Failure Handling Playbook

### A) Withdrawals stuck (no liquidity)
1. Call `processQueuedWithdrawals()`
2. If it reverts, trigger liquidity:
   - Ensure ERC4626 adapters can redeem
   - If perps balance exists, call again after sendAsset settles
3. Retry `processQueuedWithdrawals()`

### B) Deployment paused
Deployment pauses automatically when withdrawable liquidity drops below the floor.

Actions:
1. Call `processQueuedWithdrawals()` to trigger reserve enforcement.
2. Wait for perps → EVM transfers to settle.
3. Retry `processQueuedWithdrawals()` until `pendingWithdrawalAssets == 0`.
4. Once withdrawable liquidity exceeds the ceiling, `deploymentPaused` clears.

### C) Perps → Vault transfers not happening
This can occur because perps balances update asynchronously.

Actions:
1. Call `deployBatch()` to deposit L1 into perps.
2. Wait at least one block for perps balance to update.
3. Call `deployBatch()` again to move perps excess into VAULT strategies.

### D) Strategy removal blocked
`setStrategies()` reverts if a removed adapter still has TVL.

Actions:
1. Set target weights to 0 for that adapter.
2. Use `processQueuedWithdrawals()` + `deployBatch()` to unwind positions.
3. Once TVL is 0, update the registry.

---

## Parameter Reference (Units)

- **Fees:** basis points (1% = 100)
- **Reserve config:** basis points (floor/target/ceil)
- **Deployment interval:** seconds
- **maxBatchAmount:** USDC in 6 decimals (0 = unlimited)
- **Perps token scale:** USDC decimals (default 1e6)
- **Perps token id:** 0 (USDC)
- **Perps dex index:** typically 0

---

## Monitoring Checklist

On each keeper cycle, monitor:
- `pendingWithdrawalAssets`
- `getWithdrawableLiquidity()`
- `deploymentPaused`
- `lastDeploymentAt` / `deploymentInterval`
- `totalAssets()`

Optional external checks:
- Perps balance for the vault address via HyperCore precompile
- HyperCore vault equity for VAULT strategies

## Alphavaults - Updated Lifecycle Diagrams (Queued + Batching)

This document reflects the **current** on-chain behavior:
- Shares are **burned at withdrawal request**
- `pendingWithdrawalAssets` tracks queued assets
- `settleEpoch()` only mints shares and pays withdrawals from HyperEVM liquidity
- `deployBatch()` performs allocation to strategies (async HyperCore writes)
- **No partial withdrawals**: FIFO, all-or-nothing

---

## 1) Deposit Lifecycle (Queue → Mint)

```
EPOCH N (Deposit Request)
USER
  └─ deposit(1000 USDC, alice)

AlphaVault.deposit()
  1) Validate inputs
  2) Apply deposit fee (if any)
  3) Transfer USDC to vault
  4) Queue net assets into epoch N
  5) No shares minted yet

State:
  epochPendingDeposits[N] += netAssets
  totalPendingDeposits += netAssets

EPOCH N+1 (Settlement)
KEEPER / OWNER
  └─ settleEpoch(N)

AlphaVault.settleEpoch()
  1) Snapshot totalSupply/totalAssets
  2) Mint shares for each queued deposit (ERC-4626 math)
  3) Clear pending deposits
  4) Attempt withdrawals (from HyperEVM liquidity only)

Result:
  Shares minted to users
  No HyperCore writes executed here
```

---

## 2) Withdrawal Lifecycle (Burn → Queue → Pay)

```
EPOCH N (Withdrawal Request)
USER
  └─ withdraw(1000 USDC, alice, alice)

AlphaVault.withdraw()
  1) Calculate required shares
  2) Burn shares immediately
  3) Append FIFO withdrawal request
  4) pendingWithdrawalAssets += assets

State:
  totalSupply decreased immediately
  pendingWithdrawalAssets increased
  request stored in _withdrawalQueue

EPOCH N+1 (Settlement)
KEEPER / OWNER
  └─ settleEpoch(N)

AlphaVault.settleEpoch()
  1) Mint queued deposits
  2) Process withdrawals using:
     - L1 idle USDC
     - ERC4626 maxWithdraw (L2)
  3) If insufficient, request remains queued

Result:
  FIFO, all-or-nothing payouts
  No partial withdrawals
```

**Partial withdrawals are NOT supported.**  
If the head request cannot be paid in full, **no** later requests are processed.

---

## 3) Async Liquidity & Retrying Withdrawals

HyperCore writes are async. Liquidity from perps/vaults may arrive in later blocks.

```
KEEPER / OWNER
  └─ processQueuedWithdrawals()

processQueuedWithdrawals()
  1) enforce reserve (may trigger perps → EVM)
  2) retry _processWithdrawals() for prior epoch

If still insufficient:
  - requests remain queued
  - try again after liquidity arrives
```

---

## 4) Deployment Lifecycle (Batch Allocation)

```
KEEPER / DEPLOYMENT OPERATOR
  └─ deployBatch()

deployBatch()
  1) enforce reserve
  2) if pending withdrawals -> do nothing
  3) respect deploymentInterval
  4) allocate L1 to ERC4626 + PERPS
  5) if perps balance already updated, move excess to VAULTs

Note:
  Perps deposits update in a later block.
  VAULT transfers may require a second deployBatch call.
```

---

## 5) Reserve Policy (Floor / Target / Ceiling)

Definitions:
- **Floor**: minimum liquidity to keep (L1 + ERC4626 maxWithdraw)
- **Target**: desired reserve for deployment sizing
- **Ceiling**: upper bound where deployment is unpaused

Behavior:
- If withdrawable < floor:
  - pause deployment
  - recall from VAULTs
  - send perps to EVM
- If withdrawable > ceiling:
  - allow deployment again

---

## 6) What Happens in Each Cycle (Recommended)

1. **After epoch ends**
   - `settleEpoch(previousEpoch)`

2. **Once liquidity arrives**
   - `processQueuedWithdrawals()`

3. **On deployment cadence**
   - `deployBatch()` (may need multiple calls for perps → vault)
```

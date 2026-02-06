# Alphavaults - Architecture & Flow Diagrams

---

## 1. SYSTEM ARCHITECTURE OVERVIEW

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           USER INTERACTIONS                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ deposit()│  │  mint()  │  │withdraw()│  │ redeem() │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
└───────┼─────────────┼─────────────┼─────────────┼────────────────────┘
        │             │             │             │
        └─────────────┴─────────────┴─────────────┘
                      │
        ┌─────────────▼──────────────────────────────────────┐
        │         AlphaVault (ERC-4626)                     │
        │  ┌──────────────────────────────────────────────┐  │
        │  │  CUSTODY LAYER (Holds all funds & shares)   │  │
        │  │  - USDC balance (L1)                        │  │
        │  │  - ERC4626 receipt tokens (Felix shares)    │  │
        │  │  - Pending deposits tracking                │  │
        │  │  - Pending withdrawals queue                │  │
        │  └──────────────────────────────────────────────┘  │
        └────┬────────────┬────────────┬──────────────┬──────┘
             │            │            │              │
    ┌────────▼──┐  ┌─────▼──────┐  ┌─▼──────┐  ┌───▼─────────┐
    │  Felix    │  │ HyperCore  │  │ Perps  │  │ HyperCore   │
    │  Adapter  │  │   Vault    │  │ (via   │  │   Vault     │
    │ (ERC4626) │  │  Adapter   │  │CoreDep)│  │   Adapter   │
    │  L2       │  │  (Read)    │  │  L3    │  │   (Read)    │
    └────┬──────┘  └─────┬──────┘  └─┬──────┘  └───┬─────────┘
         │               │            │             │
    ┌────▼────────┐ ┌────▼─────────┐ │        ┌────▼──────────┐
    │   Felix     │ │  HyperCore   │ │        │  HyperCore    │
    │   Vault     │ │     HLP      │ │        │Trading Vaults │
    │  Protocol   │ │    Vault     │ │        │  (Lockups)    │
    └─────────────┘ └──────────────┘ │        └───────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │  HyperCore Perps Layer  │
                         │  (via Precompiles)      │
                         └─────────────────────────┘
```

**Key Architectural Principles:**
1. ✅ AlphaVault is the ONLY custodian
2. ✅ Adapters are stateless executors
3. ✅ No user-facing HyperCore dependencies
4. ✅ Async, non-atomic deployments

---

## 2. DEPOSIT LIFECYCLE FLOW

```
┌──────────────────────────────────────────────────────────────────────┐
│                      DEPOSIT FLOW (Queued)                           │
└──────────────────────────────────────────────────────────────────────┘

User calls deposit(assets, receiver)
         │
         ├─ 1. Validation
         │    ├─ assets > 0
         │    ├─ receiver != 0x0
         │    └─ strategies.length > 0
         │
         ├─ 2. Calculate Fee
         │    ├─ fee = assets * depositFeeBps / 10000
         │    └─ netAssets = assets - fee
         │
         ├─ 3. Transfer Assets
         │    ├─ USDC.safeTransferFrom(user, vault, assets)
         │    └─ USDC.safeTransfer(treasury, fee)
         │
         ├─ 4. Queue Deposit (NO SHARES MINTED YET!)
         │    ├─ epoch = getCurrentEpoch()
         │    ├─ _epochDeposits[epoch].push(DepositEntry{...})
         │    ├─ epochPendingDeposits[epoch] += netAssets
         │    └─ totalPendingDeposits += netAssets
         │
         ├─ 5. Emit Events
         │    ├─ emit DepositQueued(...)
         │    └─ emit Deposit(...)
         │
         └─ 6. Return (shares not actually minted, just preview value)

┌─────────────────────────────────────────────────────────────────────┐
│              SETTLEMENT FLOW (settleEpoch called later)             │
└─────────────────────────────────────────────────────────────────────┘

Keeper calls settleEpoch(epochId)
         │
         ├─ 1. Validation
         │    ├─ !epochSettled[epochId]
         │    └─ epochId < getCurrentEpoch()
         │
         ├─ 2. Snapshot State
         │    ├─ supplyBefore = totalSupply()
         │    ├─ assetsBefore = totalAssets()  ← EXCLUDES pending deposits!
         │    ├─ virtualShares = 10^6
         │    ├─ sharesDenom = supplyBefore + virtualShares
         │    └─ assetsNum = assetsBefore + 1
         │
         ├─ 3. Process Deposits
         │    │
         │    └─ For each deposit entry:
         │         ├─ userShares = (entryAssets * sharesDenom) / assetsNum
         │         ├─ _mint(receiver, userShares)
         │         └─ emit DepositSettled(...)
         │
         ├─ 4. Update State
         │    ├─ epochPendingDeposits[epochId] = 0
         │    ├─ totalPendingDeposits -= depositAssets
         │    └─ delete _epochDeposits[epochId]
         │
         ├─ 5. Process Withdrawals
         │    └─ _processWithdrawals(epochId)
         │
         └─ 6. Mark Settled
              └─ epochSettled[epochId] = true

```

**⚠️ CRITICAL ISSUE:** `totalAssets()` excludes pending deposits, causing incorrect share pricing!

---

## 3. WITHDRAWAL LIFECYCLE FLOW

```
┌────────────────────────────────────────────────────────────────────┐
│              WITHDRAWAL REQUEST FLOW (Immediate)                   │
└────────────────────────────────────────────────────────────────────┘

User calls withdraw(assets, receiver, owner)
         │
         ├─ 1. Validation
         │    ├─ assets > 0
         │    ├─ receiver != 0x0
         │    └─ shares = previewWithdraw(assets)
         │
         ├─ 2. Burn Shares IMMEDIATELY
         │    ├─ Check: shares <= balanceOf(owner)
         │    ├─ _spendAllowance (if msg.sender != owner)
         │    └─ _burn(owner, shares)  ← SHARES BURNED NOW!
         │
         ├─ 3. Queue Withdrawal Request
         │    ├─ epoch = getCurrentEpoch()
         │    ├─ pendingWithdrawalAssets += assets
         │    ├─ _withdrawalQueue.push(WithdrawalRequest{...})
         │    └─ epochWithdrawalCounts[epoch] += 1
         │
         ├─ 4. Emit Events
         │    ├─ emit WithdrawalQueued(...)
         │    └─ emit Withdraw(...)
         │
         └─ 5. Return (no assets paid yet)

┌────────────────────────────────────────────────────────────────────┐
│              WITHDRAWAL PROCESSING FLOW (Later)                    │
└────────────────────────────────────────────────────────────────────┘

Keeper calls processQueuedWithdrawals() OR settleEpoch()
         │
         └─── _processWithdrawals(epochId)
                │
                ├─ 1. Check Liquidity
                │    └─ availableLiquidity = _availableL1() + _erc4626Withdrawable()
                │                          ← EXCLUDES HyperCore!
                │
                ├─ 2. Calculate Payable Requests (FIFO)
                │    ├─ idx = withdrawalQueueHead
                │    └─ While (idx < queue.length):
                │         ├─ if request.epoch > epochId: BREAK
                │         ├─ if availableLiquidity < request.assets: BREAK
                │         ├─ availableLiquidity -= request.assets
                │         ├─ totalAssetsToPay += request.assets
                │         └─ idx++
                │
                ├─ 3. Prepare Liquidity
                │    └─── _prepareLiquidity(totalAssetsToPay)
                │           │
                │           ├─ If L1 balance sufficient: DONE
                │           │
                │           └─ Else: _withdrawFromERC4626(remaining)
                │                │
                │                └─ For each ERC4626 strategy:
                │                     ├─ Calculate shares needed
                │                     ├─ Transfer shares to adapter
                │                     └─ adapter.withdraw(toWithdraw)
                │                          ← ⚠️ REVERTS if adapter fails!
                │
                ├─ 4. Pay Withdrawals
                │    └─ For each request (withdrawalQueueHead to idx):
                │         ├─ fee = assets * withdrawFeeBps / 10000
                │         ├─ netAssets = assets - fee
                │         ├─ USDC.safeTransfer(receiver, netAssets)
                │         ├─ USDC.safeTransfer(treasury, fee)
                │         └─ emit WithdrawalProcessed(...)
                │
                ├─ 5. Update Queue
                │    ├─ withdrawalQueueHead = idx
                │    └─ pendingWithdrawalAssets -= processedAssets
                │
                └─ 6. Return totalPaid

```

**⚠️ CRITICAL ISSUE:** If ANY ERC4626 adapter.withdraw() fails, entire withdrawal processing reverts!

**✅ CORRECT BEHAVIOR:** Withdrawals only use L1 + ERC4626, never depend on HyperCore lockups.

---

## 4. DEPLOYMENT BATCH FLOW

```
┌────────────────────────────────────────────────────────────────────┐
│                   DEPLOYMENT BATCH FLOW                            │
└────────────────────────────────────────────────────────────────────┘

Keeper calls deployBatch()
         │
         ├─ 1. Enforce Reserve
         │    └─── _enforceReserve()
         │           │
         │           ├─ Calculate required liquidity
         │           │    ├─ total = totalAssets()
         │           │    ├─ withdrawable = _getWithdrawableLiquidity()
         │           │    ├─ floorAmount = total * reserveFloorBps / 10000
         │           │    └─ ceilAmount = total * reserveCeilBps / 10000
         │           │
         │           ├─ If withdrawable < floorAmount:
         │           │    ├─ deploymentPaused = true
         │           │    ├─ deficit = floorAmount - withdrawable
         │           │    ├─ _recallFromVaults(deficit)
         │           │    └─ _sendPerpsToEvm(deficit)
         │           │
         │           └─ Else if withdrawable > ceilAmount:
         │                └─ deploymentPaused = false
         │
         ├─ 2. Check Deployment Conditions
         │    ├─ If deploymentPaused: return 0
         │    ├─ If _hasPendingWithdrawals(): return 0  ← ⚠️ BLOCKS!
         │    └─ If too soon (interval check): revert
         │
         ├─ 3. Deploy Assets
         │    └─── _rebalanceAndAllocate(maxDeploymentAmount)
         │           │
         │           ├─ Calculate Targets
         │           │    ├─ total = totalAssets()
         │           │    ├─ reserveTarget = total * reserveTargetBps / 10000
         │           │    ├─ deployable = total - reserveTarget
         │           │    ├─ targets = StrategyLib.calculateTargetAmounts(deployable)
         │           │    └─ currents = _currentStrategyAmounts()
         │           │
         │           ├─ Deploy to ERC4626 (if target > current)
         │           │    ├─ USDC.safeTransfer(adapter, amount)
         │           │    └─ adapter.deposit(amount)  ← Shares → vault
         │           │
         │           ├─ Deploy to Perps (if target > current)
         │           │    ├─ USDC.approve(coreDepositor, amount)
         │           │    └─ coreDepositor.deposit(amount, perpDexIndex)
         │           │
         │           ├─ Calculate Perps Excess
         │           │    ├─ perpsCurrent = _perpsBalance()
         │           │    ├─ perpsProjected = perpsCurrent + perpsAdded
         │           │    └─ perpsExcess = perpsProjected - perpsTarget
         │           │
         │           └─ Deploy to HyperCore Vaults (from perps excess)
         │                ├─ scaled = scaleUSDCToCore(amount)
         │                └─ vaultTransfer(vault, true, scaled)
         │                     ← Direct precompile call
         │
         └─ 4. Emit Event & Return
              ├─ lastDeploymentAt = block.timestamp
              └─ emit DeploymentExecuted(deployedAssets)

```

**Flow Diagram: L1 → L2 → L3 → L4**

```
    L1 (Vault)        L2 (ERC4626)       L3 (Perps)      L4 (HyperCore Vaults)
    ──────────        ────────────       ──────────      ─────────────────────
        │
        ├─ USDC ────→ Felix Adapter ────→ Receipt Tokens → Vault
        │             (stateless)          (held by vault)
        │
        ├─ USDC ────→ CoreDepositor ────→ Perps Balance
        │             (approval)           (read via precompile)
        │
        └─────────────────────────────────→ Perps Excess
                                             │
                                             └──→ HyperCore Vaults
                                                  (via vaultTransfer precompile)
                                                  (lockup applies)
```

**⚠️ Issue:** Deployment blocks if ANY pending withdrawals exist (line 475).

---

## 5. RESERVE MANAGEMENT & RECALL FLOW

```
┌────────────────────────────────────────────────────────────────────┐
│                   RESERVE ENFORCEMENT FLOW                         │
└────────────────────────────────────────────────────────────────────┘

_enforceReserve() called from deployBatch() or processQueuedWithdrawals()
         │
         ├─ 1. Calculate Thresholds
         │    ├─ total = totalAssets()
         │    ├─ withdrawable = _availableL1() + _erc4626Withdrawable()
         │    ├─ floorAmount = total * reserveFloorBps / 10000    (default: 35%)
         │    ├─ targetAmount = total * reserveTargetBps / 10000  (default: 40%)
         │    └─ ceilAmount = total * reserveCeilBps / 10000      (default: 45%)
         │
         ├─ 2. Below Floor? (Emergency Recall)
         │    │
         │    └─ If withdrawable < floorAmount:
         │         │
         │         ├─ Pause Deployments
         │         │    └─ deploymentPaused = true
         │         │
         │         ├─ Calculate Deficit
         │         │    └─ deficit = floorAmount - withdrawable
         │         │
         │         ├─ Recall from HyperCore Vaults
         │         │    └─── _recallFromVaults(deficit)
         │         │           │
         │         │           └─ For each VAULT strategy:
         │         │                ├─ maxNow = adapter.maxWithdraw()
         │         │                │    └─ Returns 0 if locked!
         │         │                ├─ If unlocked:
         │         │                │    ├─ scaled = scaleUSDCToCore(amount)
         │         │                │    └─ vaultTransfer(vault, false, scaled)
         │         │                │         └─ Funds → Perps balance
         │         │                └─ withdrawn += actual
         │         │
         │         └─ Send Perps to EVM (Spot)
         │              └─── _sendPerpsToEvm(deficit)
         │                     │
         │                     ├─ perpsBalance = _perpsBalance()
         │                     ├─ toSend = min(deficit, available)
         │                     ├─ scaled = _scaleUsdcToPerps(toSend)
         │                     └─ sendAsset(
         │                          source: perps (dexIndex),
         │                          dest: spot (uint32::MAX),
         │                          amount: scaled
         │                        )
         │                        └─ Funds → L1 vault balance
         │
         └─ 3. Above Ceiling? (Unpause)
              └─ If withdrawable > ceilAmount && deploymentPaused:
                   └─ deploymentPaused = false

```

**Reserve States:**

```
    0%        35%       40%       45%       100%
    ├─────────┼─────────┼─────────┼──────────┤
              │         │         │
            FLOOR     TARGET    CEILING
              │         │         │
              │         │         │
    < FLOOR:  │         │         │  > CEILING:
    - Pause   │         │         │  - Unpause
    - Recall  │         │         │  - Normal ops
              │         │         │
```

**✅ Cooldown-Aware:** `maxWithdraw()` returns 0 if HyperCore vault is locked.

---

## 6. TOTAL ASSETS CALCULATION FLOW

```
┌────────────────────────────────────────────────────────────────────┐
│                   totalAssets() CALCULATION                        │
└────────────────────────────────────────────────────────────────────┘

totalAssets() view function
         │
         ├─ 1. L1 Available Assets
         │    └─── _availableL1()
         │           │
         │           └─ idle = USDC.balanceOf(vault)
         │              return idle > totalPendingDeposits 
         │                     ? idle - totalPendingDeposits : 0
         │                        ⚠️ Pending deposits NOT in totalAssets!
         │
         ├─ 2. L2 ERC4626 TVL
         │    └─── _erc4626TVL()
         │           │
         │           └─ For each ERC4626 strategy:
         │                └─ tvl += adapter.getTVL()
         │                     └─ Felix: felixVault.convertToAssets(vault shares)
         │
         ├─ 3. L3 Perps Balance (signed)
         │    └─── _applySignedBalance(total, _perpsBalance())
         │           │
         │           ├─ perpsBalance = HyperCoreReadPrecompile.getPerpsUsdcBalance()
         │           └─ If >= 0: total += balance
         │              If < 0:  total -= abs(balance)  (can floor at 0)
         │
         ├─ 4. L4 HyperCore Vault TVL
         │    └─── _vaultTVL()
         │           │
         │           └─ For each VAULT strategy:
         │                └─ (equity, locked) = getUserVaultEquity(vault, hyperVault)
         │                   tvl += scaleCoreToUSDC(equity)
         │
         └─ 5. Subtract Pending Withdrawals
              └─── _applyPendingWithdrawals(total)
                     │
                     └─ return total > pendingWithdrawalAssets
                              ? total - pendingWithdrawalAssets : 0

```

**Formula:**
```
totalAssets = (L1_balance - pendingDeposits)      ← ⚠️ Issue here!
            + ERC4626_TVL
            + signed(Perps_balance)
            + HyperCore_Vault_TVL
            - pendingWithdrawalAssets
```

**⚠️ CRITICAL ISSUE:** Pending deposits are excluded from `totalAssets`, but they ARE in the vault balance. This creates incorrect share pricing during settlement!

---

## 7. SHARE PRICING & ERC-4626 MATH

```
┌────────────────────────────────────────────────────────────────────┐
│              ERC-4626 SHARE PRICE CALCULATION                      │
└────────────────────────────────────────────────────────────────────┘

Share Price = totalAssets() / totalSupply()

With virtual shares offset (ERC4626Upgradeable pattern):
  - decimalsOffset = 6
  - virtualShares = 10^6
  - Denominator = totalSupply() + virtualShares
  - Numerator = totalAssets() + 1

Shares minted for deposit:
  userShares = (depositAssets * (totalSupply() + 10^6)) / (totalAssets() + 1)

Scenario: First deposit with zero TVL
  - totalSupply() = 0
  - totalAssets() = 0  (assuming all deployed)
  - userShares = (depositAssets * 10^6) / 1
  - ⚠️ Massive share inflation!

Scenario: Settlement with pending deposits
  - User deposits 100k USDC
  - Vault has 1M deployed, 0 in L1
  - totalAssets() = 1M  (excludes 100k pending!)
  - totalSupply() = 1M shares
  - userShares = (100k * (1M + 10^6)) / (1M + 1)
  - ⚠️ Incorrect! Should use 1.1M as base!

```

**Correct Formula Should Be:**
```
totalAssets = L1_balance (includes pending)
            + ERC4626_TVL
            + Perps_balance
            + Vault_TVL
            - pendingWithdrawalAssets
```

---

## 8. ADAPTER INTERACTION PATTERNS

### **FelixAdapter (ERC4626 - Stateless)**

```
Deposit Flow:
  1. Vault → Transfer USDC to adapter
  2. Adapter → Approve Felix vault
  3. Adapter → felixVault.deposit(amount, vault)  ← Shares to VAULT
  4. Adapter balance: 0 USDC, 0 shares

Withdraw Flow:
  1. Vault → Transfer Felix shares to adapter
  2. Adapter → felixVault.withdraw(amount, vault, adapter)
  3. Adapter → Return excess shares to vault
  4. Adapter balance: 0 USDC, 0 shares

TVL:
  felixVault.convertToAssets(vault.balanceOf(felixShares))
```

### **HyperCoreVaultAdapter (Read-Only)**

```
Deposit:
  ✗ Reverts (read-only)

Withdraw:
  ✗ Reverts (read-only)

TVL:
  (equity, lockedUntil) = getUserVaultEquity(vault, hypercoreVault)
  return scaleCoreToUSDC(equity)

maxWithdraw:
  If block.timestamp < lockedUntil:
    return 0  ← LOCKED!
  Else:
    return getTVL()
```

**✅ Isolation Verified:** Adapters don't custody funds, read-only for HyperCore vaults.

---

## 9. EPOCH TIMELINE

```
Epoch 0             Epoch 1             Epoch 2
├───────────────────┼───────────────────┼───────────────────►
│                   │                   │
│ User deposits     │ Settlement        │ Withdrawal paid
│ → queued          │ → shares minted   │ → assets sent
│                   │                   │
│ User withdraws    │ Withdrawal queued │
│ → shares burned   │ → in FIFO queue   │
│ → queued          │                   │
│                   │                   │
│ Deployment        │ Deployment        │
│ → async, batched  │ → async, batched  │
│                   │                   │

Timeline:
  t=0           t=7days         t=14days
  │             │               │
  Epoch 0       Epoch 1         Epoch 2
  Current       Past (settable) Past (settable)
```

**Settlement Timing:**
- Can settle past epochs: `epochId < getCurrentEpoch()`
- Idempotent: `epochSettled[epochId]` prevents double settlement
- No forced ordering: Can settle epoch 5 before epoch 4

**Withdrawal Processing:**
- FIFO queue: `withdrawalQueue[withdrawalQueueHead...]`
- Liquidity-bounded: Processes as many as liquidity allows
- Carries forward: Unpaid withdrawals remain in queue

---

## 10. ISSUE SUMMARY FROM FLOWS

### **CRITICAL Issues**

1. **Adapter Failure Blocks Withdrawals** (Line 767-769)
   - `_withdrawFromERC4626()` reverts if ANY adapter fails
   - Violates invariant: "Withdrawals never blocked"
   - Impact: Single failing adapter = ALL withdrawals frozen

2. **totalAssets Accounting Error** (Line 595-597)
   - Pending deposits excluded from `totalAssets()`
   - Settlement uses incorrect base for share pricing
   - Impact: Incorrect share dilution/inflation

### **MEDIUM Issues**

3. **Deployment Adapter Failures** (Line 797-799)
   - Deposit to ERC4626 reverts on failure
   - Non-atomic deployment could be blocked

### **LOW Issues**

4. **Deployment Blocked by Pending Withdrawals** (Line 475)
   - ANY pending withdrawal blocks deployment
   - Could create temporary liveness issues

5. **Instant Withdrawal Not Implemented**
   - Spec mentions instant withdrawal with 1% fee
   - Not present in codebase

---

## 11. DATA FLOW: LAYERS & LIQUIDITY

```
                   ┌─────────────────────────────────┐
                   │  USER ACTIONS (External)        │
                   │  - Deposits (queued)            │
                   │  - Withdrawals (queued)         │
                   └────────────┬────────────────────┘
                                │
                   ┌────────────▼────────────────────┐
                   │  L1: AlphaVault CUSTODY        │
                   │  ┌────────────────────────────┐ │
                   │  │ USDC Balance               │ │
                   │  │ - Idle reserves            │ │
                   │  │ - Pending deposits         │ │
                   │  │ - Fee collection           │ │
                   │  └────────────────────────────┘ │
                   └─┬──────────┬────────────┬───────┘
                     │          │            │
        ┌────────────▼──┐  ┌────▼──────┐  ┌─▼──────────────┐
        │  L2: ERC4626  │  │ L3: Perps │  │ L4: HyperCore  │
        │  (Sync)       │  │ (Async)   │  │ Vaults (Async) │
        └───────────────┘  └───────────┘  └────────────────┘
             │                   │                │
        Withdrawable       Recall-able       Lockup-aware
        Immediately        (via sendAsset)   (cooldown)
```

**Liquidity Tiers:**
1. **L1 (Immediate):** `_availableL1()` = balance - pendingDeposits
2. **L2 (Sync):** `_erc4626Withdrawable()` via Felix
3. **L3 (Async):** Perps balance (via `sendAsset` to spot)
4. **L4 (Locked):** HyperCore vaults (cooldown applies)

**Withdrawable Liquidity = L1 + L2** (for user withdrawals)

---

## CONCLUSION

This architecture successfully decouples user-facing operations from HyperCore lockups. However, several critical issues in error handling and accounting need to be addressed before production deployment.

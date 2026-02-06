# Security & Architecture Review Report
## Alphavaults - HyperCore Integration on HyperEVM

**Review Date:** January 20, 2026  

---

## EXECUTIVE SUMMARY

This report presents a comprehensive manual review of the Alphavaults smart contracts implementing non-atomic batching and HyperCore vault integration. The review focused on architectural correctness, safety invariants, and security vulnerabilities.

### Overall Assessment

**Architecture Alignment:** ✅ **CONFIRMED**  
The implementation successfully matches the approved liquidity-abstracted design with HyperCore vault lockups fully isolated from user-facing operations.

**Security Status:** ⚠️ **ISSUES IDENTIFIED**  
- 2 **CRITICAL** severity issues  
- 1 **MEDIUM** severity issue  
- 2 **LOW** severity issues  

**Recommendation:** **DO NOT DEPLOY** to production until CRITICAL issues are resolved.

---

## 1. ARCHITECTURAL INTEGRITY

### ✅ Design Verification

The implementation correctly implements the approved architecture:

1. **Single Custodian:** AlphaVault is the only contract holding user funds
2. **Adapter Isolation:** All adapters (Felix, HyperCore) are stateless executors with no fund custody
3. **User-Facing Decoupling:** No user functions (`deposit`, `withdraw`, `redeem`, `mint`) call HyperCore
4. **Async Deployment:** HyperCore interactions are async and best-effort only via `deployBatch()`

**Contracts Reviewed:**
- `AlphaVault.sol` - Main vault (970 lines)
- `FelixAdapter.sol` - ERC4626 adapter (262 lines)
- `HyperCoreVaultAdapter.sol` - Read-only vault adapter (130 lines)
- `BaseVaultAdapter.sol` - Base adapter implementation (223 lines)

### ✅ Custody Model

**Verified:**
- ✅ All USDC held by AlphaVault
- ✅ All receipt tokens (Felix shares) held by AlphaVault
- ✅ Adapters have zero balance after operations
- ✅ HyperCore positions tracked via precompiles (no token custody)

---

## 2. CRITICAL FINDINGS

### 🔴 CRITICAL-1: Adapter Failure Blocks All Withdrawals

**Location:** `AlphaVault.sol:767-769`

**Issue:**
```solidity
try adapter.withdraw(toWithdraw) returns (uint256 actual) {
    if (actual == 0) revert AdapterOperationFailed(strategy.adapter);
    // ... handle success
} catch {
    revert AdapterOperationFailed(strategy.adapter);  // ❌ REVERTS!
}
```

**Impact:**
- If ANY ERC4626 adapter fails (even temporarily), `_withdrawFromERC4626()` reverts
- This blocks `_processWithdrawals()` entirely
- Users cannot withdraw even if sufficient L1 liquidity exists
- **Violates core invariant:** "Withdrawals never depend on strategy failures"

**Attack Vector:**
- Malicious or buggy adapter can freeze all withdrawals
- Protocol dependency failure (e.g., Felix paused) blocks system

**Recommendation:**
```solidity
try adapter.withdraw(toWithdraw) returns (uint256 actual) {
    if (actual > 0) {
        remaining = actual >= remaining ? 0 : remaining - actual;
    }
    // Continue to next adapter on failure
} catch {
    // Log failure, continue to next adapter
    emit AdapterWithdrawFailed(strategy.adapter);
}
```

**Severity:** CRITICAL  
**Priority:** P0 - Must fix before deployment

---

### 🔴 CRITICAL-2: Incorrect Share Pricing Due to Accounting Error

**Location:** `AlphaVault.sol:595-597` and settlement logic at `345-381`

**Issue:**
The `totalAssets()` function excludes pending deposits:
```solidity
function _availableL1() internal view returns (uint256) {
    uint256 idle = IERC20(asset()).balanceOf(address(this));
    return idle > totalPendingDeposits ? idle - totalPendingDeposits : 0;
    // ❌ Pending deposits removed from totalAssets!
}

function totalAssets() public view returns (uint256) {
    uint256 total = _availableL1();  // ← Excludes pending deposits
    total += _erc4626TVL();
    total = _applySignedBalance(total, _perpsBalance());
    total += _vaultTVL();
    return _applyPendingWithdrawals(total);
}
```

During epoch settlement:
```solidity
uint256 assetsBefore = totalAssets();  // ← Excludes pending deposits!
uint256 assetsNum = assetsBefore + 1;
uint256 userShares = Math.mulDiv(entryAssets, sharesDenom, assetsNum);
```

**Impact:**
1. **Share Price Manipulation:** Pending deposits are not counted in `totalAssets()`, but they ARE in the vault balance
2. **Incorrect Valuation:** Settlement uses wrong base for share pricing
3. **User Loss:** Depositors receive incorrect number of shares (dilution or inflation depending on state)

**Example Scenario:**
```
Vault State:
- Deployed: 1,000,000 USDC
- L1 Balance: 100,000 USDC (all pending deposits)
- Pending Deposits: 100,000 USDC
- Total Supply: 1,000,000 shares

totalAssets() = 0 (L1) + 1,000,000 (deployed) = 1,000,000  ← WRONG!
Actual assets = 1,100,000 USDC

Settlement for 10,000 USDC deposit:
Current: userShares = 10,000 * 1,000,000 / 1,000,001 ≈ 9,999.99 shares
Correct: userShares = 10,000 * 1,000,000 / 1,100,001 ≈ 9,090.91 shares

Result: User gets ~10% MORE shares than deserved!
```

**Recommendation:**
Change `totalAssets()` to include pending deposits:
```solidity
function totalAssets() public view returns (uint256) {
    uint256 total = IERC20(asset()).balanceOf(address(this));  // Include all L1
    total += _erc4626TVL();
    total = _applySignedBalance(total, _perpsBalance());
    total += _vaultTVL();
    return _applyPendingWithdrawals(total);
}
```

**Severity:** CRITICAL  
**Priority:** P0 - Must fix before deployment

---

## 3. MEDIUM FINDINGS

### 🟠 MEDIUM-1: Deployment Reverts on Adapter Failure

**Location:** `AlphaVault.sol:797-799`

**Issue:**
```solidity
function _depositToERC4626(address adapter, uint256 amount) internal {
    if (amount == 0) return;
    IERC20(asset()).safeTransfer(adapter, amount);
    try IVaultAdapter(adapter).deposit(amount) {} catch {
        revert AdapterOperationFailed(adapter);  // ❌ REVERTS!
    }
}
```

**Impact:**
- Deployment is supposed to be non-atomic and best-effort
- Any adapter failure causes entire `deployBatch()` to revert
- Breaks async deployment design philosophy
- Temporarily paused adapter blocks all deployments

**Recommendation:**
```solidity
try IVaultAdapter(adapter).deposit(amount) {
    // Success
} catch {
    // Transfer back to vault on failure
    uint256 balance = IERC20(asset()).balanceOf(adapter);
    if (balance > 0) {
        // Request adapter to return funds (add to IVaultAdapter)
        try IVaultAdapter(adapter).emergencyReturn() {} catch {}
    }
    emit AdapterDepositFailed(adapter, amount);
}
```

**Severity:** MEDIUM  
**Priority:** P1 - Should fix before deployment

---

## 4. LOW FINDINGS

### 🟡 LOW-1: Deployment Blocked by Pending Withdrawals

**Location:** `AlphaVault.sol:475`

**Issue:**
```solidity
if (deploymentPaused || _hasPendingWithdrawals()) {
    return 0;  // ❌ Blocks deployment
}
```

**Impact:**
- ANY pending withdrawal blocks deployment entirely
- Could create temporary liveness issues
- Reserve enforcement runs first, but timing could be problematic

**Edge Case:**
1. User requests withdrawal
2. Withdrawal queued
3. `deployBatch()` called → returns 0 (no deployment)
4. Funds remain idle when they could be productively deployed

**Recommendation:**
Remove or relax this check. The reserve enforcement (`_enforceReserve()`) should handle liquidity needs:
```solidity
// Remove the _hasPendingWithdrawals() check
if (deploymentPaused) {
    return 0;
}
```

**Severity:** LOW  
**Priority:** P2 - Review and consider for next iteration

---

### 🟡 LOW-2: Instant Withdrawal Not Implemented

**Location:** N/A (missing from codebase)

**Issue:**
The specification mentions:
> "Instant withdrawals: gated by BUFFER adapter, apply a 1% fee correctly, retain fees inside the vault"

However, no instant withdrawal mechanism exists in the codebase.

**Impact:**
- Feature gap between spec and implementation
- Users cannot bypass queue for urgent withdrawals
- Reduced UX compared to spec

**Recommendation:**
Either:
1. Implement instant withdrawal feature as specified, OR
2. Update spec to reflect queued-only withdrawals

**Severity:** LOW  
**Priority:** P3 - Clarify requirements

---

## 5. INVARIANT VERIFICATION

Manual verification of critical system invariants:

| Invariant | Status | Notes |
|-----------|--------|-------|
| Withdrawals never depend on HyperCore | ✅ PASS | `_getWithdrawableLiquidity()` only uses L1 + ERC4626 |
| totalAssets = vault balance + adapter TVL | ❌ FAIL | Pending deposits excluded (CRITICAL-2) |
| Shares represent ownership, not deployment state | ✅ PASS | Shares burned at withdrawal request |
| Strategy loss affects share price, not liquidity logic | ✅ PASS | Losses reduce totalAssets → share price |
| Continuous deposits do not prevent withdrawals | ✅ PASS | FIFO queue, liquidity-bounded |
| Cowriter failures do not affect correctness | ⚠️ PARTIAL | Deployment is best-effort, but adapter failures block withdrawals (CRITICAL-1) |

---

## 6. SECURITY CHECKLIST

### ✅ Passed Security Checks

1. **Reentrancy Protection:** All state-changing functions have `nonReentrant` modifier
2. **Access Controls:** Proper use of `onlyOwner`, `onlyDeploymentOperator`, `onlyVault`
3. **Safe Token Transfers:** Consistent use of SafeERC20 throughout
4. **Approval Management:** `safeIncreaseAllowance` used correctly
5. **Integer Overflow:** Solidity 0.8.28 built-in protection
6. **Zero Address Checks:** Validated in all constructors and setters
7. **Front-Running:** Epoch-based design mitigates front-running
8. **Flash Loan Attacks:** Not applicable (queued operations)

### ⚠️ Security Concerns

1. **External Call Safety:** Adapter failures can block system (CRITICAL-1, MEDIUM-1)
2. **Accounting Errors:** Share pricing vulnerable to incorrect totalAssets (CRITICAL-2)
3. **Trust Assumptions:** System depends on honest adapters

---

## 7. DEPOSIT LIFECYCLE VERIFICATION

### ✅ Correct Behavior

1. **Funds Transfer:** ✅ `safeTransferFrom(user, vault, assets)` - correct
2. **Epoch Recording:** ✅ `_epochDeposits[epoch].push(...)` - correct
3. **No HyperCore Calls:** ✅ Verified - no HyperCore in deposit path
4. **Shares Minted in Settlement:** ✅ Only in `settleEpoch()` - correct
5. **No Cooldown Impact:** ✅ Deposits don't trigger HyperCore operations

### ⚠️ Settlement Issues

- Share pricing incorrect due to CRITICAL-2
- Settlement math otherwise correct (ERC4626Upgradeable pattern with virtualShares offset)

---

## 8. WITHDRAWAL LIFECYCLE VERIFICATION

### ✅ Correct Behavior

1. **Queued Withdrawals:** ✅ FIFO queue implementation correct
2. **Shares Burned Immediately:** ✅ `_burn(owner, shares)` at request time
3. **No HyperCore Calls:** ✅ Verified - only L1 + ERC4626
4. **Liquidity-Bounded:** ✅ `if (availableLiquidity < request.assets) break`
5. **Fee Handling:** ✅ Withdrawal fee correctly calculated and collected
6. **Pro-Rata Settlement:** N/A - Full-only withdrawals (not pro-rata)

### ❌ Critical Issues

- Adapter failures block withdrawal processing (CRITICAL-1)

---

## 9. DEPLOYMENT & RECALL VERIFICATION

### ✅ Correct Behavior

1. **Batching:** ✅ `deploymentInterval` and `maxDeploymentAmount` controls
2. **Cooldown-Aware:** ✅ `maxWithdraw()` returns 0 if HyperCore vault locked
3. **Reserve Enforcement:** ✅ Automatic pause and recall below floor
4. **Partial Recall:** ✅ Handles partial withdrawals gracefully
5. **Failure Isolation:** ✅ HyperCore failures don't affect correctness (best-effort)

### ⚠️ Issues

- Deployment blocked by pending withdrawals (LOW-1)
- Adapter deposit failures block deployment (MEDIUM-1)

---

## 10. ADAPTER REVIEW

### FelixAdapter (ERC4626)

**✅ Correct:**
- Stateless executor pattern implemented correctly
- Deposit sends shares directly to vault: `felixVault.deposit(amount, _vault)`
- Withdraw returns excess shares to vault
- TVL reads vault's share balance
- Zero balance after operations

**No issues found.**

### HyperCoreVaultAdapter

**✅ Correct:**
- Read-only implementation (deposit/withdraw revert)
- Correct precompile usage: `getUserVaultEquity(vault, hypercoreVault)`
- Cooldown handling via `maxWithdraw()` checking `lockedUntil`
- No custody of funds

**No issues found.**

### BaseVaultAdapter

**✅ Correct:**
- Proper access control with `onlyVault` modifier
- Emergency functions for token recovery
- Pausable functionality

**No issues found.**

---

## 11. EDGE CASES TESTED

| Edge Case | Result | Notes |
|-----------|--------|-------|
| First deposit (zero TVL) | ⚠️ VULNERABLE | CRITICAL-2 affects pricing |
| Zero TVL during settlement | ⚠️ VULNERABLE | CRITICAL-2 affects pricing |
| Partial withdrawals | ✅ SAFE | FIFO queue carries forward |
| Back-to-back settlements | ✅ SAFE | Idempotent via `epochSettled[epochId]` |
| Negative perps balance | ✅ SAFE | `_applySignedBalance()` handles correctly |
| Adapter paused | ❌ FAILS | CRITICAL-1 blocks withdrawals |
| HyperCore vault locked | ✅ SAFE | `maxWithdraw()` returns 0 |
| Multiple pending epochs | ✅ SAFE | Independent settlement per epoch |

---

## 12. GAS OPTIMIZATION NOTES (Out of Scope)

The following are noted for future optimization (not security issues):

1. **Storage Reads:** Multiple reads of `_strategies` in loops
2. **Loop Efficiency:** Could cache `_strategies.length`
3. **Array Iteration:** `_withdrawalQueue` never shrinks (could use circular buffer)

---

## 13. RECOMMENDATIONS SUMMARY

### Immediate Action Required (P0)

1. **Fix CRITICAL-1:** Make adapter withdrawals non-reverting
   - Use try-catch without revert
   - Continue to next adapter on failure
   - Emit events for monitoring

2. **Fix CRITICAL-2:** Correct totalAssets calculation
   - Include pending deposits in totalAssets
   - Verify settlement math after fix
   - Add tests for edge cases

### Before Production (P1)

3. **Fix MEDIUM-1:** Make deployment adapter-failure tolerant
   - Non-reverting on adapter deposit failures
   - Return funds to vault on failure
   - Emit events for monitoring

### Future Iterations (P2-P3)

4. **Review LOW-1:** Consider removing pending withdrawal check
5. **Clarify LOW-2:** Decide on instant withdrawal feature

---

## 14. TEST COVERAGE RECOMMENDATIONS

Based on this review, the following test scenarios should be added:

1. **Adapter Failure Scenarios:**
   - Withdrawal with one failing adapter
   - Withdrawal with all adapters failing
   - Deployment with failing adapter

2. **Accounting Edge Cases:**
   - Settlement with large pending deposits
   - First deposit with zero TVL
   - Settlement with negative perps balance

3. **Invariant Tests:**
   - totalAssets formula verification
   - Share price consistency checks
   - Withdrawal independence from HyperCore

---

## 15. ARCHITECTURAL DEVIATIONS

No architectural deviations from the approved spec were found, with one exception:

**Missing Feature:** Instant withdrawal mechanism (as noted in LOW-2)

All other aspects match the approved liquidity-abstracted design.

---

## 16. CONCLUSION

The Alphavaults implementation successfully achieves the core architectural goal of decoupling user operations from HyperCore lockups. The adapter pattern is well-designed, and the epoch-based settlement provides a clean separation of concerns.

However, **two critical security issues must be resolved before production deployment:**

1. Adapter failures blocking withdrawals violates a core safety invariant
2. Incorrect share pricing due to accounting errors could lead to user losses

Once these issues are addressed, the system should be safe for production use, pending thorough testing of the recommended scenarios.

---

## APPENDIX A: FILES REVIEWED

**Primary Contracts:**
- `./contracts/AlphaVault.sol` (970 lines)
- `./contracts/adapters/BaseVaultAdapter.sol` (223 lines)
- `./contracts/adapters/FelixAdapter.sol` (262 lines)
- `./contracts/adapters/HyperCoreVaultAdapter.sol` (130 lines)

**Libraries:**
- `./contracts/libraries/StrategyLib.sol` (163 lines)
- `./contracts/libraries/HyperCoreReadPrecompile.sol` (155 lines)
- `./contracts/libraries/HyperCoreWritePrecompile.sol` (137 lines)

**Interfaces:**
- `./contracts/interfaces/IAlphaVault.sol`
- `./contracts/interfaces/IVaultAdapter.sol`
- `./contracts/interfaces/ICoreDepositor.sol`

**Types:**
- `./contracts/types/VaultTypes.sol`

---

## APPENDIX B: REVIEW METHODOLOGY

This review employed the following techniques:

1. **Manual Code Analysis:** Line-by-line review of all smart contracts
2. **Control Flow Tracing:** Manual tracing of all user-facing functions
3. **Invariant Verification:** Systematic checking of specified invariants
4. **Edge Case Exploration:** Scenario analysis for boundary conditions
5. **Architectural Comparison:** Verification against approved design spec
6. **Security Checklist:** Standard smart contract security audit checklist

**Tools Used:**
- Manual code review
- Static analysis (grep, pattern matching)
- Flow diagram creation

---

**Report Generated:** January 20, 2026  
**Review Duration:** Comprehensive manual review  
**Status:** ⚠️ CRITICAL ISSUES IDENTIFIED - DO NOT DEPLOY

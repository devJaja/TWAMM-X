# TWAMM-X

> Next-generation privacy-preserving TWAMM hook for Uniswap v4.  
> Executes large orders invisibly, eliminates MEV leakage, and protects LPs through zero-knowledge batch execution with smoothed yield distribution.

---

## Prize Tracks

### 🏆 UHI9 Hookathon — Impermanent Loss & Yield Systems

**Track: Fee-Smoothing Hooks**
> *Hooks that automatically reinvest or distribute yield over time, smoothing fee flow for LPs.*

TWAMM-X implements a **24-hour linear yield smoothing system** for LP rebates. Instead of distributing fees as unpredictable lump sums, every rebate epoch releases yield continuously — LPs receive predictable, sustainable income from TWAMM order flow.

- `distributeLPRebate()` — commits accrued rebate into a 24h smoothing epoch
- `releaseYield()` — donates the currently vested portion to in-range LPs (auto-triggered by Reactive Network)
- `vestedYield()` — view function returning releasable amount at any point in time
- Undistributed balance rolls forward into the next epoch — no yield is ever lost

### 🏆 Sponsor Tracks

| Sponsor | Integration |
|---|---|
| **Fhenix CoFHE** | `FHE.add()`, `FHE.sub()`, `FHE.decrypt()`, `euint128`, `ebool` — encrypted order amounts and directions stored on-chain |
| **Reactive Network** | `TWAMMXReactive` auto-triggers LP rebate distribution on every `BatchExecuted` event — no keeper required |
| **Uniswap v4** | Full `beforeSwap` / `afterSwap` hook with ZK commit-reveal, TWAMM batch math, and settlement |

---

## Overview

TWAMM-X combines four technologies into a single Uniswap v4 hook:

- **ZK commit-reveal** — order details are never visible on-chain until after execution
- **FHE encrypted state** — order amounts and directions stored as on-chain ciphertexts via Fhenix CoFHE
- **Continuous TWAMM math** — closed-form batch execution based on the Paradigm TWAMM paper
- **Reactive automation** — LP rebates are distributed automatically via Reactive Network, no keeper required

---

## Architecture

```
src/
├── TWAMMXHook.sol              # Core hook — beforeSwap / afterSwap / fee-smoothing
├── TWAMMSettlement.sol         # Plaintext token custodian and swap executor
├── TWAMMXSettlementFHE.sol     # FHE-enhanced settlement — encrypted amounts/directions
├── TWAMMXReactive.sol          # Reactive Network contract — auto LP rebate distribution
├── interfaces/
│   ├── ITWAMMXHook.sol         # Full public interface
│   └── IZKVerifier.sol         # Groth16 verifier interface (snarkjs-compatible)
└── libraries/
    ├── TWAMMBatchMath.sol       # Closed-form TWAMM price formula with exp() Taylor series
    ├── Groth16Verifier.sol      # Real snarkjs-generated Groth16 verifier
    └── MockGroth16Verifier.sol  # Test-only mock verifier

circuits/
├── order_commit.circom         # Circom circuit — proves order preimage without revealing it
├── order_commit_final.zkey     # Groth16 proving key
├── verification_key.json       # Verification key
└── gen_proof.js                # Proof generation script

test/
└── TWAMMXHook.t.sol            # 27 Foundry tests — all passing

script/
└── Deploy.s.sol                # Deployment script
```

---

## Order Lifecycle

```
1. commitOrder()     Trader submits hash(owner, amount, direction, salt) — no order details on-chain
                     + depositFHE() encrypts amount + direction via Fhenix CoFHE before storing

2. revealOrder()     After expiry, trader submits ZK proof + plaintext order
                     Hook verifies: Groth16 proof + hash match
                     TWAMMXSettlementFHE requests async FHE decryption of encrypted amount
                     Swap executes once CoFHE threshold network delivers plaintext
                     Output credited as encrypted euint128 — only trader can decrypt

3. afterSwap         On every swap, accumulated virtual orders run through
                     closed-form TWAMM batch math
                     LP shield rebate accrues (5 bps of virtual volume)

4. Auto-distribution TWAMMXReactive (on Reactive Network) watches BatchExecuted events
                     Automatically calls hook.reactiveDistributeRebate()
                     Starts a 24h smoothing epoch — yield released linearly to in-range LPs

5. releaseYield()    Anyone (or Reactive Network) calls releaseYield() to donate
                     the currently vested portion — predictable, continuous LP income

6. claim()           Trader calls requestClaimDecryption(), waits for CoFHE,
                     then calls claim() to withdraw output tokens
```

---

## Fee-Smoothing Yield System

The LP rebate system implements **YieldBasis-style predictable returns** for liquidity providers:

```
Rebate accrues from TWAMM virtual order flow (5 bps per batch)
         ↓
distributeLPRebate() → commits total to a 24h linear vesting epoch
         ↓
releaseYield() → donates: total × elapsed / 24h  (minus already donated)
         ↓
LPs receive continuous yield — not unpredictable lump sums
```

| Time elapsed | % of epoch yield released |
|---|---|
| 6 hours | 25% |
| 12 hours | 50% |
| 18 hours | 75% |
| 24 hours | 100% |

Undistributed balance from a previous epoch rolls into the next — no yield is ever lost.

---

## ZK Circuit

The `order_commit.circom` circuit proves:

- `commitmentHash == Poseidon(owner, amountIn, zeroForOne, salt)`
- `amountIn > 0`
- `zeroForOne ∈ {0, 1}`
- `expiry > 0`

Private inputs (never on-chain): `owner`, `amountIn`, `zeroForOne`, `salt`  
Public inputs (on-chain): `commitmentHash`, `poolIdHash`, `expiry`

The `poolIdHash` binds the proof to a specific pool, preventing cross-pool replay attacks.

---

## TWAMM Math

Implements the exact closed-form solution from the [Paradigm TWAMM paper](https://www.paradigm.xyz/2021/07/twamm):

```
sqrtP_end = (a·sqrtP_0 + b·c·e) / (a + b·e)

where:
  a = sqrtP_0 + c
  b = sqrtP_0 - c
  c = sqrt(k0 / k1)          equilibrium price ratio
  e = exp(2·sqrt(k0·k1)·Δt / L)   exponential decay factor
```

`exp()` is computed via a 6-term Taylor series with range reduction, accurate to <0.01% for all practical TWAMM intervals.

---

## Fhenix FHE Integration

### What FHE adds

TWAMM-X uses [Fhenix CoFHE](https://cofhe-docs.fhenix.zone) to encrypt order state directly on-chain. While the ZK layer proves *validity* of a hidden order, FHE ensures the *values themselves* — amount and direction — remain encrypted even after they are stored in contract state.

### How it works

`TWAMMXSettlementFHE` replaces plaintext deposit storage with FHE ciphertext handles:

```
// Plaintext (TWAMMSettlement)
mapping(bytes32 => uint128) depositAmount;

// FHE-encrypted (TWAMMXSettlementFHE)
mapping(bytes32 => euint128) encryptedAmount;
mapping(bytes32 => ebool)    encryptedDirection;
```

The trader encrypts their order client-side using [cofhejs](https://cofhe-docs.fhenix.zone/cofhejs/introduction/overview) before sending to the contract. The contract stores only the ciphertext handle — the plaintext never appears on-chain.

At execution time, `FHE.decrypt()` requests async decryption from the CoFHE threshold network. Once ready, `FHE.getDecryptResultSafe()` retrieves the plaintext amount for the actual PoolManager swap. Output is re-encrypted as `euint128` and stored — only the trader can decrypt their own balance using their wallet key via cofhejs.

### Privacy benefits

| Without FHE | With FHE |
|---|---|
| Order amount visible in contract storage | Amount stored as `euint128` ciphertext — unreadable on-chain |
| Swap direction visible after reveal | Direction stored as `ebool` — never exposed |
| Output balance readable by anyone | Claimable balance encrypted — only owner can decrypt |
| Aggregate virtual sell pressure visible | Accumulated via `FHE.add()` without revealing individual orders |

### Access control

- `FHE.allowThis()` — contract retains access to ciphertext for future operations
- `FHE.allow(handle, owner)` — only the trader can decrypt their output balance
- No `allowGlobal()` — no ciphertext is ever made publicly readable

### Deployment

`TWAMMXSettlementFHE` deploys on Fhenix-supported networks:
- Ethereum Sepolia
- Arbitrum Sepolia
- Base Sepolia

The plaintext `TWAMMSettlement` remains available for networks without CoFHE support.

---

## Reactive Network Integration

`TWAMMXReactive` deploys on Reactive Network and subscribes to `BatchExecuted` events from the hook on the origin chain. On every batch, it automatically triggers `reactiveDistributeRebate(poolId)` — eliminating the need for any off-chain keeper.

```
BatchExecuted (Ethereum) → TWAMMXReactive.react() (Reactive Network)
                         → Callback → hook.reactiveDistributeRebate() (Ethereum)
                         → 24h smoothing epoch starts
                         → releaseYield() called periodically → LP yield distributed
```

---

## Setup

```shell
forge build
forge test
```

---

## Deploy

```shell
# 1. Origin chain — plaintext settlement (Ethereum mainnet / any EVM)
export POOL_MANAGER=<v4_pool_manager_address>
forge script script/Deploy.s.sol --rpc-url <RPC> --private-key <PK> --broadcast

# 2. FHE settlement (Sepolia / Arbitrum Sepolia / Base Sepolia)
forge create src/TWAMMXSettlementFHE.sol:TWAMMXSettlementFHE \
  --rpc-url <SEPOLIA_RPC> \
  --private-key <PK> \
  --constructor-args $POOL_MANAGER $HOOK_ADDR

# 3. Reactive Network (auto LP rebate distribution)
forge create src/TWAMMXReactive.sol:TWAMMXReactive \
  --rpc-url $REACTIVE_RPC_URL \
  --private-key $REACTIVE_PRIVATE_KEY \
  --value 0.01ether \
  --constructor-args $ORIGIN_CHAIN_ID $HOOK_ADDR $ORIGIN_CHAIN_ID $CALLBACK_PROXY
```

> Hook deployment address must encode `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG` (bits 7 & 6).  
> Use a `HookMiner` or `CREATE2` factory to mine a compliant address before deploying to mainnet.

---

## Generate ZK Proof (off-chain)

```shell
cd circuits
npm install
node gen_proof.js   # outputs proof.json, public.json, test_proof.json
```

---

## Test Results

```
Ran 27 tests — 27 passed, 0 failed

test_cancelOrder                            ✓
test_cancelOrder_nonOwner                   ✓
test_commitOrder                            ✓
test_commitOrder_invalidDelay               ✓
test_commitOrder_zeroHash                   ✓
test_distributeLPRebate                     ✓
test_distributeLPRebate_nothingToDistribute ✓
test_hookAddressFlags                       ✓
test_immutables                             ✓
test_lpRebateAccruesFromSwap                ✓
test_multipleReveals_accumulatePending      ✓
test_onlyPoolManager_afterSwap              ✓
test_onlyPoolManager_beforeSwap             ✓
test_plainSwap                              ✓
test_releaseYield_partialRelease            ✓
test_revealOrder                            ✓
test_revealOrder_beforeExpiry               ✓
test_revealOrder_doubleReveal               ✓
test_revealOrder_hashMismatch               ✓
test_settlement_fullFlow                    ✓
test_settlement_onlyHook                    ✓
test_settlement_refund                      ✓
test_twammBatchExecutes                     ✓
test_twammBatchMath_noOrders                ✓
test_twammBatchMath_sell0MovesPrice         ✓
test_twammBatchMath_sell1MovesPrice         ✓
test_yieldSmoothing_linearRelease           ✓
```

---

## Dependencies

- [Uniswap v4-core](https://github.com/Uniswap/v4-core)
- [Uniswap v4-periphery](https://github.com/Uniswap/v4-periphery)
- [Fhenix CoFHE contracts](https://github.com/FhenixProtocol/cofhe-contracts)
- [Reactive Library](https://github.com/Reactive-Network/reactive-lib)
- [Circom 2](https://github.com/iden3/circom) + [snarkjs](https://github.com/iden3/snarkjs)
- [circomlib](https://github.com/iden3/circomlib) (Poseidon hash)
- [forge-std](https://github.com/foundry-rs/forge-std)

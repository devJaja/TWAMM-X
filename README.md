# TWAMM-X

> Next-generation privacy-preserving TWAMM hook for Uniswap v4.  
> Executes large orders invisibly, eliminates MEV leakage, and protects LPs through zero-knowledge batch execution.

## Architecture

```
src/
├── TWAMMXHook.sol          # Core hook (IHooks) — beforeSwap / afterSwap
├── interfaces/             # Project-specific interfaces
└── libraries/              # Shared libraries (ZK verifier, batch math, etc.)

test/
└── TWAMMXHook.t.sol        # Foundry tests

script/
└── Deploy.s.sol            # Deployment script
```

### Hook Flags

The hook requires `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG` encoded in the deployment address (bits 7 & 6).  
Use a `HookMiner` or `CREATE2` factory to mine a compliant address before deploying to mainnet.

## Roadmap

- [ ] ZK batch order queue (`beforeSwap`)
- [ ] ZK proof verifier integration
- [ ] LP shield / rebate logic (`afterSwap`)
- [ ] TWAMM virtual order execution engine
- [ ] MEV-resistant order commitment scheme

## Setup

```shell
forge build
forge test
```

## Deploy

```shell
export POOL_MANAGER=<v4_pool_manager_address>
forge script script/Deploy.s.sol --rpc-url <RPC> --private-key <PK> --broadcast
```

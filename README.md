# Alpha Vaults

Alpha Vaults is a production-grade ERC-4626 index vault on Hyperliquid (HyperEVM + HyperCore) that batches deposits and withdrawals across HyperEVM ERC4626 protocols and HyperCore perps/vaults with a fixed composition registry.

## 🏗️ Architecture

### Strategy Registry (Fixed Composition)

Each `AlphaVault` maintains an on-chain registry of strategy targets (basis points) across layers:

| Strategy Type | Layer | TVL Source | Execution Path |
|--------------|-------|------------|----------------|
| **ERC4626** | HyperEVM | ERC4626 share value | Adapter deposit/withdraw |
| **PERPS** | HyperCore | `accountMarginSummary.rawUsd` | CoreDepositor + Cowriter `SendAsset` |
| **VAULT** | HyperCore | `userVaultEquity` | Cowriter `VaultTransfer` |

Deposits and withdrawals are queued. `settleEpoch()` only mints shares and processes withdrawals from HyperEVM liquidity; it never triggers HyperCore writes. Strategy deployment is handled separately via `deployBatch()` on a fixed cadence (keeper/Cowriter), with batches paused when withdrawals are pending.

### Adapter System

Adapters are stateless executors (vault holds the receipt tokens):

```
AlphaVault (ERC-4626)
    ├── ERC4626 Adapters (Felix, etc.)
    └── HyperCoreVaultAdapter (read-only equity + lockup)
```

HyperCore deposits/withdrawals are executed directly by the vault via CoreDepositor and Cowriter actions.

### Fees

- Deposit fee and withdrawal fee are configurable (1% default each).
- Fees are routed to the treasury on collection.

## 📦 Quick Start

### Prerequisites

- Node.js 18+
- pnpm (or npm/yarn)
- Foundry (for Solidity tests)

### Install Dependencies

```bash
pnpm install
forge install
```

### Compile Contracts

```bash
# Hardhat
pnpm compile

# Foundry
forge build
```

### Run Tests

```bash
# Foundry tests (recommended)
forge test -vvv

# Hardhat tests
pnpm test
```

## 🚀 Deployment

### Environment Setup

Create a `.env` file:

```env
# Private keys
PRIVATE_KEY=your_testnet_private_key
MAINNET_PRIVATE_KEY=your_mainnet_private_key

# Etherscan API key (for verification)
ETHERSCAN_API_KEY=your_api_key
```

### Deploy AlphaVault

```bash
# Testnet
CORE_DEPOSITOR=0x... npx hardhat run scripts/vault/deployment/deployVault.ts --network hyperEvmTestnet

# Mainnet
CORE_DEPOSITOR=0x... npx hardhat run scripts/vault/deployment/deployVault.ts --network hyperEvmMainnet
```

### Deploy Adapters

```bash
# Deploy Felix Adapter
npx hardhat run scripts/adapter/deployment/deployFelixAdapter.ts --network hyperEvmMainnet

# Deploy HyperCore Adapter (for HLP)
npx hardhat run scripts/adapter/deployment/deployHyperCoreAdapter.ts --network hyperEvmMainnet
```

### Configure Strategy

```bash
# Provide a JSON config with strategy targets
STRATEGY_CONFIG='[
  {"adapter":"0x...","targetBps":5000,"strategyType":0,"active":true},
  {"adapter":"0x...","targetBps":5000,"strategyType":2,"active":true}
]' npx hardhat run scripts/vault/deployment/configureStrategy.ts --network hyperEvmMainnet
```

### Upgrade Contracts

```bash
# Upgrade vault implementation
npx hardhat run scripts/vault/deployment/upgradeVault.ts --network hyperEvmMainnet

# Upgrade adapter implementation
npx hardhat run scripts/adapter/deployment/upgradeAdapter.ts --network hyperEvmMainnet
```

## 📁 Project Structure

```
alphavaults/
├── contracts/
│   ├── AlphaVault.sol            # Main ERC-4626 vault-of-vaults
│   ├── adapters/
│   │   ├── BaseVaultAdapter.sol  # Abstract base for all adapters
│   │   ├── FelixAdapter.sol      # Felix ERC-4626 vault adapter
│   │   └── HyperCoreVaultAdapter.sol # HyperCore vault adapter
│   ├── interfaces/
│   │   ├── IAlphaVault.sol       # Vault interface
│   │   ├── IVaultAdapter.sol     # Adapter interface
│   │   └── ICoreDepositor.sol    # Circle CoreDepositor interface
│   ├── libraries/
│   │   ├── StrategyLib.sol       # Strategy registry helpers
│   │   ├── HyperCoreReadPrecompile.sol # L1 read wrappers
│   │   └── HyperCoreWritePrecompile.sol # Cowriter action wrappers
│   └── types/
│       └── VaultTypes.sol        # Shared types and constants
├── scripts/
│   ├── vault/
│   │   └── deployment/           # Vault deployment scripts
│   └── adapter/
│       └── deployment/           # Adapter deployment scripts
├── test/
│   ├── foundry/
│   │   ├── unit/                 # Unit tests
│   │   ├── integration/          # Integration tests
│   │   └── mocks/                # Mock contracts
│   └── HyperCoreVaultAdapter.test.ts  # TypeScript adapter tests
├── hardhat.config.ts
└── foundry.toml
```

## 🔧 Configuration

### Network Configuration

| Network | Chain ID | RPC URL | Explorer |
|---------|----------|---------|----------|
| HyperEVM Testnet | 998 | https://rpc.hyperliquid-testnet.xyz/evm | https://testnet.purrsec.com |
| HyperEVM Mainnet | 999 | https://rpc.hyperliquid.xyz/evm | https://hyperevmscan.io |

### Protocol Addresses (Mainnet)

| Protocol | Address |
|----------|---------|
| USDC | `0xb88339CB7199b77E23DB6E890353E22632Ba630f` |
| Felix Vault | `0x8A862fD6c12f9ad34C9c2ff45AB2b6712e8CEa27` |
| HLP Vault | `0xdfc24b077bc1425AD1DEA75bCB6f8158E10Df303` |

## 📊 Key Features

### ERC-4626 Compatibility (Queued)
- Standard `deposit()`, `withdraw()`, `mint()`, `redeem()` functions queue into epochs
- `settleEpoch()` mints shares and processes withdrawals from HyperEVM liquidity only
- `deployBatch()` performs non-atomic strategy deployment on a fixed cadence
- `totalAssets()` aggregates L1 idle, ERC4626 TVL, perps balance, and vault equity (less pending withdrawals)

### Strategy Routing
- Fixed registry targets across ERC4626, PERPS, and VAULT strategies
- HyperEVM deposits allocate via adapters; perps via CoreDepositor
- HyperCore vault moves use Cowriter `VaultTransfer`
- Batch size and cadence are configurable via `setDeploymentConfig()`

### Donation Attack Protection
- Pending deposits are excluded from `totalAssets()`
- Pending withdrawals are excluded from `totalAssets()`
- Idle liquidity reserve remains in-vault for withdrawals
- `recoverTokens()` allows owner to recover accidental transfers

### Batched Withdrawals
- All withdrawals queue and are processed FIFO at `settleEpoch`
- No partial payouts; requests are skipped until fully liquid

## 🧪 Testing

### Run All Foundry Tests
```bash
forge test -vvv
```

### Run Specific Test File
```bash
forge test --match-path test/foundry/unit/StrategyLib.t.sol -vvv
```

### Run with Gas Reporting
```bash
forge test --gas-report
```

### Fork Testing (HyperEVM)
```bash
forge test --fork-url https://rpc.hyperliquid.xyz/evm -vvv
```

## 🔐 Security

- OpenZeppelin upgradeable contracts
- Owner-only admin functions
- Pausable for emergency stops
- ReentrancyGuard on all state-changing functions
- SafeERC20 for token transfers
- Input validation on all public functions

## 📄 License

MIT

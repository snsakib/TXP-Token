# Agent Instructions — TXP Token Ecosystem

A **Hardhat v3** project (ESM + TypeScript) deploying and testing a BSC token ecosystem: `TXPToken`, `LiquidCashToken` (LCX), `YapitToken` (YTC), `YapitSwap`, `TXPSwap`, and `TokenSwap`.

## Build / Test / Deploy

```sh
# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test test/TXPSwap.ts
npx hardhat test test/TXPToken.ts

# Deploy (order matters: YTC → LCX → TXP → YapitSwap → TXPSwap → TokenSwap)
npx hardhat ignition deploy ignition/modules/YTCToken.ts   --network bscTestnet --deployment-id ytc-token
npx hardhat ignition deploy ignition/modules/LCXToken.ts   --network bscTestnet --deployment-id lcx-token
npx hardhat ignition deploy ignition/modules/TXPToken.ts   --network bscTestnet --deployment-id txp-token
npx hardhat ignition deploy ignition/modules/YapitSwap.ts  --network bscTestnet --deployment-id yapit-swap \
  --parameters '{"YapitSwapModule":{"ytc":"<YTC_ADDR>","lcx":"<LCX_ADDR>","treasury":"<TREASURY_ADDR>"}}'
npx hardhat ignition deploy ignition/modules/TXPSwap.ts    --network bscTestnet --deployment-id txp-swap-v2 \
  --parameters '{"TXPSwapModule":{"treasury":"<TREASURY_ADDR>"}}'
npx hardhat ignition deploy ignition/modules/TokenSwap.ts  --network bscTestnet --deployment-id token-swap \
  --parameters '{"TokenSwapModule":{"txp":"<TXP_ADDR>","ytc":"<YTC_ADDR>","lcx":"<LCX_ADDR>","treasury":"<TREASURY_ADDR>"}}'
```

See [instructions.txt](instructions.txt) for canonical commands and live testnet addresses.

## Environment Variables

Loaded via `dotenv/config` in [hardhat.config.ts](hardhat.config.ts). Required in `.env` (no `0x` prefix on keys):

| Variable | Purpose |
|---|---|
| `BSC_TESTNET_RPC_URL` | BSC testnet RPC endpoint |
| `BSC_TESTNET_PRIVATE_KEY` | Deployer wallet private key |

> Never commit `.env`. It should be listed in `.gitignore`.

## Architecture

| Contract | Standard | Notes |
|---|---|---|
| `TXPToken` | Custom ERC-20 (no OZ) | Fixed 1B supply, pause/blacklist/burn, owner-only admin |
| `LiquidCashToken` (LCX) | OZ v5 ERC20Burnable + Ownable | 1B supply to owner, owner can mint post-deploy |
| `YapitToken` (YTC) | OZ v5 ERC20Burnable + Ownable | Same structure as LCX |
| `YapitSwap` | OZ v5 Pausable + ReentrancyGuard + Ownable | YTC ↔ LCX swaps + **staking system**, dual price feed (manual/DEX) |
| `TXPSwap` | OZ v5 Pausable + ReentrancyGuard + Ownable | TXP/YTC/LCX swaps via manual price or PancakeRouter, **no staking** |
| `TokenSwap` | OZ v5 Pausable + ReentrancyGuard + Ownable | Unified TXP/YTC/LCX swap (replaces YapitSwap + TXPSwap), **no staking**, dual price feed (manual/DEX) |

Both swap contracts inline `IPancakeRouter01`/`IPancakeRouter02` (not imported from a package) and target PancakeSwap v2 on BSC.

**Fee encoding:** `1e18 = 1%`, `MAX_FEE = 100e18`. Formula: `fee = amount * platformFee / MAX_FEE`.

## Key Conventions

- **viem, not ethers.js** — all contract interaction uses `viem` v2 via `@nomicfoundation/hardhat-toolbox-viem`.
- **`node:test` runner, not Mocha** — tests use `import { describe, it } from "node:test"` and `import assert from "node:assert/strict"`.
- **ESM throughout** — `"type": "module"` in `package.json`; use ESM `import`/`export` syntax everywhere.
- **Ignition modules** follow the pattern `<ContractName>Module` (e.g. `TXPSwapModule`). Deployment IDs use kebab-case.
- **Pragma style:** `TXPToken` uses `^0.8.28`; all other contracts use locked `0.8.28`.
- **OpenZeppelin v5** (`^5.6.1`) for LCX, YTC, YapitSwap, TXPSwap. `TXPToken` intentionally has no OZ dependency.
- **No `package.json` scripts** — use raw `npx hardhat ...` commands.
- Live BSC testnet deployed addresses are in [instructions.txt](instructions.txt) and hardcoded as defaults in [ignition/modules/TXPSwap.ts](ignition/modules/TXPSwap.ts).

## Project Structure

```
contracts/      # Solidity source files
ignition/
  modules/      # Hardhat Ignition deployment modules (.ts)
  deployments/  # Deployment artifacts and journal (chain-97 = BSC testnet)
test/           # Node.js test runner tests using viem
scripts/        # Utility scripts (OP chain demo)
artifacts/      # Compiled contract artifacts (auto-generated)
```

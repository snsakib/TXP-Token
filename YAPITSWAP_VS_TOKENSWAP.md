# YapitSwap vs TokenSwap — Contract Comparison

This document compares the original **`YapitSwap.sol`** swap contract with its successor **`TokenSwap.sol`**, which unifies swap functionality previously split across YapitSwap and TXPSwap.

| | **YapitSwap** | **TokenSwap** |
|---|---|---|
| **File** | `contracts/YapitSwap.sol` (~907 lines) | `contracts/TokenSwap.sol` (~580 lines) |
| **Purpose** | YTC ↔ LCX swaps with integrated staking | Unified TXP ↔ LCX, TXP ↔ YTC, LCX ↔ YTC swaps |
| **Staking** | Yes — built-in | No — output sent directly to user |
| **Tokens** | YTC, LCX | TXP, YTC, LCX |
| **Default network addresses** | BSC Mainnet | BSC Testnet |

---

## 1. High-Level Architecture

### YapitSwap

YapitSwap was the first-generation swap contract. It handled **YTC and LCX** only and combined two concerns in one contract:

1. **Manual-price swaps** via the `swap()` function (admin-set prices, contract-held liquidity).
2. **Staking** — when a user swapped into YTC or LCX, the output was **automatically staked** instead of transferred to the wallet.
3. **PancakeRouter passthrough** — wrapper functions that deduct a platform fee then delegate to PancakeSwap.

### TokenSwap

TokenSwap is the consolidated replacement. Per its NatSpec header, it **replaces both YapitSwap and TXPSwap**. It keeps manual/DEX price feeds, platform fees, liquidity management, and PancakeRouter passthrough, but **removes staking entirely**. All swap outputs go directly to the recipient.

```
YapitSwap era:
  YapitSwap  →  YTC/LCX swaps + staking
  TXPSwap    →  TXP/LCX/YTC swaps, no staking

TokenSwap era:
  TokenSwap  →  TXP + YTC + LCX swaps, no staking (single contract)
```

---

## 2. Token Support

| Aspect | YapitSwap | TokenSwap |
|---|---|---|
| **Core tokens** | `YTC`, `LCX` | `TXP`, `YTC`, `LCX` |
| **`TokenFeed` enum** | `YTC, LCX, USDT, USDC, WBNB, ROUTER, TREASURY` | `TXP, YTC, LCX, USDT, USDC, WBNB, ROUTER, TREASURY` |
| **Default manual price feeds** | YTC, LCX only | TXP, YTC, LCX |
| **Default manual prices** | YTC = `1e18`, LCX = `0.5e18` | TXP = `1e16` (0.01 USD), YTC = `1e18`, LCX = `0.5e18` |

TokenSwap adds first-class **TXP** support that YapitSwap never had. TXP swaps previously required a separate **TXPSwap** contract with duplicated logic.

---

## 3. Staking System (Major Removal)

YapitSwap includes a full staking subsystem. **TokenSwap removes all of it.**

### YapitSwap staking features

| Item | Description |
|---|---|
| **State** | `unStakeFee`, `stakesFeed`, `stakerInfo`, `stakeIds` |
| **Structs** | `StakeFeed` (min, max, rate, period), `userStake` |
| **Constructor defaults** | YTC & LCX: min `100e18`, max `1000e18`, rate `10e18` (10%), period `365 days` |
| **Admin** | `setStakeData()`, `setStakeFee()` |
| **User** | `unStake(stakeId)` — pays principal + reward minus unstake fee |
| **Internal** | `_stake()` — called automatically on swap output to YTC/LCX |
| **Events** | `Staked`, `UnStaked` |

### Auto-staking on swap (YapitSwap only)

In YapitSwap's `swap()`, when the output token is YTC or LCX, tokens are **not** sent to the user — they are locked via `_stake()`:

```solidity
// YapitSwap — swap() output handling
if (address(_path[_path.length - 1]) == address(YTC) ||
    address(_path[_path.length - 1]) == address(LCX)) {
    _stake(_msgSender(), _path[_path.length - 1], amountOut);
} else {
    IERC20(_path[_path.length - 1]).safeTransfer(_to, amountOut);
}
```

### TokenSwap behavior

TokenSwap always pays out directly:

```solidity
// TokenSwap — swap() output handling
IERC20(_path[1]).safeTransfer(_to, amountOut);
```

There is no `unStakeFee`, no stake configuration, and no stake-related storage or events.

---

## 4. Constructor

| Parameter | YapitSwap | TokenSwap |
|---|---|---|
| `_owner` | ✓ | ✓ |
| `_ytc` | ✓ | ✓ |
| `_lcx` | ✓ | ✓ |
| `_txp` | — | ✓ |
| `_treasury` | ✓ | ✓ |
| `_platformFee` | ✓ | ✓ |
| `_unStakeFee` | ✓ | — |

**YapitSwap** initializes staking feeds for YTC and LCX in the constructor.

**TokenSwap** validates all inputs at deploy time (`InvalidTxp`, `InvalidYtc`, `InvalidLcx`, `InvalidTreasury`, `FeeTooHigh`) and sets manual price feeds for all three core tokens.

---

## 5. Default Chain Addresses

The contracts ship with different hardcoded defaults:

| Address | YapitSwap (Mainnet) | TokenSwap (Testnet) |
|---|---|---|
| **WBNB** | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |
| **PancakeRouter** | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | `0xD99D1c33F9fC3444f8101754aBC46c52416550D1` |
| **USDT** | `0x55d398326f99059fF775485246999027B3197955` | `0x337610d27c682E347C9cD60BD4b3b107C9d34dDd` |
| **USDC** | `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` | `0x89C8da7569085D406800C473619d0c6B7AC0CE8E` |

Both contracts allow updating these via `updateTokens()`.

---

## 6. Core `swap()` Function

Both contracts expose a `swap(address[] memory _path, uint256 _amountIn, address _to)` entry point for manual-price swaps. The flow is similar (deduct fee → collect input → calculate output → pay recipient), but behavior differs in important ways.

### Similarities

- 2-hop paths only (`[tokenIn, tokenOut]`)
- `WBNB` represents native BNB
- Platform fee deducted from gross input; fee sent to `treasury`
- Requires at least one side of the pair to use `PriceFeed.MANUAL`
- `onlyValidUser(_to)` — caller must equal recipient
- `whenNotPaused`, `nonReentrant` guards

### Differences

| Behavior | YapitSwap | TokenSwap |
|---|---|---|
| **Supported pairs** | Any 2-token path (no TXP guard) | Must involve at least one of `{TXP, YTC, LCX}` |
| **Output delivery** | YTC/LCX → auto-stake; others → transfer | Always transfer to `_to` |
| **Pre-payout balance check** | No explicit check for ERC-20 output | Checks contract balance before payout |
| **BNB payout check** | Direct `transfer` | Reverts with `InsufficientBnbLiquidity` if underfunded |
| **Validation style** | `require()` + string messages | Custom errors |

TokenSwap's `PairNotSupported` guard prevents arbitrary token pairs that do not involve the ecosystem tokens:

```solidity
if (
    _path[0] != TXP && _path[0] != YTC && _path[0] != LCX &&
    _path[1] != TXP && _path[1] != YTC && _path[1] != LCX
) revert PairNotSupported();
```

---

## 7. Price Calculation (`calcOutAmount`)

Both contracts support **MANUAL** and **DEX** price feeds and share the same overall pattern for stablecoin and WBNB routes. TokenSwap improves token-to-token manual pricing.

### Manual token → token (both sides have manual USD price)

**YapitSwap** — divides input by input token price only (not a true cross-rate):

```solidity
amountOut = ((_amountIn * PRECISION) / getPrice(_tokenIn));
```

**TokenSwap** — proper cross-rate using both prices:

```solidity
uint256 priceIn  = getPrice(_tokenIn);
uint256 priceOut = getPrice(_tokenOut);
amountOut = (_amountIn * priceIn) / priceOut;
```

Example: swapping 100 LCX (0.50 USD) → YTC (1.00 USD)

| Contract | Formula | Result |
|---|---|---|
| YapitSwap | `100 * 1e18 / 0.5e18` | 200 (incorrect — treats as USD value, not YTC amount) |
| TokenSwap | `100 * 0.5e18 / 1e18` | 50 YTC (correct cross-rate) |

### WBNB → token path

**YapitSwap** calls `getAmountsOut` but then **overwrites** the result with a manual formula that uses `_amountIn` instead of the DEX-derived USD value:

```solidity
amountOut = IPancakeRouter02(pancakeRouter).getAmountsOut(_amountIn, path)[...];
amountOut = ((_amountIn * getPrice(_tokenOut)) / PRECISION);  // overwrites DEX result
```

**TokenSwap** correctly uses the DEX-derived USD value:

```solidity
uint256 usdValue = IPancakeRouter02(pancakeRouter).getAmountsOut(_amountIn, path)[1];
amountOut = (usdValue * getPrice(_tokenOut)) / PRECISION;
```

---

## 8. PancakeRouter Passthrough Functions

Both contracts expose the same set of fee-wrapped router functions:

| Function | YapitSwap | TokenSwap |
|---|---|---|
| `swapExactTokenForTokens` | ✓ | ✓ |
| `swapTokensForExactTokens` | ✓ | ✓ |
| `swapExactTokensForETH` | ✓ | ✓ |
| `swapTokensForExactETH` | ✓ | ✓ |
| `swapExactETHForTokens` | ✓ | ✓ |
| `swapETHForExactTokens` | ✓ | ✓ |
| `swapExactTokensForTokensSupportingFeeOnTransferTokens` | ✓ | ✓ |
| `swapExactETHForTokensSupportingFeeOnTransferTokens` | ✓ | ✓ |
| `swapExactTokensForETHSupportingFeeOnTransferTokens` | ✓ | ✓ |

Logic is equivalent: pull tokens, deduct platform fee to treasury, approve router, execute swap, emit event.

### Internal helper naming

| YapitSwap | TokenSwap |
|---|---|
| `internalSupportingTransactions()` (private) | `_internalSupportingTransactions()` (private) |
| `internalProcess()` (private, unused by `swap()`) | Removed |

---

## 9. Liquidity Management

Both contracts act as admin-managed reserves for manual-price swaps (not AMMs). Owners deposit and withdraw liquidity.

| Function | YapitSwap | TokenSwap |
|---|---|---|
| Deposit | `addManualLiqudity()` *(typo)* | `addManualLiquidity()` |
| Withdraw | `removeLiqudity()` *(typo)* | `removeLiquidity()` |

Behavior is the same: pass `address(0)` for BNB deposits/withdrawals.

---

## 10. Admin & Configuration Functions

| Function | YapitSwap | TokenSwap |
|---|---|---|
| `pause()` / `unPause()` | ✓ | ✓ |
| `updateTokens()` | ✓ | ✓ (+ TXP) |
| `setPrice()` / `setprice()` | ✓ (typo in name) | ✓ |
| `setPriceFeed()` | ✓ | ✓ |
| `setPlatformFee()` | ✓ | ✓ |
| `getPlatformFee()` | ✓ | ✓ |
| `getPrice()` | ✓ | ✓ |
| `calcOutAmount()` | ✓ | ✓ (improved) |
| `setStakeData()` | ✓ | — |
| `setStakeFee()` | ✓ | — |
| `unStake()` | ✓ | — |

---

## 11. Events

| Event | YapitSwap | TokenSwap |
|---|---|---|
| Swap completed | `YapitSwapped(user, assetIn, assetOut, amountIns, amountOuts, fees, timestamp)` | `TokenSwapped(user, assetIn, assetOut, amountIn, amountOut, fee, timestamp)` |
| Stake created | `Staked(user, asset, amount, stakeId)` | — |
| Unstake | `UnStaked(user, asset, stakeId, fee, amount)` | — |

TokenSwap uses cleaner parameter names (`amountIn` vs `amountIns`, `fee` vs `fees`).

---

## 12. Error Handling & Code Quality

| Aspect | YapitSwap | TokenSwap |
|---|---|---|
| **Errors** | `require("string")` messages (e.g. `"!ZERO"`, `"yapit : Insufficient Liqudity!"`) | Custom Solidity errors (e.g. `InvalidAmount`, `InsufficientTokenLiquidity`) |
| **Documentation** | Minimal | NatSpec on contract, constructor, and key functions |
| **Line count** | ~907 lines | ~580 lines (~36% smaller) |
| **Dead code** | `internalProcess()` defined but not used by `swap()` | Removed |
| **Input validation** | Light (mostly at call sites) | Constructor + explicit guards throughout |

Custom errors in TokenSwap reduce deployment and revert gas costs compared to string reverts.

---

## 13. Shared Design (Unchanged Concepts)

Both contracts share the same foundational design:

- **OpenZeppelin v5**: `Pausable`, `ReentrancyGuard`, `Ownable`, `SafeERC20`
- **Fee encoding**: `1e18 = 1%`, `MAX_FEE = 100e18`, `fee = amount * platformFee / MAX_FEE`
- **Price feed enum**: `DEX` | `MANUAL`
- **Dual swap modes**:
  - `swap()` for admin-priced pairs using contract-held liquidity
  - Router passthrough for on-chain PancakeSwap liquidity
- **`onlyValidUser` modifier**: `msg.sender` must equal the `_to` recipient
- **`receive()`** payable fallback for BNB

---

## 14. Migration Summary

When moving from YapitSwap to TokenSwap, consider these operational changes:

| Topic | Action Required |
|---|---|
| **Contract address** | Deploy TokenSwap; update frontend/admin to point to new address |
| **TXP swaps** | No longer need a separate TXPSwap contract — TXP is native to TokenSwap |
| **Staking** | Staking is removed; users receive tokens directly. Migrate any active stakes separately if needed |
| **Prices** | Re-set `manualPrice` and `activePriceFeed` for TXP, YTC, LCX on TokenSwap |
| **Liquidity** | Fund TokenSwap via `addManualLiquidity()` — liquidity does not carry over automatically |
| **Admin UI** | Replace dual-contract selector (YapitSwap / TXPSwap) with single TokenSwap target |
| **Events** | Update indexers/listeners from `YapitSwapped` → `TokenSwapped`; remove stake event handlers |
| **ABI** | `swap()` signature is compatible; staking functions and `unStakeFee` are gone; `TokenFeed` enum gains `TXP` |

---

## 15. Quick Reference — Feature Matrix

| Feature | YapitSwap | TokenSwap |
|---|:---:|:---:|
| TXP support | ✗ | ✓ |
| YTC support | ✓ | ✓ |
| LCX support | ✓ | ✓ |
| Manual price feed | ✓ | ✓ |
| DEX price feed | ✓ | ✓ |
| Platform fee | ✓ | ✓ |
| PancakeRouter passthrough | ✓ | ✓ |
| Manual liquidity mgmt | ✓ | ✓ |
| Auto-stake on YTC/LCX output | ✓ | ✗ |
| Stake / unstake system | ✓ | ✗ |
| Unstake fee | ✓ | ✗ |
| Cross-rate `calcOutAmount` | ✗ (buggy) | ✓ |
| Pre-payout balance checks | Partial | ✓ |
| Custom errors | ✗ | ✓ |
| NatSpec documentation | ✗ | ✓ |
| Pair whitelist (TXP/YTC/LCX) | ✗ | ✓ |

---

*Generated from source analysis of `contracts/YapitSwap.sol` and `contracts/TokenSwap.sol`.*

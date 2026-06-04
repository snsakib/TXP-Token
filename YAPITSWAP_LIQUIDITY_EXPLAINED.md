# YapitSwap / TXPSwap — Liquidity Explained

## YapitSwap / TXPSwap are NOT AMMs — but they still need liquidity. Here's why:

---

### The Key Difference

A **PancakeSwap AMM pool** holds liquidity to facilitate trades **between two external tokens** (e.g., ARK ↔ USDT). Anyone can swap, and the pool automatically prices using $k = x \times y$.

YapitSwap/TXPSwap hold liquidity for a completely **different purpose** — to act as a **treasury/reserve** that pays out the **output token** for manual-priced pairs.

---

### What Actually Happens in a Manual Swap (e.g., LCX → USDT)

```
User sends 100 LCX to YapitSwap
│
├── YapitSwap deducts platform fee → treasury
├── YapitSwap calls calcOutAmount(LCX, USDT, netAmount)
│   └── Uses manualPrice[LCX] and manualPrice[USDT] set by admin
│       (NOT an AMM formula — pure division: priceIn / priceOut)
│
└── YapitSwap pays out X USDT to user
    ← this USDT must already be sitting inside the contract
```

**If there's no USDT in the contract, the swap reverts.** The contract has no AMM pool to pull from — it can only pay what it physically holds.

---

### Why Admin Must Add Liquidity

| Scenario | AMM (PancakeSwap) | YapitSwap/TXPSwap |
|---|---|---|
| Where does output token come from? | From the pool's own reserves, auto-managed by LPs | From tokens **manually deposited** by the admin via `addManualLiquidity()` |
| Who sets the price? | The reserve ratio ($k = x \times y$) | The admin via `setprice(token, price)` |
| What happens if reserves run out? | Pool becomes imbalanced, price impact rises | **Transaction reverts** — hard failure |

The contract has an explicit check:
```solidity
// Inside swap() / calcOutAmount()
require(IERC20(toToken).balanceOf(address(this)) >= amountOut, "Insufficient liquidity");
```

---

### Summary

> YapitSwap/TXPSwap are essentially **admin-managed vending machines**:
> - Admin loads them with tokens (`addManualLiquidity`)
> - Admin sets fixed prices (`setprice`)
> - Users swap against the contract's own balance
> - No pool, no AMM formula, no automatic pricing

**Liquidity must be added from the admin** because there are no external liquidity providers — the contract itself IS the liquidity provider, and only the owner can fund it.

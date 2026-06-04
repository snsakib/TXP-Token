# DEX / PancakeSwap Pricing Workflow — Technical Documentation

## Table of Contents

1. [Fundamentals: How AMM Pricing Works](#1-fundamentals-how-amm-pricing-works)
2. [Constant Product Formula](#2-constant-product-formula)
3. [PancakeSwap Contract Architecture](#3-pancakeswap-contract-architecture)
4. [How This Project Integrates PancakeSwap Pricing](#4-how-this-project-integrates-pancakeswap-pricing)
5. [Price Feed Mode Detection](#5-price-feed-mode-detection)
6. [Liquidity Pair Discovery](#6-liquidity-pair-discovery)
7. [Multi-Hop Path Resolution](#7-multi-hop-path-resolution)
8. [Quote Calculation: getAmountsOut](#8-quote-calculation-getamountsout)
9. [Price Impact Calculation — Single Hop](#9-price-impact-calculation--single-hop)
10. [Price Impact Calculation — Multi-Hop](#10-price-impact-calculation--multi-hop)
11. [Platform Fee Deduction Before Pricing](#11-platform-fee-deduction-before-pricing)
12. [Exchange Rate Display](#12-exchange-rate-display)
13. [Slippage Tolerance](#13-slippage-tolerance)
14. [Fee-on-Transfer Tokens (slipToken)](#14-fee-on-transfer-tokens-sliptoken)
15. [Swap Execution Routing](#15-swap-execution-routing)
16. [BNB Gas Estimation (maxButton)](#16-bnb-gas-estimation-maxbutton)
17. [API Endpoints Involved in Pricing](#17-api-endpoints-involved-in-pricing)
18. [End-to-End Pricing Flow Diagram](#18-end-to-end-pricing-flow-diagram)
19. [Error Conditions and Recovery](#19-error-conditions-and-recovery)

---

## 1. Fundamentals: How AMM Pricing Works

PancakeSwap is an **Automated Market Maker (AMM)** built on Binance Smart Chain (BSC). Unlike order-book exchanges, AMMs price tokens algorithmically based on the ratio of reserves in a **liquidity pool (pair)**.

### Key Actors

| Actor           | Role                                                             |
|-----------------|------------------------------------------------------------------|
| Liquidity Pool  | Holds two tokens (Token A + Token B) at all times               |
| Liquidity Provider (LP) | Deposits both tokens to earn trading fees               |
| Trader          | Swaps Token A for Token B, changing the reserve ratio           |
| PancakeFactory  | Creates and indexes all trading pair contracts                   |
| PancakeRouter   | Routes trades, calculates output amounts, and executes swaps    |

### Reserve Mechanism

Every pair stores two reserves:

```
reserveIn  = amount of Token A held in the pool
reserveOut = amount of Token B held in the pool
```

The **spot price** (price at zero volume) is simply:

$$
\text{spotPrice} = \frac{reserveOut}{reserveIn}
$$

As a trade executes, `reserveIn` increases and `reserveOut` decreases, pushing the price against the trader. This is called **price impact**.

### Numeric Example (CAKE / USDT pair):

```
reserveIn  = 200,000 CAKE   (Token A held in the pool)
reserveOut = 600,000 USDT   (Token B held in the pool)

spotPrice = reserveOut / reserveIn
          = 600,000 / 200,000
          = 3.0 USDT per CAKE
```

This means before any trade occurs, 1 CAKE is worth **3.0 USDT** at the current pool ratio.

Now suppose a trader swaps **5,000 CAKE** into the pool:

**Why is `reserveOut` (600,000) multiplied by `amountInWithFee` (4,987.5)?**

This comes directly from solving the constant product invariant $k = reserveIn \times reserveOut$ for `amountOut`:

$$k = reserveIn \times reserveOut = 200{,}000 \times 600{,}000 = 120{,}000{,}000{,}000$$

After the trade, $k$ must stay the same:

$$(reserveIn + amountInWithFee) \times (reserveOut - amountOut) = k$$

Solving for `amountOut`:

$$amountOut = reserveOut - \frac{reserveIn \times reserveOut}{reserveIn + amountInWithFee} = \frac{reserveOut \times amountInWithFee}{reserveIn + amountInWithFee}$$

So **`reserveOut` appears in the numerator** because factoring it out is a natural result of the algebra — the pool can only pay out from what it holds. The larger the USDT reserve, the more output you extract for the same input.

```
amountInWithFee  = 5,000 × 0.9975 = 4,987.5
amountOut (USDT) = (600,000 × 4,987.5) / (200,000 + 4,987.5)
                 = 2,992,500,000 / 204,987.5
                 ≈ 14,598.22 USDT  ← pool pays this out

After trade:
  reserveIn  increases → 200,000 + 5,000     = 205,000 CAKE
  reserveOut decreases → 600,000 - 14,598.22 = 585,401.78 USDT

New spot price = 585,401.78 / 205,000 ≈ 2.856 USDT per CAKE
              < 3.0 USDT per CAKE   ← price has moved against the trader
```

**What if the 0.25% fee is removed?**

Without the fee, the full input amount goes directly into the AMM formula:

```
amountIn (no fee) = 5,000  (no 0.9975 multiplier)
amountOut (USDT)  = (600,000 × 5,000) / (200,000 + 5,000)
                  = 3,000,000,000 / 205,000
                  ≈ 14,634.15 USDT
```

Comparing the two:

| Scenario        | amountOut      | Execution Price       | Difference          |
|-----------------|----------------|-----------------------|---------------------|
| With fee (0.25%)| 14,598.22 USDT | 2.9196 USDT / CAKE    | —                   |
| Without fee     | 14,634.15 USDT | 2.9268 USDT / CAKE    | +35.93 USDT more    |

The 0.25% fee costs the trader **~35.93 USDT** on this 5,000 CAKE trade. The fee is collected by liquidity providers as their reward for supplying liquidity to the pool.

So what does the trader actually receive per CAKE?

```
Execution price = amountOut / amountIn
               = 14,598.22 / 5,000
               = 2.9196 USDT per CAKE
```

There are three distinct prices here — they are **not** the same:

| Price             | Value             | Meaning                                              |
|-------------------|-------------------|------------------------------------------------------|
| Spot price before | 3.0 USDT / CAKE   | Pool ratio before the trade; only applies at 0 volume |
| **Execution price** | **2.9196 USDT / CAKE** | **What this trader actually receives per CAKE**   |
| Spot price after  | 2.856 USDT / CAKE | New pool ratio; what the *next* trader will see      |

The trader receives **2.9196 USDT per CAKE**, not 3.0 and not 2.856. The gap between the spot price before (3.0) and the execution price (2.9196) is the **price impact**:

```
priceImpact = (3.0 - 2.9196) / 3.0 × 100 ≈ 2.68%
```

The larger the trade relative to the pool size, the more `reserveIn` grows and `reserveOut` shrinks, resulting in a higher **price impact**.

---

## 2. Constant Product Formula

PancakeSwap v2 uses Uniswap v2's invariant:

$$
k = reserveIn \times reserveOut
$$

This product `k` must remain constant after every trade (accounting for fees). Given an input amount `amountIn`, the output is:

$$
amountOut = \frac{reserveOut \times amountIn \times (1 - fee)}{reserveIn + amountIn \times (1 - fee)}
$$

PancakeSwap charges a **0.25% swap fee** (fee = 0.0025), so the fee multiplier is `0.9975`:

$$
amountOut = \frac{reserveOut \times (amountIn \times 0.9975)}{reserveIn + (amountIn \times 0.9975)}
$$

### Numeric Example (LCX → USDT pair):

```
reserveIn  = 500,000 LCX
reserveOut = 1,000,000 USDT
amountIn   = 1,000 LCX

amountInWithFee = 1,000 × 0.9975 = 997.5
amountOut = (1,000,000 × 997.5) / (500,000 + 997.5)
          = 997,500,000 / 500,997.5
          ≈ 1,990.02 USDT
```

Mid-price would be `1,000,000 / 500,000 = 2.0 USDT/LCX`.  
Execution price is `1,990.02 / 1,000 = 1.99002 USDT/LCX`.  
Price impact = `(2.0 - 1.99002) / 2.0 × 100 ≈ 0.499%`.

---

## 3. PancakeSwap Contract Architecture

This project interacts with three on-chain PancakeSwap contracts, each serving a distinct purpose:

| Contract | Why It Is Used |
|----------|---------------|
| **PancakeFactory** | Used as a **directory** — to look up whether a liquidity pool exists between two tokens and get its address. Without this, the project wouldn't know where the pool lives on-chain. |
| **PancakePair** | Used to **read live reserve balances** from a specific pool. This is what powers price impact calculation and liquidity availability checks — the raw numbers behind the AMM formula. |
| **PancakeRouter** | Used as the **entry point for all trades and price quotes**. It handles routing logic, calculates output amounts across single or multi-hop paths, and executes the actual swap on-chain. |

### 3.1 PancakeFactory

**Address:** `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73`  
**ABI file:** `app/AhdfBdkfI/factoryAbi.json`

Key function used:
```solidity
function getPair(address tokenA, address tokenB) external view returns (address pair);
```
- Returns `address(0)` if no direct liquidity pool exists between the two tokens.
- This project calls it to detect whether a **direct pair** or a **multi-hop route** is needed.

### 3.2 PancakePair

**ABI file:** `app/AhdfBdkfI/pairAbi.json`

Key functions used:
```solidity
function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
function token0() external view returns (address);
function token1() external view returns (address);
```
- `getReserves()` returns reserves in the canonical token order (`token0 < token1` by address).
- `token0()` identifies which reserve slot belongs to which token so the project can correctly assign `reserveIn` / `reserveOut`.

### 3.3 PancakeRouter

**Address (config):** `0x10ED43C718714eb63d5aA57B78B54704E256024E`  
**ABI file:** `app/AhdfBdkfI/routerAbi.json`  
**Runtime address:** fetched on-chain via `swapContract.pancakeRouter()` (overrides config if YapitSwap has a custom router set)

Key functions used:
```solidity
function getAmountsOut(uint256 amountIn, address[] calldata path) 
    external view returns (uint256[] memory amounts);
```
- Simulates the trade through a full path and returns the amount at each hop.
- For a path `[A, B]`, returns `[amountIn, amountOut]`.
- For a path `[A, WBNB, B]`, returns `[amountIn, amountMid, amountOut]`.

---

## 4. How This Project Integrates PancakeSwap Pricing

This project wraps PancakeSwap pricing inside its own **YapitSwap contract**. The flow is:

```
User Input
    │
    ▼
YapitSwap.activePriceFeed(tokenAddress)
    │
    ├── Returns 0n → isSpecialMode = true  → DEX/PancakeSwap Pricing
    └── Returns 1n → isSpecialMode = false → Manual/Internal Pricing
```

### Token Classification

**Source:** `app/home/components/Swap.jsx`

| Token | Symbol | type      | DEX Pricing | slipToken | Decimals |
|-------|--------|-----------|-------------|-----------|----------|
| USDC  | USDC   | `manual`  | ✗           | false     | 18       |
| YTC   | YTC    | `manual`  | ✗           | false     | 18       |
| LCX   | LCX    | `manual`  | ✗           | false     | 18       |
| USDT  | USDT   | `manual`  | ✗           | false     | 18       |
| WBNB  | WBNB   | `manual`  | Partial*    | false     | 18       |
| ARK   | ARK    | `pancake` | ✓           | **true**  | 18       |
| FIST  | FIST   | `pancake` | ✓           | false     | **6**    |
| ASTER | ASTER  | `pancake` | ✓           | false     | 18       |
| CAKE  | CAKE   | `pancake` | ✓           | false     | 18       |
| LINK  | LINK   | `pancake` | ✓           | false     | 18       |
| USDA  | USDA   | `pancake` | ✓           | **true**  | 18       |
| GOT   | GOT    | `pancake` | ✓           | **true**  | **9**    |

> *WBNB is treated as manual-mode but its exchange rate is fetched via PancakeRouter path `[WBNB, USDT]`.

---

## 5. Price Feed Mode Detection

**File:** `app/home/components/hooks/useSwapLogic.js` → `fetchStaticData()`  
**Triggered:** Every time `fromToken` or `toToken` changes.

```javascript
// Step 1: Determine the "native" token in the pair (LCX or YTC)
let targetAddress;
if (isNativeToken(fromToken.address)) targetAddress = fromToken.address;
else if (isNativeToken(toToken.address)) targetAddress = toToken.address;
else targetAddress = '';

// Step 2: Query the YapitSwap contract
const activestatus = await swapContract.activePriceFeed(targetAddress);

// Step 3: Branch
if (activestatus == 0n) {
  // DEX Mode — use PancakeSwap pricing
  setIsSpecialMode(true);
  setActiveTokens(tokenData.secondaryList); // show all tokens including DEX tokens
} else {
  // Manual Mode — use internal price feed
  setIsSpecialMode(false);
  setActiveTokens(tokenData.defaultList);   // show only manual tokens
}
```

### `isNativeToken()` Helper

```javascript
const isNativeToken = (addr) =>
  addr.toLowerCase() === addresses.LCASH.toLowerCase() ||
  addr.toLowerCase() === addresses.YTC.toLowerCase();
```

This means pairs like `ARK ↔ USDT`, `FIST ↔ WBNB`, `GOT ↔ CAKE` all go through DEX pricing because neither token is LCX/YTC.

---

## 6. Liquidity Pair Discovery

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `liquidityCheck()`  
**Called from:** Both `fetchStaticData()` and `getDexSwapDetails()`

### Step-by-Step

```
liquidityCheck({ fromaddress, toaddress, ... })
│
├── 1. Factory.getPair(fromaddress, toaddress)
│
├── If pair address ≠ ZeroAddress:
│   ├── Create PairContract = Contract(pairAddress, PAIR_ABI, signer)
│   ├── Call PairContract.getReserves() → [reserve0, reserve1, timestamp]
│   ├── Call PairContract.token0() → determines reserve order
│   ├── Compute reserveOut based on whether token0 = fromAddress:
│   │     token0 == fromAddress → reserveOut = reserve1
│   │     token0 != fromAddress → reserveOut = reserve0
│   ├── availableLiquidity = reserveOut (in human-readable units)
│   └── Return { hasPair: true, isMulti: false, pairvaluecontract, availableLiquidity }
│
└── If pair address = ZeroAddress → no direct pair:
    ├── Fetch multi-hop paths via API: POST /fetch-multi-path-address
    │     payload: { from_token_symbol, to_token_symbol }
    ├── For each returned path array:
    │   ├── Filter out zero addresses
    │   ├── Call router.getAmountsOut(1 unit, path)
    │   └── Pick first path where amountOut > 0 as bestPath
    │
    ├── For bestPath, collect reservesPerHop[]:
    │   └── For each consecutive token pair in path:
    │       ├── Factory.getPair(tokenIn, tokenOut)
    │       ├── PairContract.getReserves()
    │       ├── PairContract.token0()
    │       ├── ERC20.decimals() for each token
    │       └── Push { pair, tokenIn, tokenOut, reserveIn, reserveOut }
    │
    └── Return { hasPair: true, isMulti: true, reservesPerHop, path, bestAmountOut }
```

### Reserve Order Correction

A critical detail: PancakeSwap always stores tokens in ascending address order (`token0 < token1`). The reserves returned by `getReserves()` always correspond to `(reserve0 = token0 reserves, reserve1 = token1 reserves)`.

```javascript
if (token0.toLowerCase() === fromAddress.toLowerCase()) {
  reserveIn  = ethers.formatUnits(r0, decimalsIn);   // fromToken is token0
  reserveOut = ethers.formatUnits(r1, decimalsOut);   // toToken is token1
} else {
  reserveIn  = ethers.formatUnits(r1, decimalsIn);   // fromToken is token1
  reserveOut = ethers.formatUnits(r0, decimalsOut);   // toToken is token0
}
```

If this is not done correctly, the price calculation would be inverted.

---

## 7. Multi-Hop Path Resolution

When no direct liquidity pair exists (e.g., `ARK ↔ ASTER`), the trade is routed through one or more intermediate tokens (commonly `WBNB` or `USDT`).

### API Endpoint

**Mutation:** `useMultiSwapPair()` from `app/home/components/hooks/api/swapapi.js`  
**API call:** `POST /fetch-multi-path-address`  
**Payload:**
```json
{
  "from_token_symbol": "ARK",
  "to_token_symbol": "ASTER"
}
```
**Response:** Array of possible address paths:
```json
[
  ["0xCae1...ARK", "0xbb4C...WBNB", "0x000A...ASTER"],
  ["0xCae1...ARK", "0x5539...USDT", "0x000A...ASTER"]
]
```

### Path Selection Logic

```javascript
let bestPath = null;
let bestAmountOut = 0;

for (const rawPath of pathsFromApi) {
  const path = rawPath.filter(addr => addr && addr !== ethers.ZeroAddress);
  if (path.length < 2) continue;

  try {
    const amountsOut = await pancakeRouter.getAmountsOut(amountInWei, path);
    const outAmount = Number(ethers.formatUnits(
      amountsOut[amountsOut.length - 1], 
      toDecimal
    ));
    if (outAmount > 0) {
      bestPath = path;
      bestAmountOut = outAmount;
      break; // take the first valid path
    }
  } catch {}
}
```

The project takes the **first valid path** (not necessarily the optimal one). The path that returns `amountOut > 0` from `getAmountsOut` is accepted.

### Multi-Hop Example

`ARK → WBNB → ASTER`:
```
getAmountsOut(1000 ARK, [ARK, WBNB, ASTER])
  → [1000_ARK_wei, X_WBNB_wei, Y_ASTER_wei]

Final amountOut = amountsOut[2] = Y_ASTER_wei
```

---

## 8. Quote Calculation: `getAmountsOut`

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `getDexSwapDetails()`  
**Triggered:** 600ms debounced after every `sendAmount` change (in `useSwapLogic.js`).

### Full Quote Pipeline

```
getDexSwapDetails({ signer, sendAmount, fromToken, toToken, ... })
│
├── 1. liquidityCheck() → determines path and reserves
│
├── 2. amountInWei = ethers.parseUnits(sendAmount, fromToken.decimals)
│
├── 3. YapitSwap.getPlatformFee(amountInWei)
│       Returns [feeAmountWei, ...]
│       effectiveAmount = feeAmountWei (net amount after fee deduction)
│
│      ⚠️ NOTE: The returned fee[0] IS the effective amount, not the fee itself.
│         The fee is already subtracted inside the contract.
│
├── 4a. Single-hop:
│       path = [fromToken.address, toToken.address]
│       amountsOut = router.getAmountsOut(effectiveAmount, path)
│       finalAmountOut = amountsOut[1]
│
├── 4b. Multi-hop:
│       path = liqidcheck.path  (from API + validation)
│       amountsOut = router.getAmountsOut(effectiveAmount, path)
│       finalAmountOut = amountsOut[amountsOut.length - 1]
│
├── 5. Format output:
│       receiveAmount = ethers.formatUnits(finalAmountOut, toToken.decimals)
│
├── 6. Liquidity check (single-hop only):
│       if (availableLiquidity < toAmount) → message = "Insufficient Liquidity"
│
└── 7. Return {
         receiveAmount, feeAmount, path, priceImpact, isMulti,
         message: "Swap Now" | "Insufficient Liquidity" | "No Pair Found"
       }
```

### Where It Is Called

```javascript
// app/home/components/hooks/useSwapLogic.js (line ~345)
const { receiveAmount, feeAmount, message, priceImpact, path, isMulti, bestAmountOut }
  = await getDexSwapDetails({
    signer,
    sendAmount,
    fromToken,
    toToken,
    addresses,
    abis,
    checkMultiPairApi,
  });

setReceiveAmount(receiveAmount);
setCalculatedFeeAmount(feeAmount);
setBtnMessage(message);
setPriceImpact(priceImpact);
setApiMultiPath(path);
setIsMulti(isMulti);
```

---

## 9. Price Impact Calculation — Single Hop

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `calculatePriceImpact()`

This function quantifies how much the trade moves the price against the trader.

### Algorithm

```javascript
async function calculatePriceImpact(pair, fromAddress, fromAmount, fromDecimals, toDecimals) {
  const feeMultiplier = 0.9975;  // PancakeSwap 0.25% fee

  const [reserve0, reserve1] = await pair.getReserves();
  const token0 = await pair.token0();

  // Correctly assign reserves
  let reserveIn, reserveOut;
  if (token0.toLowerCase() === fromAddress.toLowerCase()) {
    reserveIn  = Number(ethers.formatUnits(reserve0, fromDecimals));
    reserveOut = Number(ethers.formatUnits(reserve1, toDecimals));
  } else {
    reserveIn  = Number(ethers.formatUnits(reserve1, fromDecimals));
    reserveOut = Number(ethers.formatUnits(reserve0, toDecimals));
  }

  // Spot price (before trade)
  const midPrice = reserveOut / reserveIn;

  // Simulated AMM output using constant product formula
  const amountInWithFee = fromAmount * feeMultiplier;
  const amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

  // Execution price (what the trader actually receives per unit)
  const executionPrice = amountOut / fromAmount;

  // Price impact: how much worse the execution price is vs spot
  const priceImpact = 1 - (executionPrice / midPrice);

  return (priceImpact * 100).toFixed(4);  // e.g., "0.4998"
}
```

### Mathematics

$$
\text{midPrice} = \frac{R_{out}}{R_{in}}
$$

$$
\text{amountOut} = \frac{R_{out} \times (A_{in} \times 0.9975)}{R_{in} + (A_{in} \times 0.9975)}
$$

$$
\text{executionPrice} = \frac{amountOut}{A_{in}}
$$

$$
\text{priceImpact} = \left(1 - \frac{executionPrice}{midPrice}\right) \times 100
$$

### Interpretation

| Price Impact | Risk Level |
|--------------|------------|
| < 0.1%       | Negligible |
| 0.1% – 1%    | Low        |
| 1% – 3%      | Medium     |
| 3% – 5%      | High       |
| > 5%         | Very High  |

---

## 10. Price Impact Calculation — Multi-Hop

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `calculateMultiHopPriceImpact()`

For routes like `A → WBNB → B`, the price impact accumulates across all hops.

### Algorithm

```javascript
async function calculateMultiHopPriceImpact(reservesPerHop, fromAmount) {
  const feeMultiplier = 0.9975;
  let amountIn      = fromAmount;
  let executionAmount = amountIn;
  let midPriceRoute = 1;

  for (const hop of reservesPerHop) {
    const { reserveIn, reserveOut } = hop;

    // Accumulated spot price across all hops
    const midPrice = reserveOut / reserveIn;
    midPriceRoute *= midPrice;

    // Simulate AMM output for this hop
    const amountInWithFee = executionAmount * feeMultiplier;
    const amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);
    executionAmount = amountOut;  // output of this hop becomes input of next hop
  }

  // Final comparison: what we got vs what the spot prices promised
  const executionPrice  = executionAmount / amountIn;
  const priceImpact     = 1 - executionPrice / midPriceRoute;

  return (priceImpact * 100).toFixed(4);
}
```

### Mathematics for N hops

$$
\text{midPriceRoute} = \prod_{i=1}^{N} \frac{R_{out,i}}{R_{in,i}}
$$

For each hop $i$:
$$
A_{out,i} = \frac{R_{out,i} \times (A_{in,i} \times 0.9975)}{R_{in,i} + (A_{in,i} \times 0.9975)}, \quad A_{in,i+1} = A_{out,i}
$$

$$
\text{priceImpact} = \left(1 - \frac{A_{out,N} / A_{in,1}}{\text{midPriceRoute}}\right) \times 100
$$

Note: For a 2-hop path, both the PancakeSwap 0.25% fees apply at each hop, so the effective fee is `1 - 0.9975² ≈ 0.499%` before impact.

---

## 11. Platform Fee Deduction Before Pricing

**YapitSwap contract function:** `getPlatformFee(amountIn)`  
**Called in:** `getDexSwapDetails()` and `swapFunction()`

The project's YapitSwap contract charges a platform fee before forwarding the trade to PancakeRouter. This means:

```
User sends:       1000 ARK
Platform fee:     ~0.5% (contract-defined, fetched via swapContract.platformFee())
effectiveAmount:  ~995 ARK
PancakeRouter quotes price for 995 ARK (not 1000)
```

### In Code

```javascript
// getDexSwapDetails() in useDexSwapLogic.js
const fee = await swapContract.getPlatformFee(amountInWei);
feeAmountWei  = fee[0];      // net amount after fee (confusingly named)
effectiveAmount = feeAmountWei;

// getAmountsOut is called with effectiveAmount, NOT amountInWei
amountsOut = await pancakeRouter.getAmountsOut(effectiveAmount, path);
```

> ⚠️ **Important:** `fee[0]` from `getPlatformFee()` is the **net amount** (what goes to the router), not the fee itself. The actual fee deducted = `amountInWei - fee[0]`.

### Fee Display

The fee percentage is fetched once on load:
```javascript
const feeRaw = await swapContract.platformFee();
setFeePercentage(ethers.formatUnits(feeRaw, 18));  // e.g., "0.005" = 0.5%
```

And the human-readable fee amount is:
```javascript
setCalculatedFeeAmount(ethers.formatUnits(feeAmountWei, fromToken.decimals));
```

---

## 12. Exchange Rate Display

**File:** `app/home/components/hooks/useSwapLogic.js` → `fetchStaticData()`

The exchange rate ("1 TokenA = X TokenB") is fetched differently depending on the mode and token pair:

### DEX Mode (isSpecialMode = true)

```javascript
// Standard: use router.getAmountsOut for 1 unit
const amountIn = ethers.parseUnits("1", fromToken.decimals);
const path = [fromToken.address, toToken.address];
const amounts = await routerContract.getAmountsOut(amountIn, path);
setExchangeRate(ethers.formatUnits(amounts[amounts.length - 1], toToken.decimals));
```

For multi-hop pairs, once a trade is calculated:
```javascript
// isMulti = true: use bestAmountOut returned from liquidityCheck
setExchangeRate(Number(bestAmountOut).toFixed(8));
// bestAmountOut = price of 1 unit of fromToken in toToken via getAmountsOut
```

### Manual Mode (isSpecialMode = false) with WBNB

```javascript
// WBNB price is fetched through USDT: WBNB → TUSD
const path = isWBNB(fromToken.address)
  ? [fromToken.address, addresses.TUSD]
  : [addresses.TUSD, toToken.address];
const routerAmounts = await routerContract.getAmountsOut(oneUnit, path);
const rate = ethers.formatUnits(routerAmounts[1], 18);
setExchangeRate(...);
```

### Manual Mode — Pure Internal Pairs (LCX, YTC, USDC, USDT)

```javascript
// Uses YapitSwap's internal calcOutAmount
let toValue = await swapContract.calcOutAmount(
  fromToken.address, toToken.address, '1000000000000000000'  // 1 unit in wei
);
setExchangeRate(ethers.formatUnits(toValue, 18));
```

---

## 13. Slippage Tolerance

**File:** `app/home/components/hooks/SlippageSettings.jsx`

### What Is Slippage?

Because DEX prices change between quote and execution (due to other transactions), a **minimum output amount** (`amountOutMin`) is specified. If the actual output falls below this minimum, the transaction reverts on-chain.

### Slippage State

```javascript
const [slippagevalue, setSlippagevalue] = useState("auto");  // "auto" or numeric %
const [isSlippage, setIsSlippage]       = useState(false);
```

`isSlippage = true` is set for tokens with `slipToken: true` (ARK, USDA, GOT — tokens that charge their own internal transfer fees).

### Slippage Recalculation

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `pancakeSwap()`

```javascript
if (isSlippage) {
  const currentReceiveAmount = Number(ethers.formatUnits(amountOutMin, toDecimals));
  
  // Apply slippage: reduce minimum accepted output
  const finalAmountNumber = currentReceiveAmount - (currentReceiveAmount * slippagevalue / 100);
  
  // Re-encode with full precision
  const finalAmountString = finalAmountNumber.toFixed(toDecimals);
  amountOutMin = ethers.parseUnits(finalAmountString, toDecimals);
}
```

### Example

```
receiveAmount  = 1000 ARK
slippagevalue  = 0.5  (0.5%)
finalAmount    = 1000 - (1000 × 0.5 / 100) = 1000 - 5 = 995 ARK

amountOutMin   = 995 ARK in wei
```

If the actual output is 996 ARK → transaction succeeds.  
If the actual output is 994 ARK → transaction reverts with `INSUFFICIENT_OUTPUT_AMOUNT`.

---

## 14. Fee-on-Transfer Tokens (slipToken)

Some tokens (ARK, USDA, GOT) implement a **transfer tax** — a percentage of every transfer is burned or sent to a treasury. Standard swap functions fail with these tokens because the router expects to receive exactly `amountIn`, but the token delivers less.

PancakeSwap provides special variants for this:

### Standard vs FoT Functions

| Scenario              | Standard Function                         | FoT Function                                                  |
|-----------------------|-------------------------------------------|---------------------------------------------------------------|
| BNB → Token           | `swapExactETHForTokens`                   | `swapExactETHForTokensSupportingFeeOnTransferTokens`          |
| Token → BNB           | `swapExactTokensForETH`                   | `swapExactTokensForETHSupportingFeeOnTransferTokens`          |
| Token → Token         | `swapExactTokenForTokens`                 | `swapExactTokensForTokensSupportingFeeOnTransferTokens`       |

### Selection Logic in `pancakeSwap()`

```javascript
// File: app/home/components/hooks/useDexSwapLogic.js

if (!isSlippage) {
  // Standard path
  if (fromToken.isCoin && !toToken.isCoin)
    swapTx = await swapContract.swapExactETHForTokens(...);
  else if (!fromToken.isCoin && toToken.isCoin)
    swapTx = await swapContract.swapExactTokensForETH(...);
  else
    swapTx = await swapContract.swapExactTokenForTokens(...);
}

if (isSlippage) {
  // Recalculate amountOutMin with slippage first
  amountOutMin = recalculate(receiveAmount, slippagevalue);

  // FoT path
  if (fromToken.isCoin && !toToken.isCoin)
    swapTx = await swapContract.swapExactETHForTokensSupportingFeeOnTransferTokens(...);
  else if (!fromToken.isCoin && toToken.isCoin)
    swapTx = await swapContract.swapExactTokensForETHSupportingFeeOnTransferTokens(...);
  else
    swapTx = await swapContract.swapExactTokensForTokensSupportingFeeOnTransferTokens(...);
}
```

Note: These functions are **called on the YapitSwap contract**, which internally forwards them to PancakeRouter. YapitSwap acts as a middleware, collecting the platform fee before passing the net amount to PancakeRouter.

---

## 15. Swap Execution Routing

**File:** `app/home/components/hooks/useSwapLogic.js` → `Dexswap()`  
**File:** `app/home/components/hooks/useDexSwapLogic.js` → `pancakeSwap()`

### Full Execution Parameters

```javascript
await pancakeSwap({
  fromToken,            // { address, decimals, isCoin, slipToken, ... }
  toToken,              // { address, decimals, isCoin, slipToken, ... }
  amount,               // sendAmount (string, human-readable)
  signer,               // ethers.Signer from wagmi
  ownerAddress,         // addresses object (SWAP_CONTRACT, etc.)
  abis,                 // ABI objects
  receiveAmount,        // quoted output amount (string)
  userAddress,          // connected wallet address
  isSlippage,           // boolean — use FoT functions?
  slippagevalue,        // numeric % or "auto"
  path: apiMultiPath,   // multi-hop path array from liquidityCheck (or undefined)
  fromBalance,          // user's current balance (for BNB max estimation)
});
```

### Path Passed to Router

```javascript
const defaultPath = [fromToken.address, toToken.address];
// Override with multi-hop path if available
const path = (Array.isArray(apiPath) && apiPath.length) ? apiPath : defaultPath;
```

### Deadline

```javascript
const deadline = Math.floor(Date.now() / 1000) + 60 * 3;  // 3 minutes from now
```

Transactions that aren't mined within 3 minutes are automatically rejected by the router.

### Token Approval (ERC20 only)

Before any ERC20 → Token or ERC20 → BNB swap, the YapitSwap contract must be approved to spend the user's tokens:

```javascript
const tokenContract = new Contract(fromToken.address, abis.TOKEN_ABI, signer);
const allowance = await tokenContract.allowance(userAddress, ownerAddress.SWAP_CONTRACT);

if (Number(allowance) < Number(amountInMin)) {
  await (await tokenContract.approve(ownerAddress.SWAP_CONTRACT, amountInMin)).wait();
}
```

BNB (`isCoin: true`) does not need approval — it is sent as `{ value: amountIn }` in the transaction.

---

## 16. BNB Gas Estimation (`maxButton`)

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `maxButton()`

When the user's balance equals or is very close to the input amount for a BNB swap, the project prevents "out of gas" failures by deducting estimated gas cost:

```javascript
const maxButton = async (frombalance) => {
  const provider = new ethers.BrowserProvider(window.ethereum);
  const feeData  = await provider.getFeeData();
  const gasPrice = feeData.gasPrice ?? 0n;
  const gasLimit = 21000000n;                          // conservative upper bound

  const feeWei     = gasPrice * gasLimit;
  const fromWei    = ethers.parseEther(String(frombalance || '0'));
  const fromMaxWei = fromWei > feeWei ? fromWei - feeWei : 0n;

  return ethers.formatEther(fromMaxWei);
};
```

This is triggered when:
```javascript
let trimBalance = await truncateTo6Decimals(fromBalance);
if (trimBalance <= amount) {
  const maxvalue = await maxButton(fromBalance);
  value = ethers.parseUnits(String(maxvalue), fromDecimals);
}
```

### `truncateTo6Decimals()`

```javascript
function truncateTo6Decimals(value) {
  const [int, dec = ""] = value.toString().split(".");
  return dec.length > 8 ? `${int}.${dec.slice(0, 8)}` : value.toString();
}
```

Prevents floating-point precision issues when comparing balances with input amounts.

---

## 17. API Endpoints Involved in Pricing

**Source:** `app/home/components/hooks/api/swapapi.js`  
**HTTP client:** `app/config/DataServices.jsx` (wraps `axios` with auth headers)

| Endpoint                    | Method | React Query Key            | Purpose                                           |
|-----------------------------|--------|----------------------------|---------------------------------------------------|
| `/token-list`               | GET    | `["get-currency"]`         | Fetch supported tokens and metadata               |
| `/fetch-multi-path-address` | POST   | (mutation, no cache key)   | Resolve multi-hop swap paths for a token pair     |
| `/pair-list`                | GET    | `["pair-list"]`            | Fetch all known trading pairs from backend        |
| `/store-swap`               | POST   | invalidates swap-history   | Record completed swap in backend DB               |
| `/swap-history`             | GET    | `["get-swap-history", ...]`| Paginated swap transaction history                |
| `/profile`                  | GET    | `["get-user-active", addr]`| Pre-swap session validation                       |

### `/fetch-multi-path-address` in Detail

**Mutation hook:** `useMultiSwapPair()`

```javascript
export const useMultiSwapPair = () => {
  return useMutation({
    mutationFn: async (data) => {
      return await postRequest("/fetch-multi-path-address", data);
    },
  });
};
```

**Request:**
```json
POST /fetch-multi-path-address
{
  "from_token_symbol": "ARK",
  "to_token_symbol": "ASTER"
}
```
> Note: `WBNB` is translated to `BNB` before sending:
> ```javascript
> from_token_symbol: fromSymbol === "WBNB" ? "BNB" : fromSymbol
> ```

**Response:**
```json
[
  ["0xCae117ca6Bc8A341D2E7207F30E180f0e5618B9D", "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", "0x000Ae314E2A2172a039B26378814C252734f556A"]
]
```

The backend (CMS) maintains a database of curated multi-hop paths. The frontend validates each returned path on-chain via `router.getAmountsOut()`.

---

## 18. End-to-End Pricing Flow Diagram

```
User selects fromToken / toToken
             │
             ▼
    fetchStaticData()
    [useSwapLogic.js]
             │
             ├─ swapContract.activePriceFeed(nativeTokenAddr)
             │       │
             │   returns 0n ──────────────────────────────────────────┐
             │       │                                                 │ DEX MODE
             │   returns 1n → Manual Mode                             │
             │                                                         ▼
             │                                           liquidityCheck()
             │                                           [useDexSwapLogic.js]
             │                                                │
             │                                        factory.getPair(A, B)
             │                                                │
             │                                   ┌───────────┴────────────────┐
             │                               Direct Pair                 No Direct Pair
             │                                   │                            │
             │                            getReserves()         POST /fetch-multi-path-address
             │                            availableLiquidity    │
             │                                   │              router.getAmountsOut(1, path[])
             │                                   │              → pick bestPath
             │                                   │              getReserves() per hop
             │                                   │
             │                         setExchangeRate() via router.getAmountsOut(1 unit, path)
             │
             ▼
User types sendAmount
             │
        600ms debounce
             │
             ▼
    getDexSwapDetails()
    [useDexSwapLogic.js]
             │
             ├─ swapContract.getPlatformFee(amountInWei)
             │       └─ effectiveAmount = fee[0]  (net after platform fee)
             │
             ├─ router.getAmountsOut(effectiveAmount, path)
             │       └─ finalAmountOut = amountsOut[last]
             │
             ├─ calculatePriceImpact() or calculateMultiHopPriceImpact()
             │
             └─ return { receiveAmount, feeAmount, priceImpact, message }
                         │
                         ▼
              setReceiveAmount(), setPriceImpact(), setBtnMessage()
             │
             ▼
User clicks "Swap Now"
             │
             ├─ Session check: GET /profile
             ├─ Token approval if needed: ERC20.approve(SWAP_CONTRACT, amountIn)
             │
             ▼
        pancakeSwap()
        [useDexSwapLogic.js]
             │
             ├─ swapContract.pancakeRouter() → get live router address
             ├─ Select function: standard vs FoT, BNB vs ERC20
             ├─ Apply slippage to amountOutMin if isSlippage
             │
             └─ swapContract.swapExact[ETH|Token]For[Token|ETH][SupportingFeeOnTransfer]
                     │  (YapitSwap collects platform fee, forwards net to PancakeRouter)
                     │
                     ▼
              PancakeRouter executes trade on-chain
                     │
                     ▼
              swapTx.wait()  ← waits for BSC block confirmation
                     │
                     ▼
              POST /store-swap  ← log in backend DB
                     │
                     ▼
              fetchBalances()   ← refresh UI balances
```

---

## 19. Error Conditions and Recovery

### On-Chain Errors

| Error String / Code                   | Cause                                                      | UI Response                                                                 |
|---------------------------------------|------------------------------------------------------------|-----------------------------------------------------------------------------|
| `INSUFFICIENT_OUTPUT_AMOUNT`          | Price moved beyond slippage tolerance                      | `toast.error("Swap failed: output less than expected... increase slippage")`|
| `Pancake: K`                          | Invariant violation (flash loan / manipulation)            | Same as above                                                               |
| `0x08c379a0` (revert data)            | Generic on-chain revert                                    | Same as above                                                               |
| `error.code === 4001`                 | User rejected MetaMask popup                              | `toast.error("User denied transaction signature!")`                         |
| `ACTION_REJECTED`                     | Wallet rejected                                            | Same as above                                                               |
| `info.error.code === 4001`            | Nested rejection from provider                            | Same as above                                                               |

### Pricing/Quote Errors

| Scenario                              | Detection                                          | UI Response                          |
|---------------------------------------|----------------------------------------------------|--------------------------------------|
| No direct pair, no multi-hop          | `liquidityCheck` returns `hasPair: false`          | `setBtnMessage("No Pair Found")`, input disabled |
| Direct pair exists, pool empty        | `availableLiquidity < toAmount`                    | `setBtnMessage("Insufficient Liquidity")` |
| `getAmountsOut` reverts               | catch block in `getDexSwapDetails`                 | Returns `message: "Insufficient Liquidity"` |
| `effectiveAmount <= 0n`               | After fee deduction leaves nothing                 | Returns `message: "Invalid Amount"` |
| Multi-hop API returns empty array     | `pathsFromApi.length === 0`                        | `hasPair: false` → "No Pair Found"  |
| All multi-hop paths fail `getAmountsOut` | `bestPath === null` after loop               | `hasPair: false` → "No Pair Found"  |

### Gas / BNB Errors

| Scenario                              | Detection                                      | UI Response                                |
|---------------------------------------|------------------------------------------------|--------------------------------------------|
| User balance ≈ input amount (BNB)     | `trimBalance <= amount`                        | Auto-deduct gas estimate via `maxButton()` |
| Not enough BNB for gas after deduction| `value <= 0n`                                 | `toast.error("Insufficient gas fee amount")` |

---

## Appendix: Contract Function Signatures Used

```solidity
// YapitSwap (app/AhdfBdkfI/abi.json)
function activePriceFeed(address token) external view returns (uint8)
function getPlatformFee(uint256 amount) external view returns (uint256, uint256)
function platformFee() external view returns (uint256)
function pancakeRouter() external view returns (address)
function calcOutAmount(address from, address to, uint256 amountIn) external view returns (uint256)
function stakesFeed(address token) external view returns (uint256, uint256, uint256, uint256)

function swapExactETHForTokens(address router, uint256 amountOutMin, address[] path, address to, uint256 deadline) external payable
function swapExactTokensForETH(address router, uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) external
function swapExactTokenForTokens(address router, uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) external
function swapExactETHForTokensSupportingFeeOnTransferTokens(address router, uint256 amountOutMin, address[] path, address to, uint256 deadline) external payable
function swapExactTokensForETHSupportingFeeOnTransferTokens(address router, uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) external
function swapExactTokensForTokensSupportingFeeOnTransferTokens(address router, uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) external

// PancakeRouter (app/AhdfBdkfI/routerAbi.json)
function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts)

// PancakeFactory (app/AhdfBdkfI/factoryAbi.json)
function getPair(address tokenA, address tokenB) external view returns (address pair)

// PancakePair (app/AhdfBdkfI/pairAbi.json)
function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
function token0() external view returns (address)

// ERC20 Token (app/AhdfBdkfI/usdcAbi.json)
function allowance(address owner, address spender) external view returns (uint256)
function approve(address spender, uint256 amount) external returns (bool)
function balanceOf(address account) external view returns (uint256)
function decimals() external view returns (uint8)
```

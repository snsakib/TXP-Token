# TXP Token Swap Integration — Technical Documentation

## Overview

This document describes **exactly how to integrate TXP** (Triple X POS Token) into the existing swap
infrastructure so users can trade:

- **TXP ↔ LCX** (manual price, internal)
- **TXP ↔ YTC** (manual price, internal)
- **TXP ↔ WBNB** (manual price → PancakeRouter BNB rate)
- **TXP ↔ USDT / USDC** (manual price → internal USD conversion)
- **TXP ↔ DEX tokens** (ARK, FIST, USDA, GOT, CAKE, LINK, ASTER via PancakeRouter passthrough)

The **TXPSwap contract** (`TXP/TXPSwap.sol`) is already deployed and mirrors YapitSwap's full
function set. This guide covers every file change, contract call, and data-flow modification
needed to wire TXP into the UI.

---

## Architecture Difference: YapitSwap vs TXPSwap

| Feature                           | YapitSwap (`app/AhdfBdkfI/abi.json`)       | TXPSwap (`app/AhdfBdkfI/TXPSwapABI.json`)                      |
|-----------------------------------|--------------------------------------------|---------------------------------------------------|
| Supported native tokens           | LCX, YTC                                   | **TXP**, LCX, YTC                                 |
| Manual price pairs                | LCX ↔ YTC, LCX ↔ USDT, etc.               | TXP ↔ LCX, TXP ↔ YTC, LCX ↔ YTC                 |
| DEX passthrough                   | ✓                                          | ✓ (identical function signatures)                 |
| Auto-staking on swap              | ✓ (output goes to staking contract)        | ✗ (output goes **directly** to recipient)         |
| Fee mechanism                     | `platformFee` → treasury                   | `platformFee` → treasury (same)                   |
| `_internalSupportingTransactions` | ✓                                          | ✓ (handles FoT tokens)                            |
| Contract key (`swap()`)           | `swap(path, amountIn, to)`                 | `swap(path, amountIn, to)` — identical signature  |

> **Critical:** TXPSwap's `swap()` requires at least one of `path[0]` or `path[1]` to be in
> `{TXP, YTC, LCX}`. Attempting an unrelated pair (e.g., ARK ↔ USDT) through TXPSwap's `swap()`
> will revert with `"Pair not supported!"`. For those pairs, use the DEX passthrough functions.

---

## Part 1 — Contract Configuration

### 1.1 Add TXPSwap Contract Address

**File:** `app/AhdfBdkfI/contract.js`

```javascript
// app/AhdfBdkfI/contract.js
// ...existing code...

export const addresses = {
  SWAP_CONTRACT:     "0x173781931d33306Fd04C7B15941b944c41Ab0C1A", // YapitSwap (existing)
  TXP_SWAP_CONTRACT: "0x<DEPLOYED_TXP_SWAP_ADDRESS>",              // ← ADD THIS
  ROUTER_CONTRACT:   "0x10ED43C718714eb63d5aA57B78B54704E256024E",
  FACTORY_CONTRACT:  "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73",
  LCASH:             "0xd5c10B78e7C274e04b213C13D2bF40F49b0006D0",
  YTC:               "0x236dAE64e0174581591230fEC1F113a86B75fFa2",
  TXP:               "0x<DEPLOYED_TXP_TOKEN_ADDRESS>",              // ← ADD THIS
  TUSD:              "0x55d398326f99059fF775485246999027B3197955",
  WBNB:              "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
  ARK:               "0xCae117ca6Bc8A341D2E7207F30E180f0e5618B9D",
  FIST:              "0xC9882dEF23bc42D53895b8361D0b1EDC7570Bc6A",
  ASTER:             "0x000Ae314E2A2172a039B26378814C252734f556A",
  USDA:              "0x17EAfd08994305D8AcE37EfB82F1523177eC70EE",
  GOT:               "0x701add4311E85c1f9C1549319fe2c476bc8a1b8b",
  USDC:              "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",
};
// ...existing code...
```

### 1.2 Import TXPSwap ABI

**File:** `app/AhdfBdkfI/contract.js`

```javascript
// app/AhdfBdkfI/contract.js
import SWAP_ABI       from "./abi.json";
import TXP_SWAP_ABI   from "./TXPSwapABI.json";    // ← ADD
import TXP_TOKEN_ABI  from "./TXPTokenABI.json";   // ← ADD
import TOKEN_ABI      from "./usdcAbi.json";
import ROUTER_ABI     from "./routerAbi.json";
import FACTORY_ABI    from "./factoryAbi.json";
import PAIR_ABI       from "./pairAbi.json";

export const abis = {
  SWAP_ABI,
  TXP_SWAP_ABI:  TXP_SWAP_ABI.abi,   // ← ADD (Hardhat artifact wraps ABI in .abi)
  TXP_TOKEN_ABI: TXP_TOKEN_ABI.abi,  // ← ADD
  TOKEN_ABI,
  ROUTER_ABI,
  FACTORY_ABI,
  PAIR_ABI,
};
```

---

## Part 2 — Token List Configuration

### 2.1 Add TXP to the Manual Token List

TXP uses **manual pricing** just like LCX and YTC. Add it to `tokenList` (the "default" list shown
when a native token is selected).

**File:** `app/home/components/Swap.jsx`

```jsx
// app/home/components/Swap.jsx
import txpIcon from '../../../public/assets/images/TXP.png'; // add TXP icon

// ...existing tokenList...
const tokenList = [
  // ...existing entries (USDC, YTC, LCX, USDT, WBNB)...
  {
    name:      "TXP",
    symbol:    "TXP",
    address:   CONFIG.addresses.TXP,
    icon:      txpIcon,
    decimals:  18,
    type:      "manual",
    slipToken: false,
    isCoin:    false,
    abi:       TOKEN_ABI,   // TXPToken ABI for allowance/approve calls
  },
];

// tokenLists (secondary/DEX list) should also include TXP so it appears
// when a DEX token is selected as counterpart:
const tokenLists = [
  ...tokenList,   // includes TXP from above
  // ...existing DEX tokens (ARK, FIST, USDA, GOT, CAKE, LINK, ASTER)...
];
```

> **Why `type: "manual"`?** TXPSwap's `activePriceFeed[TXP]` is initialized to `PriceFeed.MANUAL`
> in the constructor (`TXP/TXPSwap.sol` line 135). The UI must treat TXP as a manual token so that
> `isNativeToken()` returns `true` for TXP addresses, routing execution to TXPSwap.

---

## Part 3 — `isNativeToken` Helper Extension

The helper `isNativeToken()` in `useSwapLogic.js` determines which contract to use. Currently it
only recognizes LCX and YTC. **Add TXP.**

**File:** `app/home/components/hooks/useSwapLogic.js`

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...existing code...

const isNativeToken = (addr) =>
  addr?.toLowerCase() === addresses.LCASH?.toLowerCase() ||
  addr?.toLowerCase() === addresses.YTC?.toLowerCase()   ||
  addr?.toLowerCase() === addresses.TXP?.toLowerCase();   // ← ADD TXP

// ...existing code...
```

---

## Part 4 — Contract Routing: Which Swap Contract to Use

The core decision logic is: **if either token in the pair is TXP, use TXPSwap; otherwise use
YapitSwap.**

### 4.1 Add a `isTxpPair` Helper

**File:** `app/home/components/hooks/useSwapLogic.js`

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...existing code...

// Returns true if either token is TXP — must route to TXPSwap
const isTxpPair = (fromAddr, toAddr) =>
  fromAddr?.toLowerCase() === addresses.TXP?.toLowerCase() ||
  toAddr?.toLowerCase()   === addresses.TXP?.toLowerCase();

// ...existing code...
```

### 4.2 `fetchStaticData` — Detect Price Feed on TXPSwap

TXPSwap has its **own** `activePriceFeed` mapping. For TXP pairs, you must query TXPSwap, not
YapitSwap.

**File:** `app/home/components/hooks/useSwapLogic.js` → `fetchStaticData()`

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...existing code inside fetchStaticData()...

const fetchStaticData = async () => {
  if (!signer || !fromToken || !toToken) return;

  try {
    // ── Step 1: Choose the correct swap contract ──────────────────────────────
    const isTxp = isTxpPair(fromToken.address, toToken.address);

    const swapContractAddress = isTxp
      ? addresses.TXP_SWAP_CONTRACT
      : addresses.SWAP_CONTRACT;

    const swapContractAbi = isTxp
      ? abis.TXP_SWAP_ABI
      : abis.SWAP_ABI;

    const swapContract   = new Contract(swapContractAddress, swapContractAbi, signer);
    const routerContract = new Contract(addresses.ROUTER_CONTRACT, abis.ROUTER_ABI, signer);

    // ── Step 2: Determine targetAddress (the "native" token) ──────────────────
    let targetAddress = '';
    if (isNativeToken(fromToken.address)) targetAddress = fromToken.address;
    else if (isNativeToken(toToken.address)) targetAddress = toToken.address;

    // ── Step 3: Query activePriceFeed on the correct contract ─────────────────
    const activestatus = targetAddress
      ? await swapContract.activePriceFeed(targetAddress)
      : 1n; // default to DEX mode if no native token

    // ...rest of existing fetchStaticData logic unchanged...
    // isSpecialMode, liquidityCheck, setActiveTokens, etc. all work the same

  } catch (err) {
    console.error("fetchStaticData error:", err);
  }
};
// ...existing code...
```

---

## Part 5 — Amount Calculation for TXP Pairs

### 5.1 Manual Path Calculation (`calcOutAmount`)

When `isSpecialMode = false` (manual mode) and the pair involves TXP, call `calcOutAmount` on
**TXPSwap**, not YapitSwap. The function signature is identical.

**File:** `app/home/components/hooks/useSwapLogic.js` — inside `calculate()` / debounce effect

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...existing code inside calculate()...

const calculate = async () => {
  if (!signer || !sendAmount || parseFloat(sendAmount) <= 0) return;

  const isTxp = isTxpPair(fromToken.address, toToken.address);

  const swapContract = new Contract(
    isTxp ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT,
    isTxp ? abis.TXP_SWAP_ABI          : abis.SWAP_ABI,
    signer
  );

  if (!isSpecialMode) {
    // Manual price mode — identical call, different contract instance
    const amountInWei = ethers.parseUnits(sendAmount, fromToken.decimals);

    const amountOut              = await swapContract.calcOutAmount(
      fromToken.address,
      toToken.address,
      amountInWei
    );
    const [netAmount, feeAmount] = await swapContract.getPlatformFee(amountInWei);

    setReceiveAmount(ethers.formatUnits(amountOut, toToken.decimals));
    setCalculatedFeeAmount(ethers.formatUnits(feeAmount, fromToken.decimals));

    // Liquidity check against TXPSwap contract balance
    await checkManualLiquidity(swapContract);
  } else {
    // DEX path — getDexSwapDetails already uses pancakeRouter, no contract change needed
    // BUT pass the correct swapContract for getPlatformFee
    await getDexSwapDetailsWithContract(swapContract);
  }
};
// ...existing code...
```

### 5.2 `getPlatformFee` on TXPSwap for DEX Quotes

`getDexSwapDetails` in `useDexSwapLogic.js` calls `swapContract.getPlatformFee()` to get the
effective amount before routing to PancakeRouter. Pass the TXPSwap contract instance when needed.

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `getDexSwapDetails()`

```javascript
// app/home/components/hooks/useDexSwapLogic.js
// ...existing function signature...

export async function getDexSwapDetails({
  signer,
  sendAmount,
  fromToken,
  toToken,
  addresses,
  abis,
  checkMultiPairApi,
  isTxpPair,          // ← ADD this param (boolean)
}) {
  // ── Determine which swap contract to call for platformFee ─────────────────
  const swapContractAddress = isTxpPair
    ? addresses.TXP_SWAP_CONTRACT
    : addresses.SWAP_CONTRACT;

  const swapContractAbi = isTxpPair
    ? abis.TXP_SWAP_ABI
    : abis.SWAP_ABI;

  const swapContract = new Contract(swapContractAddress, swapContractAbi, signer);

  // ── Step: get router address (both contracts expose .pancakeRouter()) ──────
  const ROUTER_ADDRESS = await swapContract.pancakeRouter();
  const pancakeRouter  = new Contract(ROUTER_ADDRESS, abis.ROUTER_ABI, signer);

  // ── Step: deduct platform fee ──────────────────────────────────────────────
  const amountInWei     = ethers.parseUnits(String(sendAmount), fromToken.decimals);
  const fee             = await swapContract.getPlatformFee(amountInWei);
  const effectiveAmount = fee[0]; // net amount after fee

  // ...rest of getDexSwapDetails unchanged (liquidityCheck, getAmountsOut, etc.)...
}
```

---

## Part 6 — Swap Execution: TXP Manual Path

TXPSwap's `swap()` function is **signature-identical** to YapitSwap's. The only change is the
contract address. Both contracts:

1. Validate the path contains at least one of `{TXP, YTC, LCX}`
2. Call `getPlatformFee` to deduct the platform fee
3. Transfer input tokens (or BNB) from user to contract + treasury
4. Call `calcOutAmount` using `manualPrice` mappings
5. Transfer output directly to recipient

### 6.1 Modify `swapFunction` to Route to TXPSwap

**File:** `app/home/components/hooks/useSwapLogic.js` → `swapFunction()`

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...existing swapFunction...

const swapFunction = async (e, receiveAmount) => {
  e?.preventDefault();

  // ── Session check (unchanged) ────────────────────────────────────────────
  const result = await queryClient.fetchQuery({
    queryKey: ["get-user-active", connectedAddress],
    queryFn: () => getRequest("/profile")
  });
  if (!result?.data?.status) return;

  try {
    setIsSwapping(true);

    // ── Input validation (unchanged) ─────────────────────────────────────────
    if (parseFloat(sendAmount) > parseFloat(fromBalance)) {
      toast.error("Insufficient Balance"); return;
    }
    if (isNativeToken(fromToken.address) === isNativeToken(toToken.address)) {
      toast.error("Invalid Pair"); return;
    }

    const amountInWei = ethers.parseUnits(sendAmount, fromToken.decimals);

    // ── NEW: Choose contract based on whether TXP is involved ────────────────
    const isTxp = isTxpPair(fromToken.address, toToken.address);

    const swapContract = new Contract(
      isTxp ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT,
      isTxp ? abis.TXP_SWAP_ABI          : abis.SWAP_ABI,
      signer
    );

    // ── Token approval (unchanged logic, different contract to approve) ───────
    const fromIsWBNB     = fromToken.symbol === "WBNB";
    const contractToApprove = isTxp
      ? addresses.TXP_SWAP_CONTRACT
      : addresses.SWAP_CONTRACT;

    if (!fromIsWBNB) {
      const tokenContract = new Contract(fromToken.address, fromToken.abi, signer);
      const allowance     = await tokenContract.allowance(connectedAddress, contractToApprove);

      if (allowance < amountInWei) {
        toast.loading("Approving token...");
        await (await tokenContract.approve(contractToApprove, amountInWei)).wait();
        toast.dismiss();
        toast.success("Approved!");
      }
    }

    // ── Execute on-chain swap (identical call signature) ──────────────────────
    toast.loading("Swapping...");

    const path = [fromToken.address, toToken.address];
    let tx;

    if (fromIsWBNB) {
      tx = await swapContract.swap(path, amountInWei, connectedAddress, {
        value: amountInWei
      });
    } else {
      tx = await swapContract.swap(path, amountInWei, connectedAddress);
    }

    await tx.wait();
    toast.dismiss();

    // ── Record in backend (unchanged) ─────────────────────────────────────────
    const feeRaw     = await swapContract.platformFee();
    const feePercent = Number(ethers.formatUnits(feeRaw, 18));

    const apiData = {
      from_token_symbol: fromToken.symbol === "WBNB" ? "BNB" : fromToken.symbol,
      to_token_symbol:   toToken.symbol   === "WBNB" ? "BNB" : toToken.symbol,
      from_amount:       sendAmount,
      to_amount:         receiveAmount,
      user_address:      connectedAddress,
      fee:               feePercent,
      transaction_hash:  tx.hash,
      multiPathStatus:   0
    };

    // Staking integration (unchanged)
    if (stakeMessage?.stakemessage) {
      const stakedata = { /* ...existing stakedata... */ };
      await Promise.all([
        stakeMutation.mutateAsync(stakedata),
        swaptokenMutation.mutateAsync(apiData)
      ]);
    } else {
      await swaptokenMutation.mutateAsync(apiData);
    }

    toast.success("Swap successful!");
    setSendAmount("");
    setReceiveAmount("");
    setCalculatedFeeAmount("0");
    fetchBalances();

  } catch (error) {
    toast.dismiss();
    if (error.code === 4001 || error.code === "ACTION_REJECTED") {
      toast.error("User denied transaction signature!");
    } else {
      toast.error("Swap failed. Please try again.");
      console.error("swapFunction error:", error);
    }
  } finally {
    setIsSwapping(false);
  }
};
```

---

## Part 7 — Swap Execution: TXP DEX Passthrough Path

When TXP is swapped against a DEX token (e.g., **TXP → ARK** or **ASTER → TXP**), the route goes
through TXPSwap's PancakeRouter passthrough functions. These are **identical in signature** to
YapitSwap's. The only change is the contract address in `Dexswap()`.

### 7.1 Modify `Dexswap` to Pass Correct Contract

**File:** `app/home/components/hooks/useSwapLogic.js` → `Dexswap()`

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...existing Dexswap()...

const Dexswap = async () => {
  const result = await queryClient.fetchQuery({
    queryKey: ["get-user-active", connectedAddress],
    queryFn: () => getRequest("/profile")
  });
  if (!result?.data?.status) return;

  try {
    setIsSwapping(true);

    if (btnMessage === "No Pair Found" || btnMessage === "Insufficient Liquidity") return;

    // ── NEW: pass TXP flag to pancakeSwap ────────────────────────────────────
    const isTxp = isTxpPair(fromToken.address, toToken.address);

    const dataTNX = await pancakeSwap({
      fromToken,
      toToken,
      amount:      sendAmount,
      signer,
      ownerAddress: {
        // pancakeSwap() reads ownerAddress.SWAP_CONTRACT for approve + swap calls
        SWAP_CONTRACT: isTxp
          ? addresses.TXP_SWAP_CONTRACT
          : addresses.SWAP_CONTRACT,
        ...addresses
      },
      abis: {
        ...abis,
        // Override SWAP_ABI so pancakeSwap() instantiates the right contract
        SWAP_ABI: isTxp ? abis.TXP_SWAP_ABI : abis.SWAP_ABI,
      },
      userAddress:   connectedAddress,
      receiveAmount,
      isSlippage,
      slippagevalue,
      path:          apiMultiPath,
      fromBalance,
    });

    // ...rest of Dexswap() unchanged (POST /store-swap, toast, fetchBalances)...
  } catch (error) {
    // ...existing error handling...
  } finally {
    setIsSwapping(false);
  }
};
```

### 7.2 `pancakeSwap` Already Handles TXPSwap Transparently

Since `pancakeSwap()` in `useDexSwapLogic.js` uses `ownerAddress.SWAP_CONTRACT` for all
contract instantiation and approvals, **no changes are needed inside `pancakeSwap()`** itself —
it will automatically call TXPSwap when `ownerAddress.SWAP_CONTRACT` is set to
`TXP_SWAP_CONTRACT`.

The relevant code paths that already work correctly:

```javascript
// useDexSwapLogic.js — these all use ownerAddress.SWAP_CONTRACT dynamically

// BNB → TXP (non-slippage)
swapTx = await swapContract.swapExactETHForTokens(
  ROUTER_ADDRESS, amountOutMin, path, userAddress, deadline, { value }
);

// TXP → BNB (non-slippage)
await tokenContract.approve(ownerAddress.SWAP_CONTRACT, amountInMin); // TXPSwap address
swapTx = await swapContract.swapExactTokensForETH(
  ROUTER_ADDRESS, amountInMin, amountOutMin, path, userAddress, deadline
);

// TXP → ARK (Token→Token, non-slippage)
await tokenContract.approve(ownerAddress.SWAP_CONTRACT, amountInMin); // TXPSwap address
swapTx = await swapContract.swapExactTokenForTokens(
  ROUTER_ADDRESS, amountInMin, amountOutMin, path, userAddress, deadline
);

// TXP → USDA (Token→Token, slippage/FoT)
swapTx = await swapContract.swapExactTokensForTokensSupportingFeeOnTransferTokens(
  ROUTER_ADDRESS, amountInMin, amountOutMin, path, userAddress, deadline
);
```

---

## Part 8 — TXPSwap Internal Flow: What Happens On-Chain

### 8.1 Manual Swap: TXP ↔ LCX

```
User calls TXPSwap.swap([TXP_ADDR, LCX_ADDR], amountIn, userAddress)
│
├── Validates: path[0] == TXP ✓ (satisfies "Pair not supported!" check)
├── Validates: fromToken != WBNB → msg.value must be 0 ✓
│
├── Calls this.getPlatformFee(amountIn):
│   ├── feeAmount = amountIn × platformFee / 1e20
│   └── netAmount = amountIn - feeAmount
│
├── Transfers:
│   ├── IERC20(TXP).safeTransferFrom(user, treasury, feeAmount)
│   └── IERC20(TXP).safeTransferFrom(user, address(this), netAmount)
│
├── Validates activePriceFeed[TXP] == MANUAL ✓
│
├── Calls this.calcOutAmount(TXP, LCX, netAmount):
│   ├── priceIn  = manualPrice[TXP]  // e.g. 1e16 (= $0.01)
│   ├── priceOut = manualPrice[LCX]  // e.g. 1e16 (= $0.01)
│   └── amountOut = netAmount × priceIn / priceOut
│        → Since both are $0.01, ratio is 1:1 → amountOut ≈ netAmount
│
├── Checks: IERC20(LCX).balanceOf(address(this)) >= amountOut ✓
├── Transfers: IERC20(LCX).safeTransfer(user, amountOut)
│
└── Emits: TXPSwapped(user, TXP, LCX, netAmount, amountOut, fee, timestamp)
```

### 8.2 Manual Swap: TXP ↔ WBNB (BNB)

```
User calls TXPSwap.swap([TXP_ADDR, WBNB_ADDR], amountIn, userAddress)
│                                                             msg.value = 0 (TXP is ERC20)
├── Fee deduction from TXP:
│   ├── safeTransferFrom(user, treasury, feeAmount)
│   └── safeTransferFrom(user, address(this), netAmount)
│
├── Calls calcOutAmount(TXP, WBNB, netAmount):
│   ├── _tokenOut == WBNB → DEX-based BNB conversion branch:
│   │   ├── usdValue = netAmount × PRECISION / getPrice(TXP)
│   │   │            = netAmount × 1e18 / 1e16 = netAmount × 100  (USD value in 1e18)
│   │   ├── path = [USDT, WBNB]
│   │   └── amountOut = pancakeRouter.getAmountsOut(usdValue, [USDT, WBNB])[1]
│   └── Returns BNB amount at current market rate
│
├── Checks: address(this).balance >= amountOut
└── Transfers: payable(user).transfer(amountOut)
```

### 8.3 DEX Passthrough: TXP → ARK via PancakeRouter

```
User calls TXPSwap.swapExactTokenForTokens(
  ROUTER_ADDRESS, amountIn, amountOutMin,
  [TXP_ADDR, WBNB_ADDR, ARK_ADDR], userAddress, deadline
)
│
├── _internalSupportingTransactions(user, TXP, ROUTER_ADDRESS, amountIn):
│   ├── before = IERC20(TXP).balanceOf(address(this))
│   ├── IERC20(TXP).safeTransferFrom(user, address(this), amountIn)
│   ├── delta = balanceOf(this) - before      // handles FoT tokens
│   ├── (netAmount, fee) = getPlatformFee(delta)
│   ├── IERC20(TXP).safeTransfer(treasury, fee)
│   └── IERC20(TXP).safeIncreaseAllowance(ROUTER_ADDRESS, netAmount)
│
├── PancakeRouter02.swapExactTokensForTokens(
│     netAmount, amountOutMin,
│     [TXP, WBNB, ARK], userAddress, deadline
│   )
│   → PancakeRouter pulls TXP from TXPSwap (via allowance set above)
│   → Swaps TXP → WBNB in Pancake pool
│   → Swaps WBNB → ARK in Pancake pool
│   → Transfers ARK directly to userAddress
│
└── Emits: TXPSwapped(user, TXP, ARK, netAmount, amountsOut[last], fee, timestamp)
```

---

## Part 9 — TXP Token Approval Flow

TXP uses the standard ERC20 `approve` + `transferFrom` pattern (see `TXP/TXPToken.sol`). There is
**no transfer tax** on TXP itself — it is a clean ERC20. Therefore:

- `slipToken: false` ✓
- `isSlippage: false` by default ✓
- Standard (non-FoT) swap functions are used for TXP-in pairs ✓

### Approval Checklist

| Swap Direction              | Token to Approve      | Spender              |
|-----------------------------|-----------------------|----------------------|
| TXP → LCX (manual)         | TXP (`TXPToken`)      | `TXP_SWAP_CONTRACT`  |
| TXP → YTC (manual)         | TXP (`TXPToken`)      | `TXP_SWAP_CONTRACT`  |
| TXP → WBNB (manual)        | TXP (`TXPToken`)      | `TXP_SWAP_CONTRACT`  |
| TXP → ARK (DEX)            | TXP (`TXPToken`)      | `TXP_SWAP_CONTRACT`  |
| LCX → TXP (manual)         | LCX (standard ERC20)  | `TXP_SWAP_CONTRACT`  |
| WBNB → TXP (manual)        | **No approval** (BNB) | — (send as `value`)  |
| ARK → TXP (DEX, slipToken) | ARK                   | `TXP_SWAP_CONTRACT`  |

> Note: Because `TXPToken.sol` uses the custom `notBlacklisted` modifier on `transferFrom`,
> ensure the user address is not blacklisted before initiating a swap. The `transfer` will revert
> silently with `"TXP: address is blacklisted"`.

---

## Part 10 — `calcOutAmount` Logic for All TXP Pairs

The `calcOutAmount` function in `TXP/TXPSwap.sol` handles four price calculation branches.
Understanding these is critical for correct UI display.

```
calcOutAmount(tokenIn, tokenOut, amountIn)
│
├── Branch A: tokenIn is MANUAL and tokenOut is NOT WBNB
│   (e.g., TXP → LCX, LCX → YTC, TXP → USDT)
│   │
│   ├── priceIn  = manualPrice[tokenIn]   (1e18 USD per token, e.g. 1e16 = $0.01)
│   ├── priceOut = manualPrice[tokenOut]
│   └── amountOut = amountIn × priceIn / priceOut
│       Example: 100 TXP ($0.01 each) → LCX ($0.01 each) = 100 LCX
│
├── Branch B: tokenIn is USDT or USDC
│   (e.g., USDT → TXP)
│   │
│   └── amountOut = amountIn × getPrice(tokenOut) / PRECISION
│
│       ⚠️ manualPrice precision is set by the owner post-deploy.
│       The owner must call setPrice() with the value representing
│       "how many output tokens per 1 input token × 1e18".
│
│       Example: if 1 USDT = 100 TXP, set manualPrice[TXP] = 100e18
│
├── Branch C: tokenIn is WBNB
│   (e.g., BNB → TXP)
│   │
│   ├── path = [WBNB, USDT]
│   ├── usdValue = pancakeRouter.getAmountsOut(amountIn, [WBNB, USDT])[1]
│   └── amountOut = usdValue × getPrice(tokenOut) / PRECISION
│       Example: 1 BNB = $300 USDT → 300 × 100 TXP/USDT = 30,000 TXP
│
└── Branch D: tokenOut is WBNB
    (e.g., TXP → BNB)
    │
    ├── usdValue = amountIn × PRECISION / getPrice(tokenIn)
    │   Example: 100 TXP × 1e18 / price_of_TXP_per_USD
    ├── path = [USDT, WBNB]
    └── amountOut = pancakeRouter.getAmountsOut(usdValue, [USDT, WBNB])[1]
```

---

## Part 11 — Exchange Rate Display for TXP Pairs

In `fetchStaticData()`, the exchange rate ("1 TXP = X YTC") must be fetched from TXPSwap.

**File:** `app/home/components/hooks/useSwapLogic.js` → `fetchStaticData()`

```javascript
// app/home/components/hooks/useSwapLogic.js
// ...inside fetchStaticData(), after mode detection...

// ── Exchange Rate Calculation ──────────────────────────────────────────────

if (!isSpecialMode) {
  // Manual mode: use TXPSwap.calcOutAmount for 1 unit
  const oneUnit = ethers.parseUnits("1", fromToken.decimals);

  if (isWBNB(fromToken.address) || isWBNB(toToken.address)) {
    // WBNB path via PancakeRouter (existing logic, unchanged)
    const path = isWBNB(fromToken.address)
      ? [fromToken.address, addresses.TUSD]
      : [addresses.TUSD, toToken.address];
    const routerAmounts = await routerContract.getAmountsOut(oneUnit, path);
    setExchangeRate(ethers.formatUnits(routerAmounts[1], 18));
  } else {
    // Pure manual pairs (TXP ↔ LCX, TXP ↔ YTC, etc.)
    // swapContract is already TXPSwap because isTxpPair === true
    const toValue = await swapContract.calcOutAmount(
      fromToken.address,
      toToken.address,
      oneUnit
    );
    setExchangeRate(ethers.formatUnits(toValue, toToken.decimals));
  }
}
```

---

## Part 12 — Liquidity Check for TXP Manual Swaps

TXPSwap holds its own liquidity pool (ERC20 tokens + BNB). Before showing "Swap Now", the UI
must verify TXPSwap has enough output tokens.

**File:** `app/home/components/hooks/useSwapLogic.js` → `checkManualLiquidity()`

```javascript
// app/home/components/hooks/useSwapLogic.js

const checkManualLiquidity = async (swapContract) => {
  // swapContract is the TXPSwap instance when isTxpPair === true
  const contractAddress = isTxpPair(fromToken.address, toToken.address)
    ? addresses.TXP_SWAP_CONTRACT
    : addresses.SWAP_CONTRACT;

  const receiveAmountWei = ethers.parseUnits(
    String(receiveAmount || "0"),
    toToken.decimals
  );

  if (toToken.symbol === "WBNB") {
    // Check BNB balance of TXPSwap contract
    const contractBal = await signer.provider.getBalance(contractAddress);
    if (contractBal < receiveAmountWei) {
      setBtnMessage("Insufficient Liquidity");
      return false;
    }
  } else {
    // Check ERC20 balance of TXPSwap contract
    const tokenOut    = new Contract(toToken.address, abis.TOKEN_ABI, signer);
    const contractBal = await tokenOut.balanceOf(contractAddress);
    if (contractBal < receiveAmountWei) {
      setBtnMessage("Insufficient Liquidity");
      return false;
    }
  }

  setBtnMessage("Swap Now");
  return true;
};
```

---

## Part 13 — UI Token Dropdown Filtering

When TXP is selected as `fromToken`, the valid counterpart tokens are determined by the same
`activeTokens` logic already in place. No special filtering is required — TXPSwap's DEX passthrough
handles all cross-token pairs. However, ensure the "switch tokens" button also works correctly:

**File:** `app/home/components/Swap.jsx`

```jsx
// app/home/components/Swap.jsx
// In the "To" token dropdown — add TXP icon rendering
{activeTokens
  .filter((token) => token.symbol !== fromToken.symbol)
  .map((token) => (
    <li key={token.name}>
      <button
        onClick={() => {
          setToToken(token);
          // TXP has no transfer tax — no slippage needed
          if (token.slipToken) {
            setIsSlippage(true);
            setSlippagevalue(0.1);
          } else {
            setIsSlippage(false);
            setSlippagevalue("auto");
          }
        }}
      >
        <Image src={token.icon} alt={token.name} width={24} height={24} />
        <span>{token.symbol}</span>
      </button>
    </li>
  ))
}
```

---

## Part 14 — Swap History Display for TXP

`SwapContent.jsx` renders swap history from `GET /swap-history`. Add TXP icon to the token image
map.

**File:** `app/DeFi/swap/SwapContent.jsx`

```jsx
// app/DeFi/swap/SwapContent.jsx
import txpIcon from '../../../public/assets/images/TXP.png'; // ← ADD

const tokenImages = {
  // ...existing entries (LCX, YTC, USDT, USDC, WBNB, ARK, ...)...
  TXP: txpIcon,   // ← ADD
};
```

---

## Part 15 — Backend API: Register TXP Swap

After a successful on-chain TXP swap, `POST /store-swap` is called. The payload is identical to
all other swaps — no backend changes needed **except** ensuring the backend's token registry
accepts `"TXP"` as a valid `from_token_symbol` / `to_token_symbol`.

**Payload sent** (from `useSwapLogic.js`):

```json
POST /store-swap
{
  "from_token_symbol": "TXP",
  "to_token_symbol":   "LCX",
  "from_amount":       "100",
  "to_amount":         "100",
  "user_address":      "0xUserAddress...",
  "fee":               0.5,
  "transaction_hash":  "0xTxHash...",
  "multiPathStatus":   0
}
```

---

## Part 16 — `TXPSwapped` Event Monitoring

TXPSwap emits the `TXPSwapped` event on every successful swap. This can be used for backend
indexing or real-time UI updates.

**Event signature** (from `app/AhdfBdkfI/TXPSwapABI.json`):

```solidity
event TXPSwapped(
    address indexed user,      // swap recipient
    address indexed assetIn,   // input token address
    address indexed assetOut,  // output token address
    uint256 amountIn,          // net input (after fee)
    uint256 amountOut,         // output amount received
    uint256 fee,               // platform fee deducted
    uint256 timestamp          // block.timestamp
);
```

**Frontend subscription example** (optional, for real-time balance updates):

```javascript
// In useSwapLogic.js or a dedicated hook:
const txpSwapContract = new Contract(
  addresses.TXP_SWAP_CONTRACT,
  abis.TXP_SWAP_ABI,
  signer
);

txpSwapContract.on("TXPSwapped", (user, assetIn, assetOut, amountIn, amountOut, fee, ts) => {
  if (user.toLowerCase() === connectedAddress.toLowerCase()) {
    fetchBalances(); // refresh UI
  }
});

// Cleanup on unmount:
return () => txpSwapContract.removeAllListeners("TXPSwapped");
```

---

## Part 17 — Admin: Setting TXP Prices Post-Deploy

Before TXP swaps work correctly, the TXPSwap contract owner must set prices. The UI does not
expose these — they are `onlyOwner` operations called directly on-chain.

### Required `onlyOwner` Calls

```javascript
// Using ethers.js directly (admin script or Hardhat task)
const txpSwap = new Contract(TXP_SWAP_CONTRACT_ADDR, TXP_SWAP_ABI, ownerSigner);

// 1. Set TXP price: e.g., 1 TXP = $0.01 → manualPrice = 1e16
await txpSwap.setPrice(TXP_ADDRESS, ethers.parseUnits("0.01", 18));

// 2. Verify price was set
const price = await txpSwap.getPrice(TXP_ADDRESS);
console.log("TXP price:", ethers.formatUnits(price, 18), "USD");

// 3. Set platform fee (e.g., 0.5%)
await txpSwap.setPlatformFee(ethers.parseUnits("0.5", 18));

// 4. Add ERC20 liquidity for manual swaps (e.g., LCX)
const lcxToken = new Contract(LCX_ADDRESS, ERC20_ABI, ownerSigner);
await lcxToken.approve(TXP_SWAP_CONTRACT_ADDR, ethers.parseUnits("100000", 18));
await txpSwap.addManualLiquidity(LCX_ADDRESS, ethers.parseUnits("100000", 18));

// 5. Add TXP liquidity (for LCX → TXP swaps)
const txpToken = new Contract(TXP_ADDRESS, TXP_TOKEN_ABI, ownerSigner);
await txpToken.approve(TXP_SWAP_CONTRACT_ADDR, ethers.parseUnits("1000000", 18));
await txpSwap.addManualLiquidity(TXP_ADDRESS, ethers.parseUnits("1000000", 18));

// 6. Add BNB liquidity for TXP → WBNB swaps
await txpSwap.addManualLiquidity(ethers.ZeroAddress, 0n, {
  value: ethers.parseUnits("10", 18)
});
```

### Price Formula Reference

$$
\text{manualPrice} = \text{USD value per token} \times 10^{18}
$$

| TXP Market Price | `setPrice()` value                              |
|------------------|-------------------------------------------------|
| $0.01 / TXP      | `ethers.parseUnits("0.01", 18)` = `1e16`        |
| $0.10 / TXP      | `ethers.parseUnits("0.10", 18)` = `1e17`        |
| $1.00 / TXP      | `ethers.parseUnits("1.00", 18)` = `1e18`        |

---

## Part 18 — Complete Integration Checklist

### Smart Contract
- [ ] Deploy `TXPSwap.sol` with correct `_txp`, `_ytc`, `_lcx`, `_treasury`, `_platformFee`
- [ ] Call `setPrice(TXP_ADDRESS, price)` — set TXP USD price
- [ ] Call `setPrice(LCX_ADDRESS, price)` — set LCX USD price (if not set)
- [ ] Call `setPrice(YTC_ADDRESS, price)` — set YTC USD price (if not set)
- [ ] Call `addManualLiquidity()` to fund TXPSwap with TXP, LCX, YTC, and BNB
- [ ] Verify `activePriceFeed[TXP]` returns `0` (MANUAL) on-chain

### Configuration (`app/AhdfBdkfI/contract.js`)
- [ ] Add `TXP_SWAP_CONTRACT` address
- [ ] Add `TXP` token address
- [ ] Import `app/AhdfBdkfI/TXPSwapABI.json` → export as `TXP_SWAP_ABI: TXPSwapABI.abi`
- [ ] Import `app/AhdfBdkfI/TXPTokenABI.json` → export as `TXP_TOKEN_ABI: TXPTokenABI.abi`

### Token List (`app/home/components/Swap.jsx`)
- [ ] Add TXP entry to `tokenList` with `type: "manual"`, `slipToken: false`
- [ ] Ensure `tokenLists` spreads `tokenList` (already includes TXP)
- [ ] Add `TXP.png` icon to `public/assets/images/`

### Hook Changes (`app/home/components/hooks/useSwapLogic.js`)
- [ ] Extend `isNativeToken()` with `addresses.TXP`
- [ ] Add `isTxpPair()` helper
- [ ] Update `fetchStaticData()` — branch on `isTxpPair` for contract selection
- [ ] Update `calculate()` debounce effect — use TXPSwap for `calcOutAmount` / `getPlatformFee`
- [ ] Update `swapFunction()` — use TXPSwap for contract + approval
- [ ] Update `Dexswap()` — override `ownerAddress.SWAP_CONTRACT` and `abis.SWAP_ABI`
- [ ] Update `checkManualLiquidity()` — check TXPSwap balance

### Hook Changes (`app/home/components/hooks/useDexSwapLogic.js`)
- [ ] Accept `isTxpPair` param in `getDexSwapDetails()` for correct `getPlatformFee` contract

### UI
- [ ] Add TXP to `tokenImages` map in `app/DeFi/swap/SwapContent.jsx`
- [ ] Verify token dropdown renders TXP icon correctly

### Backend
- [ ] Ensure `POST /store-swap` accepts `"TXP"` as `from_token_symbol` / `to_token_symbol`
- [ ] Ensure `GET /token-list` returns TXP metadata if tokens are fetched dynamically
- [ ] Ensure `POST /fetch-multi-path-address` backend supports TXP in path lookups

---

## Part 19 — Full TXP Swap Data Flow Diagram

```
[User selects TXP → LCX in Swap.jsx]
              │
              ▼
[fetchStaticData()]
   isTxpPair(TXP, LCX) = true
   swapContract = new Contract(TXP_SWAP_CONTRACT, TXP_SWAP_ABI, signer)
              │
   TXPSwap.activePriceFeed(TXP_ADDRESS) → 0n (MANUAL)
   isSpecialMode = false
   setActiveTokens(tokenData.defaultList)
              │
   TXPSwap.calcOutAmount(TXP, LCX, 1e18) → exchangeRate
   TXPSwap.platformFee() → feePercentage
              │
              ▼
[User types sendAmount — 600ms debounce → calculate()]
   swapContract = TXPSwap (isTxp = true)
              │
   TXPSwap.calcOutAmount(TXP, LCX, amountInWei) → amountOut
   TXPSwap.getPlatformFee(amountInWei) → [netAmount, feeAmount]
   setReceiveAmount(amountOut)
   setCalculatedFeeAmount(feeAmount)
              │
   checkManualLiquidity(TXP_SWAP_CONTRACT):
     IERC20(LCX).balanceOf(TXP_SWAP_CONTRACT) >= amountOut? ✓
   setBtnMessage("Swap Now")
              │
              ▼
[User clicks "Swap Now" → handleDexswap()]
   isSpecialMode = false → swapFunction()
              │
   GET /profile → session valid ✓
              │
   TXPToken.allowance(user, TXP_SWAP_CONTRACT) → insufficient
   TXPToken.approve(TXP_SWAP_CONTRACT, amountIn).wait() ✓
              │
   TXPSwap.swap([TXP_ADDR, LCX_ADDR], amountIn, user)
              │
   ┌──────────────────────────────────────────────────────┐
   │  ON-CHAIN: TXPSwap.sol                               │
   │                                                      │
   │  getPlatformFee(amountIn)                            │
   │    feeAmount = amountIn × platformFee / 1e20         │
   │    netAmount = amountIn - feeAmount                  │
   │                                                      │
   │  safeTransferFrom(user, treasury, feeAmount)  ← fee  │
   │  safeTransferFrom(user, TXPSwap, netAmount)          │
   │                                                      │
   │  calcOutAmount(TXP, LCX, netAmount)                  │
   │    amountOut = netAmount × price[TXP] / price[LCX]   │
   │                                                      │
   │  IERC20(LCX).safeTransfer(user, amountOut)           │
   │                                                      │
   │  emit TXPSwapped(user, TXP, LCX, net, out, fee, ts)  │
   └──────────────────────────────────────────────────────┘
              │
   tx.wait() ✓
              │
   POST /store-swap {
     from_token_symbol: "TXP",
     to_token_symbol:   "LCX",
     from_amount:       sendAmount,
     to_amount:         receiveAmount,
     transaction_hash:  tx.hash,
     fee:               feePercent
   }
              │
   toast.success("Swap successful!")
   setSendAmount("") / setReceiveAmount("")
   fetchBalances() → refresh TXP + LCX balances in UI
```

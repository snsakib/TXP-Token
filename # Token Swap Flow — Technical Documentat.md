# Token Swap Flow — Technical Documentation

## Overview

This project is a Next.js DeFi frontend for swapping tokens (LCX, YTC, USDC, USDT, WBNB, ARK, FIST, USDA, GOT, CAKE, LINK, ASTER) via the **YapitSwap** smart contract system:

1. **YapitSwap** (`app/AhdfBdkfI/abi.json`) — Primary swap contract (manual price + DEX price modes)

---

## Contract Addresses (BSC Mainnet)

| Name             | Address                                      | Source File                        |
|------------------|----------------------------------------------|------------------------------------|
| SWAP_CONTRACT    | `0x173781931d33306Fd04C7B15941b944c41Ab0C1A` | `app/AhdfBdkfI/contract.js`        |
| ROUTER_CONTRACT  | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | `app/AhdfBdkfI/contract.js`        |
| FACTORY_CONTRACT | `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` | `app/AhdfBdkfI/contract.js`        |
| LCX (LCASH)      | `0xd5c10B78e7C274e04b213C13D2bF40F49b0006D0` | `app/AhdfBdkfI/contract.js`        |
| YTC              | `0x236dAE64e0174581591230fEC1F113a86B75fFa2` | `app/AhdfBdkfI/contract.js`        |
| TUSD (USDT)      | `0x55d398326f99059fF775485246999027B3197955` | `app/AhdfBdkfI/contract.js`        |
| WBNB             | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | `app/AhdfBdkfI/contract.js`        |
| ARK              | `0xCae117ca6Bc8A341D2E7207F30E180f0e5618B9D` | `app/AhdfBdkfI/contract.js`        |
| FIST             | `0xC9882dEF23bc42D53895b8361D0b1EDC7570Bc6A` | `app/AhdfBdkfI/contract.js`        |
| ASTER            | `0x000Ae314E2A2172a039B26378814C252734f556A` | `app/AhdfBdkfI/contract.js`        |
| USDA             | `0x17EAfd08994305D8AcE37EfB82F1523177eC70EE` | `app/AhdfBdkfI/contract.js`        |
| GOT              | `0x701add4311E85c1f9C1549319fe2c476bc8a1b8b` | `app/AhdfBdkfI/contract.js`        |

---

## Token Classification

### Manual Price Feed Tokens (YapitSwap internal pricing)
| Symbol | Type   | Slippage |
|--------|--------|----------|
| USDC   | manual | false    |
| YTC    | manual | false    |
| LCX    | manual | false    |
| USDT   | manual | false    |
| WBNB   | manual | false    |

> Source: `app/home/components/Swap.jsx` — `tokenList` array

### DEX/PancakeSwap Price Feed Tokens (slippage enabled)
| Symbol | Type     | Slippage |
|--------|----------|----------|
| ARK    | pancake  | true     |
| FIST   | pancake  | true     |
| USDA   | pancake  | true     |
| GOT    | pancake  | true     |
| CAKE   | pancake  | true     |
| LINK   | pancake  | true     |
| ASTER  | pancake  | true     |

> Source: `app/home/components/Swap.jsx` — `tokenLists` array

---

## ABI Files

| File                              | Purpose                                          |
|-----------------------------------|--------------------------------------------------|
| `app/AhdfBdkfI/abi.json`          | YapitSwap main contract ABI                      |
| `app/AhdfBdkfI/usdcAbi.json`      | Token (ERC20) ABI (also used as TOKEN_ABI)       |
| `app/AhdfBdkfI/routerAbi.json`    | PancakeRouter ABI                                |
| `app/AhdfBdkfI/factoryAbi.json`   | PancakeFactory ABI                               |
| `app/AhdfBdkfI/pairAbi.json`      | PancakePair ABI                                  |

---

## API Routes (Backend REST)

| Endpoint          | Method | Purpose                                   | Source File                                      |
|-------------------|--------|-------------------------------------------|--------------------------------------------------|
| `/token-list`     | GET    | Fetch available token list                | `app/home/components/hooks/api/swapapi.js`       |
| `/store-swap`     | POST   | Record swap transaction in backend DB     | `app/home/components/hooks/api/swapapi.js`       |
| `/get-swap-history` | GET  | Fetch paginated swap history              | `app/home/components/hooks/api/swapapi.js`       |
| `/profile`        | GET    | Validate user session before swap        | `app/home/components/hooks/useSwapLogic.js`      |
| `/store-stake`    | POST   | Record stake transaction                  | `app/home/components/hooks/api/swapapi.js`       |

---

## Key Source Files

| File                                                          | Role                                                        |
|---------------------------------------------------------------|-------------------------------------------------------------|
| `app/home/components/Swap.jsx`                                | Main Swap UI component                                      |
| `app/home/components/hooks/useSwapLogic.js`                   | Core swap state management, calculation, and execution hook |
| `app/home/components/hooks/useDexSwapLogic.js`                | DEX-specific swap logic (PancakeSwap passthrough)           |
| `app/home/components/hooks/api/swapapi.js`                    | React Query API hooks for swap                              |
| `app/AhdfBdkfI/contract.js`                                   | Contract config (addresses + ABIs)                          |
| `app/DeFi/swap/page.jsx`                                      | Swap page with idle logout logic                            |
| `app/DeFi/swap/SwapContent.jsx`                               | Swap + history UI                                           |

---

## Complete Swap Flow — Step by Step

### STEP 1: Page Load & Authentication

**File:** `app/DeFi/swap/page.jsx`

1. On mount, checks `localStorage` for token key `WLRVBJZUONEA`.
2. If not found → redirects to `/`.
3. Sets up a **60-minute idle timer**. On timeout:
   - Calls `POST /logout-wallet` with `{ address: walletAddress }`.
   - Disconnects wallet via `useDisconnect()` (ReownAppKit).
   - Clears localStorage and redirects to `/`.

---

### STEP 2: UI Initialization

**File:** `app/home/components/Swap.jsx`

1. Renders the `<Swap />` component.
2. Calls `useSwapLogic(config)` from `app/home/components/hooks/useSwapLogic.js` with:
   - `addresses` — contract addresses
   - `abis` — ABI objects
   - `tokenData.defaultList` — manual price tokens (YTC, LCX, USDC, USDT, WBNB)
   - `tokenData.secondaryList` — all tokens including DEX tokens
3. Default token pair: `YTC → USDT` (set in `app/AhdfBdkfI/contract.js` → `defaultSelection`)

---

### STEP 3: Static Data & Mode Detection

**File:** `app/home/components/hooks/useSwapLogic.js` → `fetchStaticData()`

Triggered on token pair change.

```
fetchStaticData()
│
├── Creates swapContract = new Contract(SWAP_CONTRACT, SWAP_ABI, signer)
├── Creates routerContract = new Contract(ROUTER_CONTRACT, ROUTER_ABI, signer)
│
├── Determines targetAddress:
│   ├── If fromToken is native (LCX/YTC) → targetAddress = fromToken.address
│   └── If toToken is native (LCX/YTC)   → targetAddress = toToken.address
│
├── Calls swapContract.activePriceFeed(targetAddress)
│   ├── Returns 0n (MANUAL mode):
│   │   ├── setIsSpecialMode(true) — enables manual price mode
│   │   ├── setActiveTokens(tokenData.secondaryList)
│   │   └── Calls liquidityCheck() → see STEP 3a
│   │
│   └── Returns 1n (DEX mode):
│       ├── setIsSpecialMode(false)
│       └── Calls liquidityCheck() → DEX pair validation
```

#### STEP 3a: Liquidity Check

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `liquidityCheck()`

```
liquidityCheck({ signerOrProvider, fromaddress, toaddress, abis, addresses, ... })
│
├── Gets factory = new Contract(FACTORY_CONTRACT, FACTORY_ABI, signer)
├── Calls factory.getPair(fromaddress, toaddress)
│
├── Direct pair found:
│   ├── Gets pair contract → reserves
│   ├── Calculates available liquidity
│   └── Returns { hasPair: true, reserves: true, isMulti: false, availableLiquidity }
│
├── No direct pair → checks multi-hop via API:
│   ├── Calls checkMultiPairApi(fromSymbol, toSymbol) → GET /multi-swap-pair
│   ├── If multi-path found:
│   │   ├── Iterates each hop
│   │   ├── Gets reserves for each pair
│   │   ├── Calculates bestAmountOut across hops
│   │   └── Returns { hasPair: true, isMulti: true, reservesPerHop, bestAmountOut }
│   └── No path → Returns { hasPair: false }
```

---

### STEP 4: Amount Calculation (Debounced 600ms)

**File:** `app/home/components/hooks/useSwapLogic.js` — `useEffect` on `[signer, sendAmount, fromToken, toToken]`

```
User types in "Send" input
│
├── handleSendChange(e) called
├── setSendAmount(value)
│
└── After 600ms debounce → calculate()
    │
    ├── isSpecialMode = true (LCX/YTC manual pairs):
    │   ├── Calls getDexSwapDetails() from useDexSwapLogic.js
    │   └── See STEP 4a
    │
    └── isSpecialMode = false (standard YapitSwap):
        ├── Creates swapContract
        ├── Calls swapContract.calcOutAmount(fromToken.address, toToken.address, amountInWei)
        ├── Calls swapContract.getPlatformFee(amountInWei)
        │   └── Returns [amountIn, feeAmount]
        ├── Sets receiveAmount, feePercentage, calculatedFeeAmount
        ├── Checks liquidity via checkManaualLiqudity()
        │   ├── If toToken = WBNB → checks contract BNB balance
        │   └── Else → checks contract ERC20 balance
        └── Sets btnMessage = "Swap Now" or "Insufficient Liquidity"
```

#### STEP 4a: getDexSwapDetails (DEX mode calculation)

**File:** `app/home/components/hooks/useDexSwapLogic.js` → `getDexSwapDetails()`

```
getDexSwapDetails({ signer, sendAmount, fromToken, toToken, addresses, abis, checkMultiPairApi })
│
├── Creates swapContract (YapitSwap)
├── Gets pancakeRouter address from swapContract.pancakeRouter()
├── Creates pancakeRouter contract
│
├── Calls swapContract.getPlatformFee(amountInWei)
│   └── effectiveAmount = fee[0] (net amount after fee)
│
├── Calls liquidityCheck() to get path/reserves
│
├── If isMulti (multi-hop):
│   ├── Calls pancakeRouter.getAmountsOut(effectiveAmount, multiPath)
│   ├── Calculates price impact via calculateMultiHopPriceImpact()
│   └── Returns amountOut, priceImpact, isMulti: true, apiMultiPath
│
├── If direct pair:
│   ├── Calls pancakeRouter.getAmountsOut(effectiveAmount, [from, to])
│   ├── Calculates price impact via calculatePriceImpact()
│   └── Returns amountOut, priceImpact, isMulti: false
│
└── Sets receiveAmount, priceImpact, exchangeRate, btnMessage
```

---

### STEP 5: Swap Execution

**File:** `app/home/components/Swap.jsx` → `handleDexswap()`

```
User clicks "Swap Now"
│
├── isSpecialMode = true  → calls Dexswap()   [DEX/PancakeSwap path]
└── isSpecialMode = false → calls swapFunction() [Manual YapitSwap path]
```

---

### STEP 5a: Manual YapitSwap Path (LCX, YTC, USDC, USDT, WBNB)

**File:** `app/home/components/hooks/useSwapLogic.js` → `swapFunction()`

```
swapFunction(e, receiveAmount)
│
├── setIsSwapping(true)
├── Validates user session: GET /profile
│   └── If !status → return (block swap)
│
├── Validates inputs:
│   ├── sendAmount > fromBalance → toast.error("Insufficient Balance")
│   └── isNativeToken(from) === isNativeToken(to) → toast.error("Invalid Pair")
│
├── amountInWei = ethers.parseUnits(sendAmount, fromToken.decimals)
├── Creates swapContract = new Contract(SWAP_CONTRACT, SWAP_ABI, signer)
│
├── If fromToken is NOT WBNB:
│   ├── Creates tokenContract = new Contract(fromToken.address, fromToken.abi, signer)
│   ├── Calls tokenContract.allowance(userAddress, SWAP_CONTRACT)
│   └── If allowance < amountInWei:
│       ├── toast.loading("Approving token...")
│       └── Calls tokenContract.approve(SWAP_CONTRACT, amountInWei).wait()
│
├── Executes swap on-chain:
│   ├── fromToken = WBNB:
│   │   └── swapContract.swap(path, amountInWei, userAddress, { value: amountInWei })
│   └── fromToken = ERC20:
│       └── swapContract.swap(path, amountInWei, userAddress)
│
├── tx.wait() — waits for confirmation
│
├── Calls swapContract.platformFee() → feePercent
│
├── Builds apiData = {
│   from_token_symbol, to_token_symbol,
│   from_amount, to_amount,
│   transaction_hash, platform_fee,
│   from_address, to_address
│   }
│
├── Checks staking conditions (if stakeMessage active):
│   ├── YES → Promise.all([POST /store-stake, POST /store-swap])
│   └── NO  → POST /store-swap
│
├── toast.success("Swap successful!")
├── setSendAmount(""), setReceiveAmount(""), setCalculatedFeeAmount("0")
└── fetchBalances()
```

---

### STEP 5b: DEX PancakeSwap Path (ARK, FIST, USDA, GOT, CAKE, LINK, ASTER)

**File:** `app/home/components/hooks/useSwapLogic.js` → `Dexswap()`  
**File:** `app/home/components/hooks/useDexSwapLogic.js` → `pancakeSwap()`

```
Dexswap()
│
├── Validates session: GET /profile
├── Calls pancakeSwap({ fromToken, toToken, amount, signer, ownerAddress, abis, ... })
│
pancakeSwap()
│
├── fromToken.isCoin = true (BNB → Token, non-slippage):
│   └── swapContract.swapExactETHForTokens(
│         ROUTER_ADDRESS, amountOutMin, path, userAddress, deadline,
│         { value: amountInWei }
│       )
│
├── fromToken.isCoin = false, toToken.isCoin = true (Token → BNB, non-slippage):
│   ├── tokenContract.allowance(userAddress, SWAP_CONTRACT)
│   ├── If insufficient → tokenContract.approve(SWAP_CONTRACT, amountIn)
│   └── swapContract.swapExactTokensForETH(
│         ROUTER_ADDRESS, amountIn, amountOutMin, path, userAddress, deadline
│       )
│
├── Token → Token (non-slippage):
│   ├── tokenContract.approve(SWAP_CONTRACT, amountIn) if needed
│   └── swapContract.swapExactTokenForTokens(
│         ROUTER_ADDRESS, amountIn, amountOutMin, path, userAddress, deadline
│       )
│
├── Slippage variants (slipToken = true):
│   ├── BNB → Token (slippage):
│   │   └── swapContract.swapExactETHForTokensSupportingFeeOnTransferTokens(...)
│   ├── Token → BNB (slippage):
│   │   └── swapContract.swapExactTokensForETHSupportingFeeOnTransferTokens(...)
│   └── Token → Token (slippage):
│       └── swapContract.swapExactTokensForTokensSupportingFeeOnTransferTokens(...)
│
├── Slippage recalculation:
│   ├── finalAmount = receiveAmount - (receiveAmount × slippagevalue / 100)
│   └── Updates amountOutMin with slippage tolerance
│
├── swapTx.wait()
│
└── Returns { status: true, message: "Swap Now", swapTx }
```

Back in `Dexswap()`:
```
├── On success:
│   ├── Builds apiData for POST /store-swap
│   ├── Calls swaptokenMutation.mutateAsync(apiData) → POST /store-swap
│   ├── toast.success("Swap successful!")
│   ├── Resets amounts
│   └── fetchBalances()
│
└── On error:
    ├── error.code === 4001 → toast.error("User denied transaction signature!")
    └── setIsSwapping(false)
```

---

### STEP 6: Balance Refresh

**File:** `app/home/components/hooks/useSwapLogic.js` → `fetchBalances()`

```
fetchBalances()
│
├── fromToken.symbol = "WBNB":
│   └── signer.provider.getBalance(userAddress) → ethers.formatEther()
│
└── fromToken.symbol = ERC20:
    └── readTokenBalance(signer, token.address, token.abi, userAddress, decimals)
        └── tokenContract.balanceOf(userAddress) → ethers.formatUnits(balance, decimals)
```

---

## Smart Contract Swap Functions (YapitSwap)

### Manual Price Swap
```solidity
// YapitSwap — app/AhdfBdkfI/abi.json
function swap(address[] memory _path, uint256 _amountIn, address _to)
    external payable
```
- Validates the token pair is supported
- Calls `getPlatformFee(_amountIn)` → deducts fee to treasury
- Calls `calcOutAmount(_path[0], _path[1], _amountIn)` → manual price lookup
- Transfers output token/BNB directly to `_to`

### DEX Passthrough Functions
```solidity
swapExactETHForTokens(IPancakeRouter02 _router, uint256 amountOutMin, address[] path, address to, uint256 deadline)
swapExactTokensForETH(IPancakeRouter02 _router, uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)
swapExactTokenForTokens(IPancakeRouter02 _router, uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)
swapExactTokensForTokensSupportingFeeOnTransferTokens(...)
swapExactETHForTokensSupportingFeeOnTransferTokens(...)
```
All passthrough functions:
1. Call `_internalSupportingTransactions()` to collect fee + transfer tokens to router allowance
2. Forward call to actual PancakeRouter

---

## Price Impact Calculation

**File:** `app/home/components/hooks/useDexSwapLogic.js`

### Single Hop
```
calculatePriceImpact(pair, fromAddress, fromAmount, fromDecimals, toDecimals)
│
├── Gets pair reserves
├── midPrice = reserveOut / reserveIn
├── executionPrice = amountOut / amountIn
└── priceImpact = ((midPrice - executionPrice) / midPrice) × 100
```

### Multi Hop
```
calculateMultiHopPriceImpact(reservesPerHop, fromAmount)
│
└── For each hop: accumulates spot price ratio vs execution ratio
    └── Returns combined price impact %
```

---

## Slippage Settings

**File:** `app/home/components/hooks/SlippageSettings.jsx`

- Default: `"auto"` (no slippage) for manual tokens
- For `slipToken: true` tokens: defaults to `0.1%`
- User can override via settings modal
- Stored in state: `slippagevalue`, `isSlippage`
- Used in `pancakeSwap()` to recalculate `amountOutMin`:
  ```js
  finalAmount = receiveAmount - (receiveAmount * slippagevalue / 100)
  ```

---

## Staking Integration During Swap

**File:** `app/home/components/hooks/useSwapLogic.js`

If the swap amount falls within a staking range (`stakeMessage.minValue` to `stakeMessage.maxValue`):

```
swapFunction()
│
└── stakeMessage.stakemessage is set:
    ├── Builds stakedata = {
    │     stake_period, stake_yield, stakeuniqueid, stake_fee
    │   }
    ├── Promise.all([
    │     POST /store-stake (stakedata),
    │     POST /store-swap  (apiData)
    │   ])
    └── On success → router.push('/DeFi/stake')
```

---

## Session Validation Flow

Before every swap execution:

```
queryClient.fetchQuery({ queryKey: ["get-user-active", address], queryFn: () => GET /profile })
│
├── response.data.status = true  → proceed with swap
└── response.data.status = false → return (block swap silently)
```

**Source:** `app/home/components/hooks/useSwapLogic.js` lines 564–570, 481–487

---

## React Query Keys

| Query Key                           | API Call         | Purpose                     |
|-------------------------------------|------------------|-----------------------------|
| `["get-currency"]`                  | GET /token-list  | Token list fetch             |
| `["get-swap-history", page, ...]`   | GET /swap-history| Paginated history            |
| `["get-user-active", address]`      | GET /profile     | Pre-swap session check       |
| `["get-multi-pair"]`                | GET /multi-swap-pair | Multi-hop path check     |

**Source:** `app/home/components/hooks/api/swapapi.js`

---

## Error Handling

| Error                          | Handler                                        |
|--------------------------------|------------------------------------------------|
| `error.code === 4001`          | `toast.error("User denied transaction!")`      |
| `"ACTION_REJECTED"`            | `toast.error("User denied transaction!")`      |
| `info.error.code === 4001`     | `toast.error("User denied transaction!")`      |
| Insufficient balance           | `toast.error("Insufficient Balance")`          |
| Invalid pair (both native)     | `toast.error("Invalid Pair")`                  |
| No liquidity                   | `setBtnMessage("Insufficient Liquidity")`      |
| No pair found                  | `setBtnMessage("No Pair Found")`               |
| API log failure                | `console.warn("Swap API failed")` (non-blocking)|

---

## Full Data Flow Diagram

```
[User UI - Swap.jsx]
        │
        ▼
[useSwapLogic hook]
        │
   ┌────┴────────────────┐
   │                     │
[isSpecialMode=false]  [isSpecialMode=true]
[YapitSwap.swap()]     [pancakeSwap()]
   │                     │
   │                 [useDexSwapLogic.js]
   │                     │
   └────────┬────────────┘
            │
    [tx.wait() - BSC]
            │
     [POST /store-swap]
            │
    [toast.success()]
            │
    [fetchBalances()]
```
# TXP Token Swap — Full-Stack Integration Masterplan

## Scope

This document is the **definitive cross-project implementation plan** for integrating TXP (Triple X
POS Token) swaps into the full stack. It covers every required change across all three active
projects and explicitly confirms which projects require **no changes**.

| Project                       | Changes Required? | Summary                                            |
|-------------------------------|-------------------|----------------------------------------------------|
| `alvin_crypto_frontend`       | ✅ **YES**        | Covered exhaustively in `TXP_SWAP_INTEGRATION_GUIDE.md` |
| `alvin_crypto_backend`        | ✅ **YES**        | DB seed, token registry, multi-hop graph bootstrap |
| `alvin_crypto_admin`          | ✅ **YES**        | Token add, contract routing for price-feed & liquidity UIs |
| `alvin_iyap360_micro`         | ❌ **NO**         | Unrelated (Iyap360 social/marketplace Laravel app) |
| `alvin_iyap360_micro_front`   | ❌ **NO**         | Unrelated (Nuxt.js social media frontend)          |

---

## Project 1: `alvin_crypto_frontend` (Next.js DeFi Frontend)

> The complete implementation is already documented in `TXP_SWAP_INTEGRATION_GUIDE.md`.
> This section provides a condensed implementation-order reference and highlights critical
> dependencies between parts.

### Execution Order (strict — later steps depend on earlier ones)

```
Step 1 → Contract Config
Step 2 → Token List
Step 3 → isNativeToken / isTxpPair helpers
Step 4 → fetchStaticData contract routing
Step 5 → calculate() / debounce effect
Step 6 → getDexSwapDetails isTxpPair param
Step 7 → swapFunction routing
Step 8 → Dexswap routing
Step 9 → checkManualLiquidity
Step 10 → Exchange rate display
Step 11 → UI token dropdown / icon
Step 12 → Swap history icon map
```

### Step 1 — Contract Config (`app/AhdfBdkfI/contract.js`)

Add `TXP_SWAP_CONTRACT` and `TXP` addresses, import `app/AhdfBdkfI/TXPSwapABI.json` and `app/AhdfBdkfI/TXPTokenABI.json`:

```javascript
// app/AhdfBdkfI/contract.js
export const addresses = {
  SWAP_CONTRACT:     "0x173781931d33306Fd04C7B15941b944c41Ab0C1A",
  TXP_SWAP_CONTRACT: "0x<DEPLOYED_TXP_SWAP_ADDRESS>",           // ← ADD
  ROUTER_CONTRACT:   "0x10ED43C718714eb63d5aA57B78B54704E256024E",
  FACTORY_CONTRACT:  "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73",
  LCASH:             "0xd5c10B78e7C274e04b213C13D2bF40F49b0006D0",
  YTC:               "0x236dAE64e0174581591230fEC1F113a86B75fFa2",
  TXP:               "0x<DEPLOYED_TXP_TOKEN_ADDRESS>",           // ← ADD
  TUSD:              "0x55d398326f99059fF775485246999027B3197955",
  WBNB:              "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
  ARK:               "0xCae117ca6Bc8A341D2E7207F30E180f0e5618B9D",
  FIST:              "0xC9882dEF23bc42D53895b8361D0b1EDC7570Bc6A",
  ASTER:             "0x000Ae314E2A2172a039B26378814C252734f556A",
  USDA:              "0x17EAfd08994305D8AcE37EfB82F1523177eC70EE",
  GOT:               "0x701add4311E85c1f9C1549319fe2c476bc8a1b8b",
  USDC:              "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",
};

import SWAP_ABI      from "./abi.json";
import TXP_SWAP_ABI  from "./TXPSwapABI.json";    // ← ADD
import TXP_TOKEN_ABI from "./TXPTokenABI.json";   // ← ADD

export const abis = {
  SWAP_ABI,
  TXP_SWAP_ABI:  TXP_SWAP_ABI.abi,   // ← ADD (Hardhat artifact — ABI in .abi)
  TXP_TOKEN_ABI: TXP_TOKEN_ABI.abi,  // ← ADD
  // ...rest unchanged
};
```

> **Blocker:** `TXP_SWAP_CONTRACT` address and `TXP` token address must be known before any
> other step. Obtain them from the deployment script output.

### Step 2 — Token List (`app/home/components/Swap.jsx`)

Add TXP to `tokenList` (manual tokens) and ensure `tokenLists` (DEX + all) spreads it:

```jsx
import txpIcon from '../../../public/assets/images/TXP.png';

// In tokenList (manual/native group):
{
  name:      "TXP",
  symbol:    "TXP",
  address:   CONFIG.addresses.TXP,
  icon:      txpIcon,
  decimals:  18,
  type:      "manual",
  slipToken: false,
  isCoin:    false,
  abi:       abis.TXP_TOKEN_ABI,  // needed for allowance/approve calls
},

// tokenLists (secondary DEX list) must spread tokenList so TXP appears
// when a DEX token is the counterpart — confirm the spread already exists:
const tokenLists = [
  ...tokenList,       // now includes TXP ✓
  // ...ARK, FIST, etc.
];
```

> Place `TXP.png` into `public/assets/images/TXP.png`.

### Step 3 — Helpers (`app/home/components/hooks/useSwapLogic.js`)

```javascript
// Extend isNativeToken:
const isNativeToken = (addr) =>
  addr?.toLowerCase() === addresses.LCASH?.toLowerCase() ||
  addr?.toLowerCase() === addresses.YTC?.toLowerCase()   ||
  addr?.toLowerCase() === addresses.TXP?.toLowerCase();   // ← ADD

// New helper:
const isTxpPair = (fromAddr, toAddr) =>
  fromAddr?.toLowerCase() === addresses.TXP?.toLowerCase() ||
  toAddr?.toLowerCase()   === addresses.TXP?.toLowerCase();
```

### Step 4 — `fetchStaticData` Contract Routing

```javascript
const fetchStaticData = async () => {
  const isTxp = isTxpPair(fromToken.address, toToken.address);

  const swapContract = new Contract(
    isTxp ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT,
    isTxp ? abis.TXP_SWAP_ABI          : abis.SWAP_ABI,
    signer
  );

  let targetAddress = '';
  if (isNativeToken(fromToken.address)) targetAddress = fromToken.address;
  else if (isNativeToken(toToken.address)) targetAddress = toToken.address;

  const activestatus = targetAddress
    ? await swapContract.activePriceFeed(targetAddress)
    : 1n;

  // ...rest of existing logic unchanged...
};
```

### Step 5 — `calculate()` Debounce Effect

```javascript
const calculate = async () => {
  const isTxp = isTxpPair(fromToken.address, toToken.address);

  const swapContract = new Contract(
    isTxp ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT,
    isTxp ? abis.TXP_SWAP_ABI          : abis.SWAP_ABI,
    signer
  );

  if (!isSpecialMode) {
    // Manual mode — identical call on different contract instance
    const amountInWei = ethers.parseUnits(sendAmount, fromToken.decimals);
    const amountOut   = await swapContract.calcOutAmount(
      fromToken.address, toToken.address, amountInWei
    );
    const [netAmount, feeAmount] = await swapContract.getPlatformFee(amountInWei);
    setReceiveAmount(ethers.formatUnits(amountOut, toToken.decimals));
    setCalculatedFeeAmount(ethers.formatUnits(feeAmount, fromToken.decimals));
    await checkManualLiquidity(swapContract);
  } else {
    // DEX mode — pass isTxp flag so getDexSwapDetails uses correct platformFee contract
    const result = await getDexSwapDetails({
      signer, sendAmount, fromToken, toToken, addresses, abis,
      checkMultiPairApi, isTxpPair: isTxp,
    });
    // ...set state from result...
  }
};
```

### Step 6 — `getDexSwapDetails` in `useDexSwapLogic.js`

Add `isTxpPair` boolean parameter to select the correct swap contract for `getPlatformFee`:

```javascript
export async function getDexSwapDetails({
  signer, sendAmount, fromToken, toToken,
  addresses, abis, checkMultiPairApi,
  isTxpPair,      // ← ADD
}) {
  const swapContract = new Contract(
    isTxpPair ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT,
    isTxpPair ? abis.TXP_SWAP_ABI          : abis.SWAP_ABI,
    signer
  );

  const ROUTER_ADDRESS = await swapContract.pancakeRouter();
  const pancakeRouter  = new Contract(ROUTER_ADDRESS, abis.ROUTER_ABI, signer);

  const amountInWei     = ethers.parseUnits(String(sendAmount), fromToken.decimals);
  const fee             = await swapContract.getPlatformFee(amountInWei);
  const effectiveAmount = fee[0];

  // ...rest of getDexSwapDetails unchanged...
}
```

### Step 7 — `swapFunction` Routing (Manual Path)

```javascript
const swapFunction = async (e, receiveAmount) => {
  // ...session check, validation unchanged...

  const isTxp = isTxpPair(fromToken.address, toToken.address);
  const contractAddress = isTxp ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT;

  const swapContract = new Contract(
    contractAddress,
    isTxp ? abis.TXP_SWAP_ABI : abis.SWAP_ABI,
    signer
  );

  if (!fromIsWBNB) {
    const tokenContract = new Contract(fromToken.address, fromToken.abi, signer);
    const allowance     = await tokenContract.allowance(connectedAddress, contractAddress);
    if (allowance < amountInWei) {
      await (await tokenContract.approve(contractAddress, amountInWei)).wait();
    }
  }

  const path = [fromToken.address, toToken.address];
  const tx = fromIsWBNB
    ? await swapContract.swap(path, amountInWei, connectedAddress, { value: amountInWei })
    : await swapContract.swap(path, amountInWei, connectedAddress);

  await tx.wait();
  // ...POST /store-swap, toast, fetchBalances unchanged...
};
```

### Step 8 — `Dexswap` Routing (DEX Passthrough)

Override `ownerAddress.SWAP_CONTRACT` and `abis.SWAP_ABI` passed into `pancakeSwap()`:

```javascript
const Dexswap = async () => {
  const isTxp = isTxpPair(fromToken.address, toToken.address);

  const dataTNX = await pancakeSwap({
    fromToken, toToken, amount: sendAmount,
    signer, userAddress: connectedAddress,
    ownerAddress: {
      ...addresses,
      SWAP_CONTRACT: isTxp ? addresses.TXP_SWAP_CONTRACT : addresses.SWAP_CONTRACT,
    },
    abis: {
      ...abis,
      SWAP_ABI: isTxp ? abis.TXP_SWAP_ABI : abis.SWAP_ABI,
    },
    receiveAmount, isSlippage, slippagevalue,
    path: apiMultiPath, fromBalance,
  });
  // ...rest unchanged — pancakeSwap() uses ownerAddress.SWAP_CONTRACT dynamically...
};
```

> **Key insight:** `pancakeSwap()` in `useDexSwapLogic.js` already uses
> `ownerAddress.SWAP_CONTRACT` for all `approve` and `swap` calls. No changes needed
> inside `pancakeSwap()` itself — it transparently calls TXPSwap when the address is overridden.

### Step 9 — `checkManualLiquidity`

```javascript
const checkManualLiquidity = async (swapContract) => {
  const contractAddress = isTxpPair(fromToken.address, toToken.address)
    ? addresses.TXP_SWAP_CONTRACT
    : addresses.SWAP_CONTRACT;

  const receiveAmountWei = ethers.parseUnits(String(receiveAmount || "0"), toToken.decimals);

  if (toToken.symbol === "WBNB") {
    const bal = await signer.provider.getBalance(contractAddress);
    if (bal < receiveAmountWei) { setBtnMessage("Insufficient Liquidity"); return false; }
  } else {
    const tokenOut = new Contract(toToken.address, abis.TOKEN_ABI, signer);
    const bal      = await tokenOut.balanceOf(contractAddress);
    if (bal < receiveAmountWei) { setBtnMessage("Insufficient Liquidity"); return false; }
  }
  setBtnMessage("Swap Now");
  return true;
};
```

### Step 10 — Exchange Rate Display

```javascript
// Inside fetchStaticData(), after mode detection:
if (!isSpecialMode) {
  const oneUnit = ethers.parseUnits("1", fromToken.decimals);
  if (isWBNB(fromToken.address) || isWBNB(toToken.address)) {
    // Existing WBNB → PancakeRouter path (unchanged)
  } else {
    // swapContract already routes to TXPSwap if isTxpPair === true
    const toValue = await swapContract.calcOutAmount(
      fromToken.address, toToken.address, oneUnit
    );
    setExchangeRate(ethers.formatUnits(toValue, toToken.decimals));
  }
}
```

### Step 11 — UI Token Dropdown

The token dropdown logic already handles `slipToken` for slippage settings — TXP has
`slipToken: false` so no new branch is needed. Verify TXP icon renders:

```jsx
<Image src={token.icon} alt={token.name} width={24} height={24} />
```

### Step 12 — Swap History Icon Map (`app/DeFi/swap/SwapContent.jsx`)

```jsx
import txpIcon from '../../../public/assets/images/TXP.png';

const tokenImages = {
  // ...existing entries...
  TXP: txpIcon,   // ← ADD
};
```

---

## Project 2: `alvin_crypto_backend` (Laravel 11 API)

The backend performs **no on-chain calls**. It is a pure record-keeping layer. However, three
critical things must happen before TXP swaps can be recorded successfully.

### Why Backend Changes Are Needed

The `POST /store-swap` endpoint (`SwapController@saveSwapResult`) validates:

```php
$fetchFromToken = Token::where('token_symbol', $input_data['from_token_symbol'])->first();
if (empty($fetchFromToken)) {
    return response()->json(['success' => false, 'message' => 'Invalid from token'], 422);
}
```

If `"TXP"` does not exist in the `tooskiezn` table, **every TXP swap will fail to record** with
HTTP 422 `"Invalid from token"` or `"Invalid to token"`, even though the on-chain transaction
succeeded.

Similarly, `GET /token-list` reads from `tooskiezn` — TXP won't appear in the frontend token
list if it is not in the DB (assuming the frontend eventually migrates to DB-driven token lists).

The `POST /fetch-multi-path-address` endpoint builds a graph from the `MultiSwapPair` table
using BFS. This table is **auto-populated** when `saveSwapResult()` runs for `multiPathStatus=0`
swaps, but that first TXP multi-hop swap will fail the BFS lookup because the edges don't exist
yet — a chicken-and-egg problem for cold-start. Solution: seed TXP pairs manually.

### 2.1 Insert TXP into the Token Registry (`tooskiezn` table)

**Method A — Via Admin Panel** (preferred, no code change):

1. Log in to admin panel → `Token → Add Token`
2. Fill in:

| Field                    | Value                                       |
|--------------------------|---------------------------------------------|
| `token_name`             | `Triple X POS Token`                        |
| `token_symbol`           | `TXP`                                       |
| `token_decimal`          | `18`                                        |
| `token_contract_address` | `0x<DEPLOYED_TXP_TOKEN_ADDRESS>`            |
| `token_image`            | Upload TXP.png                              |
| `type`                   | `manual`                                    |
| `isCoin`                 | `0` (false — it is ERC20, not native BNB)   |
| `slipToken`              | `0` (false — TXP has no transfer tax)       |
| `token_status`           | `1` (active)                                |

**Method B — Database Seeder** (for reproducible environments):

Create `database/seeders/TxpTokenSeeder.php`:

```php
<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;

class TxpTokenSeeder extends Seeder
{
    public function run(): void
    {
        DB::table('tooskiezn')->insertOrIgnore([
            'token_name'             => 'Triple X POS Token',
            'token_symbol'           => 'TXP',
            'token_decimal'          => 18,
            'token_contract_address' => '0x<DEPLOYED_TXP_TOKEN_ADDRESS>',
            'token_image'            => null,          // update after upload
            'token_status'           => '1',
            'isCoin'                 => 0,
            'slipToken'              => 0,
            'type'                   => 'manual',
            'ip_address'             => '127.0.0.1',
            'created_at'             => now(),
            'updated_at'             => now(),
        ]);
    }
}
```

Register in `DatabaseSeeder.php`:
```php
$this->call(TxpTokenSeeder::class);
```

Run: `php artisan db:seed --class=TxpTokenSeeder`

### 2.2 Seed Initial TXP Multi-Hop Pairs (`MultiSwapPair` / `nartpaws` table)

The `fetch-multi-path-address` BFS graph is built from `MultiSwapPair`. Without edges, the
graph cannot route through TXP as an intermediate node. Seed the minimal set of direct pairs
to bootstrap the graph:

> **Note:** The `MultiSwapPair` table is the obfuscated `nartpaws` table
> (see migration `2026_01_06_052348_create_nartpaws_table.php`).

Pairs to seed:

| from_symbol | to_symbol | Rationale                                  |
|-------------|-----------|---------------------------------------------|
| TXP         | LCX       | Primary manual pair — direct swap           |
| TXP         | YTC       | Primary manual pair — direct swap           |
| TXP         | USDT      | Primary manual pair — USD stablecoin        |
| TXP         | WBNB      | Manual BNB conversion pair                  |
| TXP         | ARK       | DEX passthrough — single-hop via PancakeSwap|
| TXP         | USDC      | Manual USD stablecoin pair                  |

Create `database/seeders/TxpMultiSwapPairSeeder.php`:

```php
<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use App\Models\Token;
use App\Models\MultiSwapPair;

class TxpMultiSwapPairSeeder extends Seeder
{
    private array $pairsToSeed = [
        ['TXP', 'LCX'],
        ['TXP', 'YTC'],
        ['TXP', 'USDT'],
        ['TXP', 'WBNB'],
        ['TXP', 'ARK'],
        ['TXP', 'USDC'],
    ];

    public function run(): void
    {
        foreach ($this->pairsToSeed as [$fromSymbol, $toSymbol]) {
            $fromToken = Token::where('token_symbol', $fromSymbol)->first();
            $toToken   = Token::where('token_symbol', $toSymbol)->first();

            if (!$fromToken || !$toToken) {
                $this->command->warn("Skipping {$fromSymbol}/{$toSymbol} — token not found in DB");
                continue;
            }

            // Check A→B
            $exists = MultiSwapPair::where('from_symbol', $fromSymbol)
                ->where('to_symbol', $toSymbol)
                ->exists();

            if (!$exists) {
                MultiSwapPair::create([
                    'from_token_id' => $fromToken->id,
                    'from_address'  => $fromToken->token_contract_address,
                    'from_name'     => $fromToken->token_name,
                    'from_symbol'   => $fromSymbol,
                    'from_decimal'  => $fromToken->token_decimal,
                    'to_token_id'   => $toToken->id,
                    'to_address'    => $toToken->token_contract_address,
                    'to_name'       => $toToken->token_name,
                    'to_symbol'     => $toSymbol,
                    'to_decimal'    => $toToken->token_decimal,
                    'pair'          => "{$fromSymbol}/{$toSymbol}",
                    'pairaddress'   => null,
                    'ip_address'    => '127.0.0.1',
                ]);
                $this->command->info("Seeded pair: {$fromSymbol} → {$toSymbol}");
            }
        }
    }
}
```

> **Dependency:** Run `TxpTokenSeeder` first — `TxpMultiSwapPairSeeder` resolves token IDs from
> the `tooskiezn` table. If TXP is not in DB yet, the seeder will skip TXP pairs.

### 2.3 No New API Routes or Controllers Required

The existing `SwapController` already handles TXP transparently once the token is in the DB:

- `POST /store-swap` — works as-is; validates against `tooskiezn` table
- `GET /token-list` — works as-is; fetches `tooskiezn` where `token_status = 1`
- `POST /fetch-multi-path-address` — works as-is after `MultiSwapPair` table is seeded
- `GET /swap-history` — works as-is; no token-specific filtering

### 2.4 Backend Integration Checklist

- [ ] Deploy TXPSwap contract — obtain `TXP_SWAP_CONTRACT` address and `TXP` token address
- [ ] Insert TXP into `tooskiezn` table (Method A: admin panel, Method B: seeder)
- [ ] Run `TxpTokenSeeder` if using seeder approach
- [ ] Run `TxpMultiSwapPairSeeder` to bootstrap the BFS multi-hop graph
- [ ] Verify `GET /token-list` response includes TXP in `data.tokens`
- [ ] Verify `POST /store-swap` with `from_token_symbol: "TXP"` returns 200
- [ ] Verify `POST /fetch-multi-path-address` with `from_token_symbol: "TXP", to_token_symbol: "ARK"` returns non-empty paths

---

## Project 3: `alvin_crypto_admin` (Next.js Admin Panel)

The admin panel's role in TXP integration is **operational** — setting prices and funding
liquidity on the TXPSwap contract on-chain, then logging those transactions to the backend for
audit. Three areas need changes.

### 3.1 Token Registration (No Code Change — Use Existing UI)

The admin panel already has a working token management UI at `/admin/token/add-token`. This calls
`POST /admin/tokens/add` which inserts into `tooskiezn`. **No code changes needed** — use the
existing form to add TXP. (Covered in Section 2.1 Method A above.)

### 3.2 Price Feed UI — Support TXPSwap Contract

**Current behavior:** The price-feed page (`/admin/price-feed`) calls `setPrice()` on the
**YapitSwap** contract only, then logs the transaction hash via `POST /admin/price-feed/update`.

**Required change:** Add a **Contract Selector** dropdown so the admin can choose whether to
call `setPrice()` on YapitSwap or TXPSwap.

**File:** `src/app/admin/price-feed/page.tsx` (or equivalent)

#### 3.2.1 Add Contract Selector State

```tsx
// src/app/admin/price-feed/page.tsx

const CONTRACT_OPTIONS = [
  {
    label:   "YapitSwap",
    address: "0x173781931d33306Fd04C7B15941b944c41Ab0C1A",
    abi:     SWAP_ABI,        // existing YapitSwap ABI
  },
  {
    label:   "TXPSwap",
    address: "0x<DEPLOYED_TXP_SWAP_ADDRESS>",              // ← fill after deploy
    abi:     TXP_SWAP_ABI,    // import from app/AhdfBdkfI/TXPSwapABI.json
  },
];

const [selectedContract, setSelectedContract] = useState(CONTRACT_OPTIONS[0]);
```

#### 3.2.2 Add Contract Selector Dropdown to Form

```tsx
<select
  value={selectedContract.address}
  onChange={(e) => {
    const opt = CONTRACT_OPTIONS.find(c => c.address === e.target.value);
    setSelectedContract(opt);
  }}
>
  {CONTRACT_OPTIONS.map(c => (
    <option key={c.address} value={c.address}>{c.label}</option>
  ))}
</select>
```

#### 3.2.3 On-Chain Call Uses Selected Contract

```tsx
// In the submit handler that calls setPrice() on-chain:
const swapContract = new Contract(
  selectedContract.address,
  selectedContract.abi,
  signer
);

const tx = await swapContract.setPrice(tokenAddress, priceWei);
await tx.wait();

// Log to backend:
await postRequest('/admin/price-feed/update', {
  currency_symbol:  selectedTokenSymbol,
  currency_address: tokenAddress,
  transaction_hash: tx.hash,
  transaction_mode: selectedContract.label,   // "YapitSwap" or "TXPSwap"
});
```

> **Critical:** TXP prices **must** be set on TXPSwap, not YapitSwap. Setting TXP price on
> YapitSwap will have no effect because the user's swap goes through TXPSwap.

#### 3.2.4 Required Price Settings (Minimum for TXP to function)

The admin must call `setPrice()` on TXPSwap for each manually-priced token TXPSwap handles:

| Token | Price Formula                              | Example Value       |
|-------|--------------------------------------------|---------------------|
| TXP   | `USD_price_per_token × 10^18`              | `ethers.parseUnits("0.01", 18)` → `1e16` |
| LCX   | Same — already set on YapitSwap, must also set on TXPSwap | Same value |
| YTC   | Same as above                              | Same value          |
| USDT  | Fixed: `1.0 × 10^18` = `1e18`             | `ethers.parseUnits("1", 18)` |
| USDC  | Fixed: `1.0 × 10^18` = `1e18`             | Same as USDT        |

> **Why LCX/YTC must be set on TXPSwap separately?** TXPSwap has its own independent
> `manualPrice` mapping (storage on a separate contract address). Prices set on YapitSwap are
> not accessible from TXPSwap's storage.

### 3.3 Liquidity Management UI — Support TXPSwap Contract

**Current behavior:** The liquidity page (`/admin/liquidity`) calls `addManualLiquidity()` on
**YapitSwap** only, then logs the transaction via `POST /admin/liquidity`.

**Required change:** Same contract selector pattern as price-feed.

**File:** `src/app/admin/liquidity/page.tsx` (or equivalent)

#### 3.3.1 Add Contract Selector (Same Pattern as Price-Feed)

```tsx
const [selectedContract, setSelectedContract] = useState(CONTRACT_OPTIONS[0]);
// Same CONTRACT_OPTIONS array as defined in 3.2.1
```

#### 3.3.2 On-Chain Liquidity Call Routes to Selected Contract

```tsx
const swapContract = new Contract(
  selectedContract.address,
  selectedContract.abi,
  signer
);

// ERC20 liquidity (e.g., add LCX to TXPSwap):
const tokenContract = new Contract(tokenAddress, ERC20_ABI, signer);
await (await tokenContract.approve(selectedContract.address, amountWei)).wait();
const tx = await swapContract.addManualLiquidity(tokenAddress, amountWei);
await tx.wait();

// OR: BNB liquidity:
const tx = await swapContract.addManualLiquidity(
  ethers.ZeroAddress, 0n, { value: bnbAmountWei }
);
await tx.wait();

// Log to backend:
await postRequest('/admin/liquidity', {
  type:            'add',
  amount:          humanAmount,
  currency:        tokenSymbol,
  transactionHash: tx.hash,
  // Optionally tag which contract was funded:
  // contract:     selectedContract.label,
});
```

#### 3.3.3 TXPSwap Minimum Liquidity Requirements

TXPSwap must hold its own reserves of each output token it supports for manual swaps.
These are funded separately from YapitSwap — they do not share liquidity pools.

| Token | Minimum Suggested Liquidity | Notes                                          |
|-------|-----------------------------|------------------------------------------------|
| TXP   | 1,000,000 TXP               | For LCX → TXP, YTC → TXP manual swaps         |
| LCX   | 100,000 LCX                 | For TXP → LCX manual swaps                    |
| YTC   | 100,000 YTC                 | For TXP → YTC manual swaps                    |
| USDT  | 10,000 USDT                 | For TXP → USDT manual swaps                   |
| USDC  | 10,000 USDC                 | For TXP → USDC manual swaps                   |
| BNB   | 5–10 BNB                    | For TXP → WBNB and BNB → TXP manual swaps     |

### 3.4 Swap History — No Changes Required

The admin swap history page (`/admin/swap-history`) calls `GET /admin/swap-history` which reads
from the obfuscated `nartpaws` swap table. The `SwapController@saveSwapResult` populates this
table for all tokens including TXP. The admin history view will automatically show TXP swaps once
the backend token registry accepts TXP.

**Only add TXP icon** to the admin's token icon map if it displays token logos in swap history:

```tsx
// src/app/admin/swap-history/... (wherever token logos are rendered)
import txpIcon from '../../assets/images/txp.png';  // adjust path

const tokenIcons = {
  // ...existing...
  TXP: txpIcon,
};
```

### 3.5 Admin Integration Checklist

- [ ] Add TXP token via `/admin/token/add-token` UI
- [ ] Add contract selector dropdown to price-feed page (YapitSwap / TXPSwap)
- [ ] Call `setPrice(TXP, price)` on TXPSwap via price-feed UI
- [ ] Call `setPrice(LCX, price)` on TXPSwap via price-feed UI
- [ ] Call `setPrice(YTC, price)` on TXPSwap via price-feed UI
- [ ] Call `setPrice(USDT, 1e18)` on TXPSwap via price-feed UI
- [ ] Call `setPrice(USDC, 1e18)` on TXPSwap via price-feed UI
- [ ] Add contract selector dropdown to liquidity page (YapitSwap / TXPSwap)
- [ ] Fund TXPSwap with TXP liquidity (minimum 1,000,000 TXP)
- [ ] Fund TXPSwap with LCX liquidity (minimum 100,000 LCX)
- [ ] Fund TXPSwap with YTC liquidity (minimum 100,000 YTC)
- [ ] Fund TXPSwap with USDT liquidity (minimum 10,000 USDT)
- [ ] Fund TXPSwap with BNB liquidity (minimum 5 BNB)
- [ ] Verify TXP icon renders in swap history table

---

## Projects 4 & 5: `alvin_iyap360_micro` and `alvin_iyap360_micro_front` — NO CHANGES

These are the **Iyap360 social media / marketplace platform** (Laravel 10 + Nuxt.js). They are
architecturally independent from the crypto swap system:

- No shared database with `alvin_crypto_backend`
- No shared authentication system
- No contract interaction
- No swap UI

**Zero files need to be touched in these projects.**

---

## Pre-Flight: On-Chain Contract Deployment Checklist

Before any frontend or backend work can begin, the following on-chain operations must be
completed by the **contract deployer**:

```
1. Deploy TXPToken.sol
   └── Record: TXP_TOKEN_ADDRESS

2. Deploy TXPSwap.sol with constructor args:
   ├── _txp:          TXP_TOKEN_ADDRESS
   ├── _ytc:          0x236dAE64e0174581591230fEC1F113a86B75fFa2
   ├── _lcx:          0xd5c10B78e7C274e04b213C13D2bF40F49b0006D0
   ├── _treasury:     <treasury wallet address>
   └── _platformFee:  ethers.parseUnits("0.5", 18)   // 0.5%
   └── Record: TXP_SWAP_CONTRACT_ADDRESS

3. Call TXPSwap.setPrice(TXP_ADDR,   ethers.parseUnits("0.01", 18))  // $0.01 / TXP
4. Call TXPSwap.setPrice(LCX_ADDR,   <same LCX price as YapitSwap>)
5. Call TXPSwap.setPrice(YTC_ADDR,   <same YTC price as YapitSwap>)
6. Call TXPSwap.setPrice(USDT_ADDR,  ethers.parseUnits("1", 18))
7. Call TXPSwap.setPrice(USDC_ADDR,  ethers.parseUnits("1", 18))

8. Approve + addManualLiquidity for each ERC20 token
9. addManualLiquidity(ZeroAddress, 0, { value: 5 BNB }) for BNB reserves

10. Verify: TXPSwap.activePriceFeed(TXP_ADDR)   → 0n (MANUAL)
11. Verify: TXPSwap.calcOutAmount(TXP, LCX, 1e18) → non-zero
12. Verify: TXPSwap.getPrice(TXP_ADDR) → 1e16
```

---

## Dependency Graph (All Projects)

```
[Deploy TXPSwap on-chain]
        │
        ├──────────────────────────────────────────────────────────┐
        │                                                          │
        ▼                                                          ▼
[Backend: Insert TXP into tooskiezn]                [Frontend: Add TXP_SWAP_CONTRACT address]
        │                                                          │
        ▼                                                          ▼
[Backend: Seed MultiSwapPair for TXP pairs]         [Frontend: Add TXP to tokenList]
        │                                                          │
        ▼                                                          ▼
[Backend: POST /store-swap accepts TXP]             [Frontend: Extend isNativeToken + isTxpPair]
                                                               │
        ┌──────────────────────────────────────────────────────┘
        │
        ▼
[Admin: Set prices on TXPSwap via price-feed UI]
        │
        ▼
[Admin: Fund TXPSwap liquidity via liquidity UI]
        │
        ▼
[Frontend: All swap modes functional]
        │
        ▼
[E2E Test: TXP ↔ LCX manual swap → POST /store-swap records successfully]
[E2E Test: TXP ↔ ARK DEX swap → PancakeRouter executes, history recorded]
[E2E Test: WBNB ↔ TXP manual swap → BNB reserves consumed, history recorded]
```

---

## Global Checklist Summary

### On-Chain (Contract Deployer)
- [ ] Deploy `TXPToken.sol` — record address
- [ ] Deploy `TXPSwap.sol` with correct constructor args — record address
- [ ] Set prices for TXP, LCX, YTC, USDT, USDC on TXPSwap
- [ ] Fund TXPSwap with TXP, LCX, YTC, USDT, USDC, and BNB liquidity
- [ ] Verify `activePriceFeed[TXP] == 0` (MANUAL) on-chain

### `alvin_crypto_frontend`
- [ ] `app/AhdfBdkfI/contract.js` — add `TXP_SWAP_CONTRACT`, `TXP` addresses + ABIs
- [ ] `public/assets/images/TXP.png` — add TXP icon asset
- [ ] `app/home/components/Swap.jsx` — add TXP to `tokenList` and `tokenLists`
- [ ] `app/home/components/hooks/useSwapLogic.js` — extend `isNativeToken`, add `isTxpPair`, update `fetchStaticData`, `calculate`, `swapFunction`, `Dexswap`, `checkManualLiquidity`
- [ ] `app/home/components/hooks/useDexSwapLogic.js` — add `isTxpPair` param to `getDexSwapDetails`
- [ ] `app/DeFi/swap/SwapContent.jsx` — add TXP to `tokenImages` map

### `alvin_crypto_backend`
- [ ] Insert TXP into `tooskiezn` table (admin UI or seeder)
- [ ] Create + run `TxpMultiSwapPairSeeder` to bootstrap BFS graph
- [ ] No new routes, controllers, or migrations required

### `alvin_crypto_admin`
- [ ] Add TXP via existing `/admin/token/add-token` UI
- [ ] Add contract selector (YapitSwap / TXPSwap) to price-feed page
- [ ] Add contract selector (YapitSwap / TXPSwap) to liquidity management page
- [ ] Set all required prices on TXPSwap via updated price-feed UI
- [ ] Fund TXPSwap via updated liquidity UI
- [ ] Add TXP icon to admin swap history token icon map (if applicable)

### `alvin_iyap360_micro` + `alvin_iyap360_micro_front`
- [ ] ~~No changes required~~ ✅

---

## Swap Pair Support Matrix

| From Token | To Token | Contract   | Mode       | Execution Path                        |
|-----------|----------|------------|------------|---------------------------------------|
| TXP       | LCX      | TXPSwap    | Manual     | `TXPSwap.swap([TXP, LCX], ...)`       |
| TXP       | YTC      | TXPSwap    | Manual     | `TXPSwap.swap([TXP, YTC], ...)`       |
| TXP       | USDT     | TXPSwap    | Manual     | `TXPSwap.swap([TXP, USDT], ...)`      |
| TXP       | USDC     | TXPSwap    | Manual     | `TXPSwap.swap([TXP, USDC], ...)`      |
| TXP       | WBNB     | TXPSwap    | Manual+DEX | `TXPSwap.swap([TXP, WBNB], ...)` → BNB via PancakeRouter internally |
| WBNB      | TXP      | TXPSwap    | Manual+DEX | `TXPSwap.swap([WBNB, TXP], ...)` → USD→TXP calc |
| LCX       | TXP      | TXPSwap    | Manual     | `TXPSwap.swap([LCX, TXP], ...)`       |
| YTC       | TXP      | TXPSwap    | Manual     | `TXPSwap.swap([YTC, TXP], ...)`       |
| USDT      | TXP      | TXPSwap    | Manual     | `TXPSwap.swap([USDT, TXP], ...)`      |
| TXP       | ARK      | TXPSwap    | DEX        | `TXPSwap.swapExactTokenForTokens(ROUTER, ..., [TXP, WBNB, ARK], ...)` |
| TXP       | FIST     | TXPSwap    | DEX        | `TXPSwap.swapExactTokenForTokens(ROUTER, ..., [TXP, WBNB, FIST], ...)` |
| TXP       | CAKE     | TXPSwap    | DEX        | `TXPSwap.swapExactTokenForTokens(ROUTER, ..., [TXP, WBNB, CAKE], ...)` |
| TXP       | USDA     | TXPSwap    | DEX+Slip   | `TXPSwap.swapExactTokensForTokensSupportingFeeOnTransferTokens(...)` |
| TXP       | GOT      | TXPSwap    | DEX+Slip   | Same as USDA path (GOT is FoT)        |
| ARK       | TXP      | TXPSwap    | DEX+Slip   | ARK is slipToken → FoT path           |
| LCX       | YTC      | YapitSwap  | Manual     | Unchanged — no TXP involved           |
| YTC       | USDT     | YapitSwap  | Manual     | Unchanged — no TXP involved           |
| ARK       | CAKE     | YapitSwap  | DEX        | Unchanged — no TXP involved           |

# Plan: BSC Mainnet/Testnet Network Awareness — Full Stack

## Context / Key Findings

### Current State (what's missing)
- **alvin_iyap360_micro_front**: Only `withdraw.vue` detects chainId (56/97) and sets `currentNetwork`. `swap.vue` and `buy.vue` do NOT detect network. No API call includes a `network` parameter.
- **alvin_iyap360_micro**: No `network` column in any crypto table. `Web3WalletService` proxies requests to crypto backend without forwarding network context. `notifyWithdrawCompletion()` receives `network` but discards it.
- **alvin_crypto_backend**: NO `network` column in ANY table (swaps, stakes, buys, withdraws, grants, tokens, pairs, prices). Smart scripts have hardcoded RPC behavior: `get_balance.js` + `send_tokens.js` are testnet-locked, and `fetch_missed.js` is mainnet-locked (`https://bsc-dataseed.bnbchain.org`).
- **alvin_crypto_admin**: Has dual-chain contract routing but swap/stake history pages show all transactions with no network filter/badge.
- **alvin_crypto_frontend**: Has `getConfig(chainId)` routing but API calls (`store-swap`, `store-stake`) send no `network` param.

### Network value convention
- `network = 'mainnet'` (chainId 56) or `network = 'testnet'` (chainId 97, default fallback)
- Frontend detects chainId → maps to 'mainnet'|'testnet' → includes in every API call
- Custodial wallets: same keypair works on both networks (no wallet recreation needed)
- Token prices: shared across networks (same USD value) unless admin overrides

### RPC URLs
- Mainnet: `https://bsc-dataseed.bnbchain.org` (or pool)
- Testnet: `https://bsc-testnet-dataseed.bnbchain.org` (or pool)

---

## Plan Phases

### Phase 1 — DB Migrations (alvin_crypto_backend) [BLOCKING — must complete first]
Tables needing `network VARCHAR(10) DEFAULT 'testnet'` column:
1. `nartpaws` (swaps)
2. `noitcasnartekats` (stakes)
3. `token_buy_orders`
4. `token_withdraw_orders`
5. `crypto_wallet_creation_grants`
6. `tooskiezn` (tokens) — to allow per-network contract addresses + seed mainnet data
7. `riappawsitlum` (multi-swap pairs) — per-network routing graph

- `tsohkaevnpsrhiece` (token prices) — YES: `currency_address` differs per network; lookup must return the right contract address for the active chain
- `current_block` — YES: block numbers are per-chain; need one cursor row per network for event indexing
- `deefecirp` (PriceFeed) — YES: pricing mode (DEX vs Manual) + `currency_address` + `transaction_hash` are all chain-specific; admin sets this per network
- `eefekats` (StakeFee) — YES: fee is set on-chain per contract; `transaction_hash` belongs to a specific chain
- `ljfoeufwlamnxdv` (Liquidity) — YES: liquidity operations are per-chain; `transactionHash` is network-specific
- `ofniekats` (StakeInfor) — YES: stake config written to a specific chain's contract; `address` + `transaction_hash` are network-specific
- `platformfee` — YES: fee is set on-chain per contract; `transactionHash` is network-specific

### Phase 2 — Smart Scripts (alvin_crypto_backend/smart/) [parallel with Phase 1]
Goal: make every script network-aware via explicit runtime inputs (no hardcoded chain).

2.1 Script contract updates
- `get_balance.js`
  - Input schema: `{ walletAddress, contractAddress, decimals, rpc_url, network, request_id }`
  - Require `rpc_url` (or fail fast with validation error)
  - Keep fallback RPC pool as same-network fallback only (optional but recommended)
- `send_tokens.js`
  - Input schema: `{ contractAddress, toAddress, amountWei, privateKey, commissionAmountWei, treasuryAddress, rpc_url, network, request_id }`
  - Use provided `rpc_url`; log resolved chain id before sending tx
  - Return payload includes `network`, `chainId`, `rpc_url_used`, `txHash`, `commissionTxHash`
- `fetch_missed.js`
  - Replace hardcoded `RPC = "https://bsc-dataseed.bnbchain.org"`
  - Accept CLI args with explicit rpc: `node fetch_missed.js <fromBlock> <toBlock> <contractAddress> <network> <rpc_url>`
  - Enforce fail-fast if `rpc_url` is missing
  - Include `network` and `chainId` in every output row so reconciler stores correct-chain data

2.2 Centralized PHP RPC config (single source of truth)
- Add one shared config file: `config/rpc_registry.php` (no RPC env vars)
  - structure example:
    - `return [ 'selection_policy' => 'first_available', 'mainnet' => [ ['url' => '...', 'enabled' => true, 'priority' => 1], ... ], 'testnet' => [ ... ] ];`
- Add shared resolver helper in backend service layer that reads only this PHP config:
  - `getRpcPool(network): array` (returns validated, enabled endpoints)
  - `pickRpc(network, attempt=0): string` (policy-driven endpoint selection)
  - `reportRpcFailure(network, rpcUrl): void` (optional health tracking/circuit-breaker)
- Node scripts (`get_balance.js`, `send_tokens.js`, `fetch_missed.js`) must always receive `rpc_url` from PHP after PHP resolves it from `config/rpc_registry.php`.
- Standalone script usage: pass `rpc_url` explicitly via args/payload; scripts do not read registry files directly.

2.3 Job-to-script wiring
- Jobs passing runtime payload to scripts (`GetBalanceJob`, `SendTokensJob`, `SendWithdrawJob`, `SendWalletCreationGrantJob`) must include:
  - `network`
  - `rpc_url` (resolved once in PHP before spawn)
  - `request_id` for traceability
- Standardize script execution response format so all jobs parse the same keys.

2.4 Reliability and safety rules
- Validate `network in [mainnet, testnet]` before spawn
- Validate contract address exists for that network in DB/config before script call
- Add timeout + retry with same-network fallback RPC only
- Never log private keys; sanitize payload logging

2.5 Verification for Phase 2
- Test 1: run each script with `network=testnet` and assert chain id 97 in response
- Test 2: run each script with `network=mainnet` and assert chain id 56 in response
- Test 3: intentionally pass wrong rpc/network combination and assert script hard-fails
- Test 4: run `fetch_missed.js` on both networks for same block range and verify output is tagged by network

### Phase 3 — Backend Controller/Service Updates (alvin_crypto_backend) [depends on Phase 1+2]
Controller coverage is split into required, and no-change groups.

Required controller changes (must do for network correctness)
- `app/Http/Controllers/IcoEventController.php`
  - make recover flow network-aware, pass network + rpc_url to `fetch_missed.js`, and track `current_block` per network
  - store `network` on recovered Swap/Stake rows
- `app/Http/Controllers/Frontend/SwapController.php`
  - `saveSwapResult()`, `fetchToken()`, `fetchPair()`, `swapHistory()` use network-scoped reads/writes
- `app/Http/Controllers/Frontend/StakeController.php`
  - `saveStakeResult()`, `stakeHistory()` use network-scoped reads/writes
- `app/Http/Controllers/Frontend/CryptoBuyController.php`
  - `receiveBuyFulfillment()` persists network and passes network-resolved rpc to jobs
- `app/Http/Controllers/Frontend/CryptoWithdrawController.php`
  - `receiveWithdrawFulfillment()` and `requestWalletBalances()` persist/use network and pass network-resolved rpc
- `app/Http/Controllers/Frontend/CryptoActivityController.php`
  - merged activity query filtered/tagged by network
- `app/Http/Controllers/Frontend/WalletCreationGrantController.php`
  - persist network on grant records and make idempotency checks network-aware
- `app/Http/Controllers/Admin/TokenController.php` and `app/Http/Controllers/Admin/SwapPairController.php`
  - create/list operations scoped by network for token contracts and swap pairs
- `app/Http/Controllers/Admin/TokenPriceController.php` and `app/Http/Controllers/Admin/PriceFeedController.php`
  - store/filter price and feed history by network
- `app/Http/Controllers/Admin/LiquidityController.php`
  - store/filter liquidity and platform fee operations by network
- `app/Http/Controllers/Admin/StakeController.php`
  - store/filter stake settings and fee settings by network

No Phase 3 change needed (unless product scope expands)
- Root: `Controller.php`, `Test.php`, `LogoutExpiredTokenController.php`
- Frontend: `AuthController.php`, `HomeController.php`
- Admin: `AuthController.php`, `FrontendUserController.php`, `SettingsController.php`, `HomeController.php`, `FaqController.php`, `CmsController.php`, `AdminWhiteListController.php`, `AdminBlockIpAddressController.php`

Service updates aligned to required controllers
- `app/Services/TokenBuyService.php` (REQUIRED)
  - add `network` to method inputs and DB writes
  - scope idempotency checks by `(idempotency_key, network)`
  - resolve rpc via PHP registry resolver and pass `network + rpc_url` to `SendTokensJob`
- `app/Services/TokenWithdrawService.php` (REQUIRED)
  - add `network` to `getWalletBalances()`, `requestWalletBalances()`, `receiveWithdrawFulfillment()`
  - scope token/price/order lookups by network
  - scope cache/request IDs and idempotency checks by network
  - pass `network + rpc_url` to `GetBalanceJob` and `SendWithdrawJob`
- `app/Services/WalletCreationGrantService.php` (REQUIRED)
  - add `network` to grant fulfillment flow and persist on `crypto_wallet_creation_grants`
  - scope idempotency checks by `(idempotency_key, network)`
  - pass `network + rpc_url` to `SendWalletCreationGrantJob`
- `app/Services/IcoEventService.php` or equivalent event-recovery service paths (REQUIRED)
  - remove hardcoded RPC list and contract assumptions
  - use `config/rpc_registry.php` resolver for selected network
  - enforce per-network `current_block` cursor handling and store recovered rows with network
- `app/Services/TreasuryTransferService.php` (REQUIRED if used in active transfer path)
  - add `network` to send methods
  - scope token contract lookups by network
  - pass network-resolved `rpc_url` into script/process execution
- `app/Services/KmsService.php` (NO CHANGE)
  - remains network-agnostic encryption utility

### Phase 4 — DB Migrations (alvin_iyap360_micro) [parallel with Phase 1]
- Add `network VARCHAR(10) DEFAULT 'testnet'` to `crypto_wallet_withdraw_orders`
- (crypto_wallets table: no change needed — wallet address is chain-agnostic)

### Phase 5 — Micro API Updates (alvin_iyap360_micro) [depends on Phase 4]
- All `FormRequest` classes: add `network` validation (required|in:mainnet,testnet or optional with default 'mainnet')
- `Web3WalletService`: forward `network` in all proxy calls to crypto backend
  - `withdrawToken()`, `buyTokensWithCard()`, `storeSwap()`, `storeStake()`, `getWithdrawBalance()` (balance polling)
- `Web3WalletRepository`: include `network` in fulfillment payloads
- `cryptoActivity()` endpoint: accept + forward `network` filter param

### Phase 6 — Nuxt Frontend (alvin_iyap360_micro_front) [depends on Phase 5]
Page-level updates
- `pages/crypto/swap.vue`: Add `currentNetwork` ref + `resolveNetwork(chainId)` + `watchAccount` (same pattern as `withdraw.vue`)
- `pages/crypto/buy.vue`: Add `currentNetwork` detection and pass network in breakdown/purchase flow payloads
- `pages/crypto/index.vue`: Pass `network` to activity/balance fetch calls

Composable updates in `composables/crypto/`
- `composables/crypto/useSwapLogic.ts` (REQUIRED)
  - include `network` in both manual and dex `storeSwap` calls
  - derive network from signer/provider chainId and keep fallback mapping deterministic
- `composables/crypto/useDexSwapLogic.ts` (REQUIRED)
  - include `network` in `fetchMultiPathAddress` payload
  - include `network` in dex swap persistence payload path used by `useSwapLogic`
- `composables/crypto/useWithdrawLogic.ts` (REQUIRED)
  - include `network` in `getWalletBalances`, `getWithdrawBreakdown`, and `withdrawToken` payloads
- `composables/crypto/useTransactionHistory.ts` (REQUIRED)
  - include `network` in `cryptoActivity` fetch requests and pagination/refetch calls
- `composables/crypto/useEthersSigner.ts` (RECOMMENDED)
  - expose a normalized `network`/`chainId` computed to avoid duplicate mapping logic in pages/composables
- `composables/crypto/useWalletData.ts` (NO CHANGE)
  - keep as UI state store only unless network-scoped caching is introduced later

Service client updates used by composables/pages
- `services/modules/Liquidcash/Crypto/Wallet/WalletService.ts`: add `network` param to `getWalletBalances`, `getWithdrawBreakdown`, `purchaseToken`, `withdrawToken`, `cryptoActivity`
- `services/modules/Liquidcash/Crypto/Swap/SwapService.ts`: add `network` param to `fetchMultiPathAddress`, `storeSwap`, `storeStake`, `swapHistory`

### Phase 7 — Next.js Public Frontend (alvin_crypto_frontend) [depends on Phase 3, parallel with Phase 6]
Centralized frontend network mechanism (single source of truth)
- Keep `app/AhdfBdkfI/contract.js` as the frontend address registry and expand it to hold all mainnet/testnet smart contract addresses and token/ABI mappings.
  - This file remains the source of truth for frontend contract addresses.
  - Do not replace it with a new registry file; refactor consumers to import from it.
- Add only lightweight helpers around that registry if needed:
  - `getConfig(chainId)` continues to return the correct network address set
  - optional helper exports for `getNetworkKey(chainId)`, `getContractAddress(chainId, key)`, `getTokenMeta(chainId, symbol)`
- Keep chain metadata in the existing wagmi/AppKit network layer:
  - `app/config_wagmi/index.tsx` and `app/context_wagmi/index.tsx` continue to define supported networks (`bsc`, `bscTestnet`)
  - frontend consumes chainId from wallet/AppKit and maps it to the registry
- RPC URLs are not maintained locally in the frontend:
  - wallet/AppKit transport uses the connected wallet/provider
  - if dedicated read RPCs are needed later, add them only as derived data in the frontend config layer, not as separate environment-maintained endpoints

Flow updates using centralized registry
- `useSwapLogic.js`:
  - `buildTokenLists(chainId)` must continue to call `getConfig(chainId)` from `app/AhdfBdkfI/contract.js`
  - `useEthersSigner({ chainId })` should resolve the signer on the active chain and feed that chainId into `getConfig`
  - when persisting swaps, include `network` derived from the same chainId used by `getConfig`
- `useDexSwapLogic.js` (REQUIRED):
  - `liquidityCheck(params)` must receive `addresses` and `abis` from the same `getConfig(chainId)` result used by `useSwapLogic`
  - `getDexSwapDetails(...)` must consume registry-derived `addresses`/`abis` only; no duplicate hardcoded contract constants
  - include `network` in multi-path API payloads (`checkMultiPairApi`) so backend returns network-correct paths
  - avoid implicit assumptions around WBNB/BNB mapping by using registry token metadata from `contract.js`
- `useStakeActions.js`:
  - resolve the active network from the connected chainId before signing the claim transaction
  - include `network` in the stake history/API payload returned by `useClaimStake`
- `swapapi.js`: accept optional `network` arg and pass through consistently for all crypto API methods
- `pages/crypto/swap.vue`, `buy.vue`, `index.vue`, `dashboard.vue`: pass the active chainId/network into the composables so they all use the same registry-derived config
- UI history views: show `network` badge and optionally filter by network key from the registry
- `SlippageSettings.jsx` (NO CHANGE by default): remains presentation-only; optional improvement is to show unsupported-network notice from parent state

Guardrails
- Fail-fast on unsupported chainId (disable actions + clear message)
- Do not hardcode contract addresses or explorer URLs outside registry module
- Add helper `getNetworkConfig(chainId)` and `getContractAddress(chainId, key)` and use everywhere

### Phase 8 — Admin (alvin_crypto_admin) [depends on Phase 3, parallel with Phases 6-7]
Centralized admin config using existing files only
- Keep and use existing files as single sources:
  - `src/app/lib/chain.js` = centralized chain IDs + RPC pools + default chain + explorer base URLs by chain
  - `src/app/web3/contract-address.js` = centralized smart contract addresses per chain
- Refactor consumers to import only from these two files:
  - `src/app/utils/get-provider.js` should derive provider RPC from `PUBLIC_NODES` (remove local `RPC` object duplication)
  - all admin web3 logic/pages should use `getContracts(chain)` from `contract-address.js` (no inline contract literals)
  - all tx-link builders should use `getExplorerTxUrl(chainId, txHash)` from `chain.js` (no `NEXT_PUBLIC_HASH_URL`)

Hardcoded + env-var cleanup pass (must-do in Phase 8)
- Remove/replace any inline mainnet/testnet RPC URL literals outside `chain.js`
- Remove/replace any inline non-zero contract address literals outside `contract-address.js`
- Remove frontend env var usage for chain infra in admin app:
  - remove `process.env.NEXT_PUBLIC_RPC_URL` usage (currently in `src/app/admin/token/add-token/page.jsx`)
  - remove `process.env.NEXT_PUBLIC_HASH_URL` usage from history pages and replace with `chain.js` explorer helper
  - `NEXT_PUBLIC_TESTNET_RPC_URL` / `NEXT_PUBLIC_RPC_URL` / `NEXT_PUBLIC_HASH_URL` become obsolete for admin web3 routing after this refactor
- Keep a single exported `ZERO_ADDRESS` constant in `contract-address.js` and import it where needed (e.g., liquidity pages/helpers) instead of repeating the literal
- Update files with known drift risks:
  - `src/app/admin/liquidity/add/page.jsx`
  - `src/app/admin/liquidity/remove/page.jsx`
  - `src/app/admin/liquidity/contract.js`
  - `src/app/admin/token/add-token/page.jsx`
  - `src/app/admin/swap-history/page.jsx`
  - `src/app/admin/stake/history/page.jsx`
  - `src/app/admin/fee/history/page.jsx`
  - `src/app/admin/fee/stake-history/page.jsx`
  - `src/app/admin/stake/info-history/page.jsx`
  - `src/app/admin/price-feed/history/page.jsx`
  - `src/app/admin/currency-price/history/page.jsx`

UI/admin flow updates
- Add a global network indicator in the admin shell/header (visible on every admin page): `BSC Mainnet` or `BSC Testnet`, color-coded and derived from active wallet chain id.
- `dashboard/page.jsx`: make `Liquidity View` and `Token View` explicitly network-aware (show counts for active network only) and render a network badge in each card header.
- `swap-history/page.jsx`: add network filter dropdown + network badge per row/header; history query must include network.
- `stake/history/page.jsx`: add network filter dropdown + network badge per row/header; history query must include network.
- `liquidity/history/page.jsx`, `fee/history/page.jsx`, `fee/stake-history/page.jsx`, `stake/info-history/page.jsx`, `price-feed/history/page.jsx`, `currency-price/history/page.jsx`: update data fetching and tx links to be network-aware (active chain and/or explicit network filter) and show network label near table title or filter bar.
- `token/list-token/page.jsx`: make token list network-scoped (active network or explicit filter) so contract addresses shown belong to selected chain.
- API client layer includes `network` query/body where needed for all filtered admin history/config views, not only swap/stake.
- Explorer links across all history/config tables must be generated from chain helper (`getExplorerTxUrl(chainId, txHash)`), never from env hash url.


Phase 8 execution checklist (implementation-ready)
- Shared prerequisites (apply first):
  - `src/app/lib/chain.js`: add `NETWORK_META` and helper exports `getNetworkKey(chainId)`, `getNetworkLabel(chainId)`, `getNetworkBadgeTone(chainId)`, `getExplorerTxUrl(chainId, txHash)`.
  - `src/app/admin/api/apiAuthantication.jsx`: add optional `network` passthrough for dashboard, token list, and all history list hooks.
  - Request contract: FE sends `network=mainnet|testnet`; BE returns rows scoped by that network (plus row `network` when available).
- Global visual indicator:
  - `src/components/layout/adminHeader.jsx`: show persistent network badge near wallet address.
  - Badge spec: `BSC Mainnet` (green) / `BSC Testnet` (amber); unsupported chain shows `Unsupported Network` (red) and disables write actions where applicable.
- Dashboard:
  - `src/app/admin/dashboard/page.jsx`: include active `chainId` and derived `network` in `useDashboard` request.
  - In `Liquidity View` and `Token View`, show network badge and ensure values (`liquidityCount`, `addLiquidityCount`, `removeLiquidityCount`, `totalTokens`, `activeTokenCount`, `swapCount`) are active-network scoped.
  - Optional UX guard: if API still returns aggregate-only data, show warning label `Unscoped data` until backend filter lands.
- Token list:
  - `src/app/admin/token/list-token/page.jsx`: include `network` in `useGetToken` query; optionally add explicit network dropdown defaulted from active chain.
  - Show small network chip above table and ensure copied contract addresses are from active/selected network dataset.
- History pages (data + UI indicator + explorer):
  - `src/app/admin/swap-history/page.jsx`: pass `network` to query, add network filter, render network badge column (or row tag), use `getExplorerTxUrl(chainId, hash)`.
  - `src/app/admin/stake/history/page.jsx`: pass `network` to query, add network filter, render network badge, use `getExplorerTxUrl(chainId, hash)`.
  - `src/app/admin/liquidity/history/page.jsx`: pass `network` to query, add network label/filter in toolbar, replace env hash URL with chain helper.
  - `src/app/admin/fee/history/page.jsx`: pass `network` to query, add network label/filter in toolbar, replace env hash URL with chain helper.
  - `src/app/admin/fee/stake-history/page.jsx`: pass `network` to query, add network label/filter in toolbar, replace env hash URL with chain helper.
  - `src/app/admin/stake/info-history/page.jsx`: pass `network` to query, add network label/filter in toolbar, replace env hash URL with chain helper.
  - `src/app/admin/price-feed/history/page.jsx`: pass `network` to query, add network label/filter in toolbar, replace env hash URL with chain helper.
  - `src/app/admin/currency-price/history/page.jsx`: pass `network` to query, add network label/filter in toolbar, replace env hash URL with chain helper.
- Liquidity actions (consistency with indicator):
  - `src/app/admin/liquidity/add/page.jsx` and `src/app/admin/liquidity/remove/page.jsx`: show active network badge near page title and keep token/contract routing tied to `chainId` + `getContracts(chain)`.
- Definition of done for Phase 8:
  - No `process.env.NEXT_PUBLIC_HASH_URL` references remain in admin pages.
  - No `process.env.NEXT_PUBLIC_RPC_URL`/`NEXT_PUBLIC_TESTNET_RPC_URL` usage remains for chain routing.
  - Dashboard Liquidity/Token sections visibly show active network and fetch active-network-scoped data.
  - All admin history/config tables show visible network context and open tx links in the correct explorer for active chain.
  - Unsupported chain displays clear error state and blocks submissions.

Guardrails
- fail-fast on unsupported chain id
- no hardcoded RPC URLs outside `chain.js`
- no hardcoded non-zero contract addresses outside `contract-address.js`
- helper APIs remain: `getRpcPool(chainId)`, `getProviderRpc(chainId)`, `getContracts(chainId)`

### Phase 9 — Seeding Network Data (alvin_crypto_backend) [depends on Phase 1]
- Seed `tooskiezn` with BOTH network datasets:
  - mainnet token entries (TXP, YTC, LCX, BNB, USDT, USDC, etc. with mainnet contract addresses)
  - testnet token entries (tBNB/TXP/YTC/LCX and any testnet-supported stables with testnet contract addresses)
- Seed `riappawsitlum` with BOTH network routing graphs:
  - mainnet swap pairs using mainnet contract addresses
  - testnet swap pairs using testnet contract addresses
- Add uniqueness/idempotency guard for seed data by `(network, token_symbol)` and `(network, from_token, to_token)` (or equivalent pair key) to avoid duplicate rows across reruns.
- Verify/update `tsohkaevnpsrhiece` strategy:
  - if prices are global, confirm reads remain deterministic when token contract differs by network
  - if prices are network-scoped, seed/update per-network rows with explicit `network`.
---

## Relevant Files

### alvin_crypto_backend
- `database/migrations/` — new migration files per table
- `smart/get_balance.js`, `smart/send_tokens.js`, `smart/fetch_missed.js` — make network-aware and remove hardcoded RPCs
- `app/Http/Controllers/Frontend/SwapController.php`
- `app/Http/Controllers/Frontend/StakeController.php`
- `app/Http/Controllers/Frontend/CryptoBuyController.php`
- `app/Http/Controllers/Frontend/CryptoWithdrawController.php`
- `app/Http/Controllers/Frontend/CryptoActivityController.php`
- `app/Services/TokenBuyService.php`, `app/Services/TokenWithdrawService.php`, `app/Services/WalletCreationGrantService.php`
- `app/Services/IcoEventService.php`, `app/Services/TreasuryTransferService.php`, `app/Services/KmsService.php` (Kms expected no-change)
- `app/Jobs/SendTokensJob.php`, `SendWithdrawJob.php`, `GetBalanceJob.php`, `SendWalletCreationGrantJob.php`
- `config/rpc_registry.php` — centralized mainnet/testnet RPC registry config
- `app/Support/RpcRegistry.php` (or equivalent service) — loads and selects RPC endpoint from PHP config

### alvin_iyap360_micro
- `package/iyap360/crypto-wallet/database/migrations/` — new migration for withdraw_orders
- `package/iyap360/crypto-wallet/src/Services/Web3WalletService.php`
- `package/iyap360/crypto-wallet/src/Repositories/Web3WalletRepository.php`
- `package/iyap360/crypto-wallet/src/Http/Requests/` — update FormRequests
- `package/iyap360/crypto-wallet/src/Http/Controllers/Web3WalletController.php`

### alvin_iyap360_micro_front
- `pages/crypto/swap.vue`
- `pages/crypto/buy.vue`
- `pages/crypto/index.vue`
- `pages/crypto/dashboard.vue` (recommended alignment)
- `composables/crypto/useSwapLogic.ts`
- `composables/crypto/useDexSwapLogic.ts`
- `composables/crypto/useWithdrawLogic.ts`
- `composables/crypto/useTransactionHistory.ts`
- `composables/crypto/useEthersSigner.ts` (recommended helper normalization)
- `composables/crypto/useWalletData.ts` (no-change unless network cache added)
- `services/modules/Liquidcash/Crypto/Wallet/WalletService.ts`
- `services/modules/Liquidcash/Crypto/Swap/SwapService.ts`

### alvin_crypto_frontend
- `app/AhdfBdkfI/contract.js` (keep as the centralized frontend address registry; expand with all mainnet/testnet addresses and token metadata)
- `app/config_wagmi/index.tsx` and `app/context_wagmi/index.tsx` (keep network definitions in AppKit/wagmi layer; no local RPC registry)
- `app/lib/chain.js` (refactor only if needed to consume contract registry helpers)
- `app/home/components/hooks/useSwapLogic.js`
- `app/home/components/hooks/useDexSwapLogic.js` (required network propagation + registry usage)
- `app/home/components/hooks/useStakeActions.js`
- `app/home/components/hooks/api/swapapi.js`
- `app/home/components/hooks/SlippageSettings.jsx` (no-change by default)

### alvin_crypto_admin
- `src/app/lib/chain.js` (single source for chain IDs, RPC pools, and explorer mapping)
- `src/app/web3/contract-address.js` (single source for smart contract addresses)
- `src/app/utils/get-provider.js` (consume `chain.js`; remove local RPC duplication)
- `src/components/layout/adminHeader.jsx` (add global network indicator/badge in admin shell)
- `src/app/admin/dashboard/page.jsx` (network-aware Liquidity View + Token View cards)
- `src/app/admin/token/list-token/page.jsx` (network-scoped token list + address context)
- `src/app/admin/liquidity/history/page.jsx` (network-aware history query + explorer links + network label)

- `src/app/admin/liquidity/contract.js` (import `ZERO_ADDRESS` and `getContracts`; remove literals)
- `src/app/admin/liquidity/add/page.jsx` (remove inline ZERO_ADDRESS literal)
- `src/app/admin/liquidity/remove/page.jsx` (remove inline ZERO_ADDRESS literal)
- `src/app/admin/token/add-token/page.jsx` (remove `NEXT_PUBLIC_RPC_URL` fallback assumption)
- `src/app/admin/swap-history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/stake/history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/fee/history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/fee/stake-history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/stake/info-history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/price-feed/history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/currency-price/history/page.jsx` (replace `NEXT_PUBLIC_HASH_URL` tx links)
- `src/app/admin/api/apiAuthantication.jsx` (add network filter passthrough where needed)

---

## Decisions & Scope Boundaries

- **Custodial wallets**: Same EVM keypair works on mainnet and testnet. No new wallet creation needed. Grant (500 YTC) is network-scoped: a user can receive one registration grant on testnet and one on mainnet (max one per network).
- **Grant uniqueness rule**: enforce one-time grant per user per network (recommended key: `(user_id, grant_type, network)`; optional include wallet address). This prevents duplicate grants on the same chain while allowing separate chain-specific grants.
- **`network` default**: All new records default to 'mainnet' (backward compatible with existing data), but seed baselines must exist for both mainnet and testnet token/pair datasets.
- **tBNB vs BNB**: `tokenSymbol = 'tBNB'` used on testnet, `'BNB'` on mainnet — this existing pattern remains; balance queries pass `nativeSymbol` based on network.

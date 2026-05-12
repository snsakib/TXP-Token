Read [](file:///home/snsakib/Projects/Kaz/alvin_txp_token/contracts/TXPToken.sol#1-1), lines 1 to 100

Read [](file:///home/snsakib/Projects/Kaz/alvin_txp_token/contracts/YTCToken.sol)

Read [](file:///home/snsakib/Projects/Kaz/alvin_txp_token/contracts/LCXToken.sol)

Read [](file:///home/snsakib/Projects/Kaz/alvin_txp_token/contracts/YapitSwap.sol#1-1), lines 1 to 300

Read [](file:///home/snsakib/Projects/Kaz/alvin_txp_token/contracts/TXPSwap.sol#1-1), lines 1 to 300

Here's a summary of each contract:

---

### `TXPToken` (TXP)
The core utility token of the iYap Global ecosystem. A custom ERC-20 (no OpenZeppelin) with a **fixed 1 billion supply** minted entirely to the deployer. Features owner-controlled **pause** (halts all transfers), **blacklisting** (blocks specific addresses), and user-initiated **burn**. Includes safe ownership transfer/renounce and `increaseAllowance`/`decreaseAllowance` helpers.

---

### `LiquidCashToken` (LCX)
A minimal OZ v5 ERC-20 built on `ERC20Burnable` + `Ownable`. Mints **1 billion LCX** to the owner at deployment. The owner can **mint additional tokens** at any time via `mint()`. Token holders can burn their own tokens.

---

### `YapitToken` (YTC)
Structurally identical to LCX. An OZ v5 ERC-20 with `ERC20Burnable` + `Ownable`, minting **1 billion YTC** to the owner on deploy. Owner can mint more; holders can burn.

---

### `YapitSwap`
A DEX-style swap contract for **YTC ↔ LCX** trades, extended with a full **staking system**. Uses OZ v5 `Pausable`, `ReentrancyGuard`, and `Ownable`. Supports dual price feeds (manual USD price or live PancakeSwap DEX price). Platform fees are collected and forwarded to a treasury. Staking allows users to lock YTC or LCX for a configured period/rate, with an early-unstake fee. The owner can configure stake parameters (min/max/rate/period), update token addresses, add/remove liquidity, and switch price feeds.

---

### `TXPSwap`
Mirrors `YapitSwap` but handles **TXP ↔ LCX, TXP ↔ YTC, and LCX ↔ YTC** swaps — with **no staking**. Output tokens go directly to the recipient. Same dual price feed system (manual/DEX via PancakeRouter), platform fee to treasury, owner-managed liquidity, and pause/reentrancy guards. Adds TXP as a tracked token (extending the `TokenFeed` enum) and validates constructor inputs more strictly.

---

### `TokenSwap`
Unified replacement for both `YapitSwap` and `TXPSwap`. Handles all three pairs — **TXP ↔ LCX, TXP ↔ YTC, and LCX ↔ YTC** — with **no staking**. Uses OZ v5 `Pausable`, `ReentrancyGuard`, and `Ownable`. Supports dual price feeds (manual USD cross-rate or live PancakeSwap DEX price). Platform fees go to a configurable treasury. The `swap()` function sends output tokens directly to the recipient. Includes the full suite of PancakeRouter passthrough functions (including fee-on-transfer variants). Owner can manage liquidity, update token/router/treasury addresses, and toggle price feeds per token. Default manual prices: TXP = $0.01, YTC = $1.00, LCX = $0.50.
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Hardhat Ignition deployment module for TXPSwap.
 *
 * Assumes TXPToken, YapitToken (YTC), and LiquidCashToken (LCX) are already deployed.
 *
 * BSC Testnet addresses (defaults):
 *   TXP  : 0x80a30378Bd7Dc053B360163e75420745460Aa486
 *   YTC  : 0x42dA837faAf4Cb4Dd808f771bDf0C9D238Ca6AA1
 *   LCX  : 0x1bDE88fe36c60CE523fE5ad683b8568D59421604
 *
 * Deploy:
 *   npx hardhat ignition deploy ignition/modules/TXPSwap.ts \
 *     --network bscTestnet \
 *     --deployment-id txp-swap \
 *     --parameters '{"TXPSwapModule":{"treasury":"0xYOUR_TREASURY","platformFee":"1000000000000000000"}}'
 */
export default buildModule("TXPSwapModule", (m) => {
  // ── Token addresses (defaults = BSC testnet) ───────────────────────────────
  const txp = m.getParameter<string>("txp", "0x80a30378Bd7Dc053B360163e75420745460Aa486");
  const ytc = m.getParameter<string>("ytc", "0x42dA837faAf4Cb4Dd808f771bDf0C9D238Ca6AA1");
  const lcx = m.getParameter<string>("lcx", "0x1bDE88fe36c60CE523fE5ad683b8568D59421604");

  // ── Parameters ─────────────────────────────────────────────────────────────
  const treasury = m.getParameter<string>("treasury");

  const platformFee = m.getParameter<bigint>(
    "platformFee",
    1_000_000_000_000_000_000n, // 1e18 = 1%
  );

  // ── Deploy TXPSwap ─────────────────────────────────────────────────────────
  const txpSwap = m.contract("TXPSwap", [
    m.getAccount(0), // owner = deployer wallet
    txp,             // TXP token address
    ytc,             // YTC token address
    lcx,             // LCX token address
    treasury,        // fee recipient
    platformFee,     // platform fee
  ]);

  return { txpSwap };
});

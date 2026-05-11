import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Hardhat Ignition deployment module for YapitSwap.
 *
 * Assumes YapitToken (YTC) and LiquidCashToken (LCX) are already deployed.
 * Pass their addresses as parameters.
 *
 * Parameters (override via --parameters at CLI):
 *   ytc         - deployed YapitToken address (REQUIRED)
 *   lcx         - deployed LiquidCashToken address (REQUIRED)
 *   treasury    - address that receives platform fees (REQUIRED)
 *   platformFee - fee in 1e18 precision; 1e18 = 1% (default: 1%)
 *   unStakeFee  - unstake fee in 1e18 precision (default: 0)
 *
 * Deploy:
 *   npx hardhat ignition deploy ignition/modules/YapitSwap.ts \
 *     --network bscTestnet \
 *     --parameters '{"YapitSwapModule":{"ytc":"0xYTC","lcx":"0xLCX","treasury":"0xTreasury","platformFee":"1000000000000000000","unStakeFee":"0"}}'
 */
export default buildModule("YapitSwapModule", (m) => {
  // ── Parameters ──────────────────────────────────────────────────────────────
  const ytc = m.getParameter<string>("ytc");
  const lcx = m.getParameter<string>("lcx");

  const treasury = m.getParameter<string>("treasury");

  const platformFee = m.getParameter<bigint>(
    "platformFee",
    1_000_000_000_000_000_000n, // 1e18 = 1%
  );

  const unStakeFee = m.getParameter<bigint>(
    "unStakeFee",
    0n,
  );

  // ── Deploy YapitSwap ────────────────────────────────────────────────────────
  const yapitSwap = m.contract("YapitSwap", [
    m.getAccount(0), // owner = deployer wallet
    ytc,             // YTC token address
    lcx,             // LCX token address
    treasury,        // fee recipient
    platformFee,     // platform fee
    unStakeFee,      // unstake fee
  ]);

  return { yapitSwap };
});

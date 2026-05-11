import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Hardhat Ignition deployment module for YapitToken (YTC).
 *
 * Deploy:
 *   npx hardhat ignition deploy ignition/modules/YTCToken.ts --network bscTestnet
 */
export default buildModule("YTCTokenModule", (m) => {
  const ytcToken = m.contract("YapitToken", [m.getAccount(0)]);

  return { ytcToken };
});

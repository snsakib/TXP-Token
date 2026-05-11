import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Hardhat Ignition deployment module for LiquidCashToken (LCX).
 *
 * Deploy:
 *   npx hardhat ignition deploy ignition/modules/LCXToken.ts --network bscTestnet
 */
export default buildModule("LCXTokenModule", (m) => {
  const lcxToken = m.contract("LiquidCashToken", [m.getAccount(0)]);

  return { lcxToken };
});

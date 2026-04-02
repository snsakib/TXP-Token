import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Hardhat Ignition deployment module for the Triple X POS Token (TXP).
 *
 * The constructor mints the entire fixed supply of 1,000,000,000 TXP to
 * the deployer address; no additional configuration parameters are needed.
 */
export default buildModule("TXPTokenModule", (m) => {
  const txpToken = m.contract("TXPToken");

  return { txpToken };
});

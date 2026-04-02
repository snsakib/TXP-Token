import "dotenv/config";
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    ...(process.env.SEPOLIA_RPC_URL && process.env.SEPOLIA_PRIVATE_KEY
      ? {
          sepolia: {
            type: "http" as const,
            chainType: "l1" as const,
            url: process.env.SEPOLIA_RPC_URL,
            accounts: [`0x${process.env.SEPOLIA_PRIVATE_KEY}`],
          },
        }
      : {}),
    bscTestnet: {
      type: "http",
      chainType: "l1",
      chainId: 97,
      url: process.env.BSC_TESTNET_RPC_URL ?? "",
      accounts: process.env.BSC_TESTNET_PRIVATE_KEY
        ? [`0x${process.env.BSC_TESTNET_PRIVATE_KEY}`]
        : [],
    },
  },
});


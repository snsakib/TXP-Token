import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, parseEther, zeroAddress } from "viem";

// ─── Constants ────────────────────────────────────────────────────────────────

const DECIMALS     = 18n;
const D            = 10n ** DECIMALS;
const SUPPLY       = 1_000_000_000n * D;   // 1 billion tokens
const PRECISION    = 10n ** 18n;
const MAX_FEE      = 100n * PRECISION;     // 100e18 (100%)
const PLATFORM_FEE = 1n * PRECISION;       // 1e18  (1%)

// Default manual prices set in constructor
const TXP_PRICE = PRECISION;              // 1 USD
const YTC_PRICE = PRECISION;              // 1 USD
const LCX_PRICE = PRECISION / 2n;        // 0.5 USD

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Deduct 1% platform fee and return [amountIn, feeAmount]. */
function applyFee(gross: bigint, feeBps = PLATFORM_FEE): [bigint, bigint] {
  const fee = (gross * feeBps) / MAX_FEE;
  return [gross - fee, fee];
}

/** Cross-rate: amountOut = amountIn * priceIn / priceOut */
function calcOut(amountIn: bigint, priceIn: bigint, priceOut: bigint): bigint {
  return (amountIn * priceIn) / priceOut;
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

describe("TXPSwap", async function () {
  const { viem } = await network.connect();
  const [owner, alice, bob, treasury] = await viem.getWalletClients();

  // ── Deploy mock ERC-20s + TXPSwap ─────────────────────────────────────────

  /**
   * Deploys three fresh token contracts and a TXPSwap instance.
   * Owner holds the full supply of each token after deployment.
   */
  async function deploy() {
    const txp = await viem.deployContract("TXPToken");
    const ytc = await viem.deployContract("YapitToken");
    const lcx = await viem.deployContract("LiquidCashToken");

    const swap = await viem.deployContract("TXPSwap", [
      owner.account.address,
      txp.address,
      ytc.address,
      lcx.address,
      treasury.account.address,
      PLATFORM_FEE,
    ]);

    return { txp, ytc, lcx, swap };
  }

  /**
   * Deploy + seed the swap contract with token liquidity and approve the
   * swap contract on alice's behalf for a given token.
   */
  async function deployAndSeed(liquidityPerToken = 500_000n * D) {
    const { txp, ytc, lcx, swap } = await deploy();

    // Transfer tokens to alice so she can swap
    await txp.write.transfer([alice.account.address, 10_000n * D]);
    await ytc.write.mint([alice.account.address, 10_000n * D]);
    await lcx.write.mint([alice.account.address, 10_000n * D]);

    // Approve swap for alice
    const aliceTxp = await viem.getContractAt("TXPToken", txp.address, { client: { wallet: alice } });
    const aliceYtc = await viem.getContractAt("YapitToken", ytc.address, { client: { wallet: alice } });
    const aliceLcx = await viem.getContractAt("LiquidCashToken", lcx.address, { client: { wallet: alice } });
    await aliceTxp.write.approve([swap.address, SUPPLY]);
    await aliceYtc.write.approve([swap.address, SUPPLY]);
    await aliceLcx.write.approve([swap.address, SUPPLY]);

    // Seed swap contract with output liquidity
    await txp.write.approve([swap.address, liquidityPerToken]);
    await ytc.write.mint([swap.address, liquidityPerToken]);
    await lcx.write.mint([swap.address, liquidityPerToken]);
    await txp.write.transfer([swap.address, liquidityPerToken]);

    return { txp, ytc, lcx, swap, aliceTxp, aliceYtc, aliceLcx };
  }

  // ─── Deployment ─────────────────────────────────────────────────────────────

  describe("Deployment", async function () {
    it("stores correct token addresses", async function () {
      const { txp, ytc, lcx, swap } = await deploy();
      assert.equal((await swap.read.TXP()).toLowerCase(), txp.address.toLowerCase());
      assert.equal((await swap.read.YTC()).toLowerCase(), ytc.address.toLowerCase());
      assert.equal((await swap.read.LCX()).toLowerCase(), lcx.address.toLowerCase());
    });

    it("stores treasury and platformFee", async function () {
      const { swap } = await deploy();
      assert.equal(
        (await swap.read.treasury()).toLowerCase(),
        treasury.account.address.toLowerCase(),
      );
      assert.equal(await swap.read.platformFee(), PLATFORM_FEE);
    });

    it("sets default manual prices", async function () {
      const { txp, ytc, lcx, swap } = await deploy();
      assert.equal(await swap.read.manualPrice([txp.address]), TXP_PRICE);
      assert.equal(await swap.read.manualPrice([ytc.address]), YTC_PRICE);
      assert.equal(await swap.read.manualPrice([lcx.address]), LCX_PRICE);
    });

    it("sets owner correctly", async function () {
      const { swap } = await deploy();
      assert.equal(
        (await swap.read.owner()).toLowerCase(),
        owner.account.address.toLowerCase(),
      );
    });

    it("is not paused on deployment", async function () {
      const { swap } = await deploy();
      assert.equal(await swap.read.paused(), false);
    });

    it("reverts with zero TXP address", async function () {
      const ytc = await viem.deployContract("YapitToken");
      const lcx = await viem.deployContract("LiquidCashToken");
      await assert.rejects(
        viem.deployContract("TXPSwap", [
          owner.account.address, zeroAddress,
          ytc.address, lcx.address,
          treasury.account.address, PLATFORM_FEE,
        ]),
        /Invalid TXP/,
      );
    });

    it("reverts when fee exceeds MAX_FEE", async function () {
      const txp = await viem.deployContract("TXPToken");
      const ytc = await viem.deployContract("YapitToken");
      const lcx = await viem.deployContract("LiquidCashToken");
      await assert.rejects(
        viem.deployContract("TXPSwap", [
          owner.account.address, txp.address,
          ytc.address, lcx.address,
          treasury.account.address, MAX_FEE + 1n,
        ]),
        /Fee too high/,
      );
    });
  });

  // ─── getPlatformFee ─────────────────────────────────────────────────────────

  describe("getPlatformFee()", async function () {
    it("returns correct fee and net amount for 1% fee", async function () {
      const { swap } = await deploy();
      const gross = 1000n * D;
      const [net, fee] = await swap.read.getPlatformFee([gross]);
      assert.equal(fee, (gross * PLATFORM_FEE) / MAX_FEE);
      assert.equal(net, gross - fee);
    });

    it("returns zero fee when platformFee is 0", async function () {
      const { swap } = await deploy();
      await swap.write.setPlatformFee([0n]);
      const [net, fee] = await swap.read.getPlatformFee([500n * D]);
      assert.equal(fee, 0n);
      assert.equal(net, 500n * D);
    });
  });

  // ─── getPrice ───────────────────────────────────────────────────────────────

  describe("getPrice()", async function () {
    it("returns the manual price for TXP", async function () {
      const { txp, swap } = await deploy();
      assert.equal(await swap.read.getPrice([txp.address]), TXP_PRICE);
    });

    it("returns the manual price for LCX (0.5 USD)", async function () {
      const { lcx, swap } = await deploy();
      assert.equal(await swap.read.getPrice([lcx.address]), LCX_PRICE);
    });
  });

  // ─── calcOutAmount ──────────────────────────────────────────────────────────

  describe("calcOutAmount()", async function () {
    it("TXP → YTC: 1:1 when both priced at 1 USD", async function () {
      const { txp, ytc, swap } = await deploy();
      const amountIn = 100n * D;
      const out = await swap.read.calcOutAmount([txp.address, ytc.address, amountIn]);
      assert.equal(out, calcOut(amountIn, TXP_PRICE, YTC_PRICE));
    });

    it("TXP → LCX: 1 TXP = 2 LCX when TXP=1 USD, LCX=0.5 USD", async function () {
      const { txp, lcx, swap } = await deploy();
      const amountIn = 100n * D;
      const out = await swap.read.calcOutAmount([txp.address, lcx.address, amountIn]);
      // 100 TXP * (1 / 0.5) = 200 LCX
      assert.equal(out, calcOut(amountIn, TXP_PRICE, LCX_PRICE));
      assert.equal(out, 200n * D);
    });

    it("LCX → TXP: 2 LCX = 1 TXP when LCX=0.5, TXP=1 USD", async function () {
      const { txp, lcx, swap } = await deploy();
      const amountIn = 200n * D;
      const out = await swap.read.calcOutAmount([lcx.address, txp.address, amountIn]);
      // 200 LCX * (0.5 / 1) = 100 TXP
      assert.equal(out, calcOut(amountIn, LCX_PRICE, TXP_PRICE));
      assert.equal(out, 100n * D);
    });

    it("LCX → YTC: 2 LCX = 1 YTC when LCX=0.5, YTC=1 USD", async function () {
      const { ytc, lcx, swap } = await deploy();
      const amountIn = 200n * D;
      const out = await swap.read.calcOutAmount([lcx.address, ytc.address, amountIn]);
      assert.equal(out, calcOut(amountIn, LCX_PRICE, YTC_PRICE));
      assert.equal(out, 100n * D);
    });

    it("reflects updated manual price", async function () {
      const { txp, ytc, swap } = await deploy();
      const newTxpPrice = 2n * PRECISION; // 2 USD
      await swap.write.setPrice([txp.address, newTxpPrice]);
      const amountIn = 100n * D;
      const out = await swap.read.calcOutAmount([txp.address, ytc.address, amountIn]);
      assert.equal(out, calcOut(amountIn, newTxpPrice, YTC_PRICE));
      assert.equal(out, 200n * D);
    });
  });

  // ─── Admin: updateTokens ────────────────────────────────────────────────────

  describe("updateTokens()", async function () {
    it("owner can update treasury address (TokenFeed.TREASURY = 7)", async function () {
      const { swap } = await deploy();
      await swap.write.updateTokens([bob.account.address, 7]); // TREASURY
      assert.equal(
        (await swap.read.treasury()).toLowerCase(),
        bob.account.address.toLowerCase(),
      );
    });

    it("owner can update pancakeRouter (TokenFeed.ROUTER = 6)", async function () {
      const { swap } = await deploy();
      await swap.write.updateTokens([bob.account.address, 6]); // ROUTER
      assert.equal(
        (await swap.read.pancakeRouter()).toLowerCase(),
        bob.account.address.toLowerCase(),
      );
    });

    it("reverts when called by non-owner", async function () {
      const { swap } = await deploy();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.updateTokens([bob.account.address, 7]),
        /OwnableUnauthorizedAccount/,
      );
    });

    it("reverts on zero address", async function () {
      const { swap } = await deploy();
      await assert.rejects(
        swap.write.updateTokens([zeroAddress, 7]),
        /Invalid address!/,
      );
    });
  });

  // ─── Admin: setPrice ────────────────────────────────────────────────────────

  describe("setPrice()", async function () {
    it("owner can update a token's manual price", async function () {
      const { txp, swap } = await deploy();
      const newPrice = 3n * PRECISION;
      await swap.write.setPrice([txp.address, newPrice]);
      assert.equal(await swap.read.manualPrice([txp.address]), newPrice);
    });

    it("reverts on zero price", async function () {
      const { txp, swap } = await deploy();
      await assert.rejects(
        swap.write.setPrice([txp.address, 0n]),
        /Invalid data!/,
      );
    });

    it("reverts when called by non-owner", async function () {
      const { txp, swap } = await deploy();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.setPrice([txp.address, PRECISION]),
        /OwnableUnauthorizedAccount/,
      );
    });
  });

  // ─── Admin: setPlatformFee ──────────────────────────────────────────────────

  describe("setPlatformFee()", async function () {
    it("owner can update the platform fee", async function () {
      const { swap } = await deploy();
      const newFee = 2n * PRECISION; // 2%
      await swap.write.setPlatformFee([newFee]);
      assert.equal(await swap.read.platformFee(), newFee);
    });

    it("reverts when fee exceeds MAX_FEE", async function () {
      const { swap } = await deploy();
      await assert.rejects(
        swap.write.setPlatformFee([MAX_FEE + 1n]),
        /Invalid Fee!/,
      );
    });

    it("allows setting fee to MAX_FEE exactly", async function () {
      const { swap } = await deploy();
      await swap.write.setPlatformFee([MAX_FEE]);
      assert.equal(await swap.read.platformFee(), MAX_FEE);
    });
  });

  // ─── Admin: pause / unPause ─────────────────────────────────────────────────

  describe("pause() / unPause()", async function () {
    it("owner can pause the contract", async function () {
      const { swap } = await deploy();
      await swap.write.pause();
      assert.equal(await swap.read.paused(), true);
    });

    it("owner can unpause the contract", async function () {
      const { swap } = await deploy();
      await swap.write.pause();
      await swap.write.unPause();
      assert.equal(await swap.read.paused(), false);
    });

    it("non-owner cannot pause", async function () {
      const { swap } = await deploy();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.pause(),
        /OwnableUnauthorizedAccount/,
      );
    });

    it("swap() reverts while paused", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      await swap.write.pause();

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.swap([
          [txp.address, ytc.address],
          100n * D,
          alice.account.address,
        ]),
        /EnforcedPause/,
      );
    });
  });

  // ─── Admin: addManualLiquidity / removeLiquidity ─────────────────────────────

  describe("addManualLiquidity() / removeLiquidity()", async function () {
    it("owner can deposit token liquidity", async function () {
      const { txp, swap } = await deploy();
      const amount = 1000n * D;
      await txp.write.approve([swap.address, amount]);
      await swap.write.addManualLiquidity([txp.address, amount]);
      assert.equal(await txp.read.balanceOf([swap.address]), amount);
    });

    it("owner can withdraw token liquidity", async function () {
      const { txp, swap } = await deploy();
      const amount = 1000n * D;
      await txp.write.approve([swap.address, amount]);
      await swap.write.addManualLiquidity([txp.address, amount]);

      const before = await txp.read.balanceOf([owner.account.address]);
      await swap.write.removeLiquidity([txp.address, owner.account.address, amount]);
      const after = await txp.read.balanceOf([owner.account.address]);
      assert.equal(after - before, amount);
    });

    it("reverts when withdrawing more than contract balance", async function () {
      const { txp, swap } = await deploy();
      await assert.rejects(
        swap.write.removeLiquidity([txp.address, owner.account.address, 1n * D]),
        /Insufficient balance/,
      );
    });

    it("non-owner cannot add liquidity", async function () {
      const { txp, swap } = await deploy();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.addManualLiquidity([txp.address, 100n * D]),
        /OwnableUnauthorizedAccount/,
      );
    });
  });

  // ─── Core swap() ─────────────────────────────────────────────────────────────

  describe("swap()", async function () {
    // ── TXP → YTC ─────────────────────────────────────────────────────────────

    it("TXP → YTC: transfers correct net amount to alice", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      const gross = 100n * D;
      const [net] = applyFee(gross);
      const expectedOut = calcOut(net, TXP_PRICE, YTC_PRICE);

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      const before = await ytc.read.balanceOf([alice.account.address]);
      await aliceSwap.write.swap([[txp.address, ytc.address], gross, alice.account.address]);
      const after = await ytc.read.balanceOf([alice.account.address]);

      assert.equal(after - before, expectedOut);
    });

    it("TXP → YTC: deducts gross input from alice", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      const gross = 100n * D;

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      const before = await txp.read.balanceOf([alice.account.address]);
      await aliceSwap.write.swap([[txp.address, ytc.address], gross, alice.account.address]);
      const after = await txp.read.balanceOf([alice.account.address]);

      assert.equal(before - after, gross);
    });

    it("TXP → YTC: sends fee to treasury", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      const gross = 100n * D;
      const [, fee] = applyFee(gross);

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      const before = await txp.read.balanceOf([treasury.account.address]);
      await aliceSwap.write.swap([[txp.address, ytc.address], gross, alice.account.address]);
      const after = await txp.read.balanceOf([treasury.account.address]);

      assert.equal(after - before, fee);
    });

    it("TXP → LCX: 100 TXP → 200 LCX (price ratio 1:0.5)", async function () {
      const { txp, lcx, swap } = await deployAndSeed();
      const gross = 100n * D;
      const [net] = applyFee(gross);
      const expectedOut = calcOut(net, TXP_PRICE, LCX_PRICE); // ×2

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      const before = await lcx.read.balanceOf([alice.account.address]);
      await aliceSwap.write.swap([[txp.address, lcx.address], gross, alice.account.address]);
      const after = await lcx.read.balanceOf([alice.account.address]);

      assert.equal(after - before, expectedOut);
    });

    it("LCX → TXP: 200 LCX → 100 TXP (price ratio 0.5:1)", async function () {
      const { txp, lcx, swap } = await deployAndSeed();
      const gross = 200n * D;
      const [net] = applyFee(gross);
      const expectedOut = calcOut(net, LCX_PRICE, TXP_PRICE); // ×0.5

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      const before = await txp.read.balanceOf([alice.account.address]);
      await aliceSwap.write.swap([[lcx.address, txp.address], gross, alice.account.address]);
      const after = await txp.read.balanceOf([alice.account.address]);

      assert.equal(after - before, expectedOut);
    });

    it("YTC → LCX: 100 YTC → 200 LCX (YTC=1, LCX=0.5)", async function () {
      const { ytc, lcx, swap } = await deployAndSeed();
      const gross = 100n * D;
      const [net] = applyFee(gross);
      const expectedOut = calcOut(net, YTC_PRICE, LCX_PRICE);

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      const before = await lcx.read.balanceOf([alice.account.address]);
      await aliceSwap.write.swap([[ytc.address, lcx.address], gross, alice.account.address]);
      const after = await lcx.read.balanceOf([alice.account.address]);

      assert.equal(after - before, expectedOut);
    });

    it("emits TXPSwapped event with correct args", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      const gross = 100n * D;
      const [net, fee] = applyFee(gross);
      const expectedOut = calcOut(net, TXP_PRICE, YTC_PRICE);

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });

      await viem.assertions.emitWithArgs(
        aliceSwap.write.swap([[txp.address, ytc.address], gross, alice.account.address]),
        swap,
        "TXPSwapped",
        [
          getAddress(alice.account.address),
          getAddress(txp.address),
          getAddress(ytc.address),
          net,
          expectedOut,
          fee,
        ],
      );
    });

    // ── Validations ───────────────────────────────────────────────────────────

    it("reverts with amount = 0", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.swap([[txp.address, ytc.address], 0n, alice.account.address]),
        /Invalid amount!/,
      );
    });

    it("reverts with path length != 2", async function () {
      const { txp, ytc, lcx, swap } = await deployAndSeed();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.swap([[txp.address, ytc.address, lcx.address], 100n * D, alice.account.address]),
        /Invalid path!/,
      );
    });

    it("reverts for identical tokenIn/tokenOut", async function () {
      const { txp, swap } = await deployAndSeed();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.swap([[txp.address, txp.address], 100n * D, alice.account.address]),
        /Identical pair!/,
      );
    });

    it("reverts when pair does not include TXP/YTC/LCX", async function () {
      const { swap } = await deployAndSeed();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      // two random addresses
      const randA = "0x1111111111111111111111111111111111111111" as `0x${string}`;
      const randB = "0x2222222222222222222222222222222222222222" as `0x${string}`;
      await assert.rejects(
        aliceSwap.write.swap([[randA, randB], 100n * D, alice.account.address]),
        /Pair not supported!/,
      );
    });

    it("reverts when caller is not _to", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      // alice calls but passes bob as recipient
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.swap([[txp.address, ytc.address], 100n * D, bob.account.address]),
        /!USER/,
      );
    });

    it("reverts when swap contract has insufficient output liquidity", async function () {
      const { txp, ytc, swap } = await deploy(); // no seeding

      // Give alice tokens and approve
      await txp.write.transfer([alice.account.address, 1000n * D]);
      const aliceTxp = await viem.getContractAt("TXPToken", txp.address, { client: { wallet: alice } });
      await aliceTxp.write.approve([swap.address, SUPPLY]);

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.swap([[txp.address, ytc.address], 100n * D, alice.account.address]),
        /Insufficient token liquidity!/,
      );
    });

    it("no tokens are auto-staked — output goes directly to alice", async function () {
      const { txp, ytc, swap } = await deployAndSeed();
      const gross = 100n * D;
      const [net] = applyFee(gross);
      const expectedOut = calcOut(net, TXP_PRICE, YTC_PRICE);

      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await aliceSwap.write.swap([[txp.address, ytc.address], gross, alice.account.address]);

      // alice holds the full output herself — nothing locked in swap contract as a "stake"
      assert.equal(await ytc.read.balanceOf([alice.account.address]), 10_000n * D + expectedOut);
    });
  });

  // ─── Ownership ──────────────────────────────────────────────────────────────

  describe("transferOwnership() / renounceOwnership()", async function () {
    it("owner can transfer ownership", async function () {
      const { swap } = await deploy();
      await swap.write.transferOwnership([alice.account.address]);
      assert.equal(
        (await swap.read.owner()).toLowerCase(),
        alice.account.address.toLowerCase(),
      );
    });

    it("non-owner cannot transfer ownership", async function () {
      const { swap } = await deploy();
      const aliceSwap = await viem.getContractAt("TXPSwap", swap.address, { client: { wallet: alice } });
      await assert.rejects(
        aliceSwap.write.transferOwnership([bob.account.address]),
        /OwnableUnauthorizedAccount/,
      );
    });

    it("owner can renounce ownership", async function () {
      const { swap } = await deploy();
      await swap.write.renounceOwnership();
      assert.equal(await swap.read.owner(), zeroAddress);
    });
  });
});

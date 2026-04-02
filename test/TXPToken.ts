import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress } from "viem";

// ─── Constants ───────────────────────────────────────────────────────────────

const ONE_BILLION = 1_000_000_000n;
const DECIMALS    = 18n;
const TOTAL_SUPPLY = ONE_BILLION * 10n ** DECIMALS;

// ─── Test Suite ───────────────────────────────────────────────────────────────

describe("TXPToken", async function () {
  const { viem } = await network.connect();
  const [owner, alice, bob] = await viem.getWalletClients();

  // Helper: fresh contract for each test
  async function deploy() {
    return viem.deployContract("TXPToken");
  }

  // ─── Metadata ──────────────────────────────────────────────────────────────

  describe("Metadata", async function () {
    it("has the correct name", async function () {
      const token = await deploy();
      assert.equal(await token.read.name(), "Triple X POS Token");
    });

    it("has the correct symbol", async function () {
      const token = await deploy();
      assert.equal(await token.read.symbol(), "TXP");
    });

    it("has 18 decimals", async function () {
      const token = await deploy();
      assert.equal(await token.read.decimals(), 18);
    });

    it("reports the correct TOTAL_SUPPLY constant", async function () {
      const token = await deploy();
      assert.equal(await token.read.TOTAL_SUPPLY(), TOTAL_SUPPLY);
    });
  });

  // ─── Deployment ────────────────────────────────────────────────────────────

  describe("Deployment", async function () {
    it("mints the full supply to the deployer", async function () {
      const token = await deploy();
      assert.equal(
        await token.read.balanceOf([owner.account.address]),
        TOTAL_SUPPLY,
      );
    });

    it("totalSupply equals TOTAL_SUPPLY after deployment", async function () {
      const token = await deploy();
      assert.equal(await token.read.totalSupply(), TOTAL_SUPPLY);
    });

    it("sets the deployer as owner", async function () {
      const token = await deploy();
      assert.equal(
        (await token.read.owner()).toLowerCase(),
        owner.account.address.toLowerCase(),
      );
    });

    it("is not paused on deployment", async function () {
      const token = await deploy();
      assert.equal(await token.read.paused(), false);
    });
  });

  // ─── ERC-20: Transfer ──────────────────────────────────────────────────────

  describe("transfer()", async function () {
    it("moves tokens from sender to recipient", async function () {
      const token  = await deploy();
      const amount = 500n * 10n ** DECIMALS;

      await token.write.transfer([alice.account.address, amount]);

      assert.equal(
        await token.read.balanceOf([alice.account.address]),
        amount,
      );
      assert.equal(
        await token.read.balanceOf([owner.account.address]),
        TOTAL_SUPPLY - amount,
      );
    });

    it("emits a Transfer event", async function () {
      const token  = await deploy();
      const amount = 100n * 10n ** DECIMALS;

      await viem.assertions.emitWithArgs(
        token.write.transfer([alice.account.address, amount]),
        token,
        "Transfer",
        [getAddress(owner.account.address), getAddress(alice.account.address), amount],
      );
    });

    it("reverts when balance is insufficient", async function () {
      const token = await deploy();
      const huge  = TOTAL_SUPPLY + 1n;

      await assert.rejects(
        token.write.transfer([alice.account.address, huge]),
        /TXP: transfer amount exceeds balance/,
      );
    });
  });

  // ─── ERC-20: Approve & TransferFrom ───────────────────────────────────────

  describe("approve() & transferFrom()", async function () {
    it("sets the allowance and emits Approval", async function () {
      const token  = await deploy();
      const amount = 200n * 10n ** DECIMALS;

      await viem.assertions.emitWithArgs(
        token.write.approve([alice.account.address, amount]),
        token,
        "Approval",
        [getAddress(owner.account.address), getAddress(alice.account.address), amount],
      );

      assert.equal(
        await token.read.allowance([
          owner.account.address,
          alice.account.address,
        ]),
        amount,
      );
    });

    it("transferFrom moves tokens and reduces allowance", async function () {
      const token  = await deploy();
      const amount = 300n * 10n ** DECIMALS;

      await token.write.approve([alice.account.address, amount]);

      const aliceToken = await viem.getContractAt("TXPToken", token.address, {
        client: { wallet: alice },
      });
      await aliceToken.write.transferFrom([
        owner.account.address,
        bob.account.address,
        amount,
      ]);

      assert.equal(
        await token.read.balanceOf([bob.account.address]),
        amount,
      );
      assert.equal(
        await token.read.allowance([
          owner.account.address,
          alice.account.address,
        ]),
        0n,
      );
    });

    it("reverts transferFrom when allowance is exceeded", async function () {
      const token  = await deploy();
      const amount = 100n * 10n ** DECIMALS;

      await token.write.approve([alice.account.address, amount]);

      const aliceToken = await viem.getContractAt("TXPToken", token.address, {
        client: { wallet: alice },
      });

      await assert.rejects(
        aliceToken.write.transferFrom([
          owner.account.address,
          bob.account.address,
          amount + 1n,
        ]),
        /TXP: transfer amount exceeds allowance/,
      );
    });
  });

  // ─── Burn ──────────────────────────────────────────────────────────────────

  describe("burn()", async function () {
    it("reduces both balance and totalSupply", async function () {
      const token      = await deploy();
      const burnAmount = 1_000n * 10n ** DECIMALS;

      await token.write.burn([burnAmount]);

      assert.equal(
        await token.read.totalSupply(),
        TOTAL_SUPPLY - burnAmount,
      );
      assert.equal(
        await token.read.balanceOf([owner.account.address]),
        TOTAL_SUPPLY - burnAmount,
      );
    });

    it("emits Burn and Transfer(to zero) events", async function () {
      const token      = await deploy();
      const burnAmount = 50n * 10n ** DECIMALS;

      await viem.assertions.emitWithArgs(
        token.write.burn([burnAmount]),
        token,
        "Burn",
        [getAddress(owner.account.address), burnAmount],
      );
    });

    it("reverts when burning more than balance", async function () {
      const token = await deploy();
      await assert.rejects(
        token.write.burn([TOTAL_SUPPLY + 1n]),
        /TXP: burn amount exceeds balance/,
      );
    });
  });

  // ─── Pause ─────────────────────────────────────────────────────────────────

  describe("pause() / unpause()", async function () {
    it("owner can pause and unpause", async function () {
      const token = await deploy();

      await token.write.pause();
      assert.equal(await token.read.paused(), true);

      await token.write.unpause();
      assert.equal(await token.read.paused(), false);
    });

    it("blocks transfers while paused", async function () {
      const token  = await deploy();
      const amount = 10n * 10n ** DECIMALS;

      await token.write.pause();

      await assert.rejects(
        token.write.transfer([alice.account.address, amount]),
        /TXP: token transfers are paused/,
      );
    });

    it("non-owner cannot pause", async function () {
      const token = await deploy();
      const aliceToken = await viem.getContractAt("TXPToken", token.address, {
        client: { wallet: alice },
      });

      await assert.rejects(
        aliceToken.write.pause(),
        /TXP: caller is not the owner/,
      );
    });
  });

  // ─── Blacklist ─────────────────────────────────────────────────────────────

  describe("blacklist() / removeFromBlacklist()", async function () {
    it("owner can blacklist and remove an address", async function () {
      const token = await deploy();

      await token.write.blacklist([alice.account.address]);
      assert.equal(
        await token.read.isBlacklisted([alice.account.address]),
        true,
      );

      await token.write.removeFromBlacklist([alice.account.address]);
      assert.equal(
        await token.read.isBlacklisted([alice.account.address]),
        false,
      );
    });

    it("blocks transfers from a blacklisted sender", async function () {
      const token  = await deploy();
      const amount = 10n * 10n ** DECIMALS;

      // Give alice some tokens first
      await token.write.transfer([alice.account.address, amount]);
      await token.write.blacklist([alice.account.address]);

      const aliceToken = await viem.getContractAt("TXPToken", token.address, {
        client: { wallet: alice },
      });

      await assert.rejects(
        aliceToken.write.transfer([bob.account.address, amount]),
        /TXP: address is blacklisted/,
      );
    });

    it("blocks transfers to a blacklisted recipient", async function () {
      const token  = await deploy();
      const amount = 10n * 10n ** DECIMALS;

      await token.write.blacklist([alice.account.address]);

      await assert.rejects(
        token.write.transfer([alice.account.address, amount]),
        /TXP: address is blacklisted/,
      );
    });

    it("cannot blacklist the owner", async function () {
      const token = await deploy();
      await assert.rejects(
        token.write.blacklist([owner.account.address]),
        /TXP: cannot blacklist the owner/,
      );
    });
  });

  // ─── Ownership ─────────────────────────────────────────────────────────────

  describe("transferOwnership() / renounceOwnership()", async function () {
    it("owner can transfer ownership", async function () {
      const token = await deploy();

      await token.write.transferOwnership([alice.account.address]);

      assert.equal(
        (await token.read.owner()).toLowerCase(),
        alice.account.address.toLowerCase(),
      );
    });

    it("reverts on transfer to zero address", async function () {
      const token = await deploy();
      await assert.rejects(
        token.write.transferOwnership([
          "0x0000000000000000000000000000000000000000",
        ]),
        /TXP: new owner is the zero address/,
      );
    });

    it("owner can renounce ownership", async function () {
      const token = await deploy();

      await token.write.renounceOwnership();

      assert.equal(
        await token.read.owner(),
        "0x0000000000000000000000000000000000000000",
      );
    });

    it("non-owner cannot transfer ownership", async function () {
      const token = await deploy();
      const aliceToken = await viem.getContractAt("TXPToken", token.address, {
        client: { wallet: alice },
      });

      await assert.rejects(
        aliceToken.write.transferOwnership([bob.account.address]),
        /TXP: caller is not the owner/,
      );
    });
  });
});

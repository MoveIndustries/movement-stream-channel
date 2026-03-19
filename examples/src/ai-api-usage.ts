/**
 * Example: AI API Pay-Per-Use
 *
 * Simulates a user paying for AI inference requests via a streaming payment channel.
 *
 * Flow:
 *   1. User opens a channel depositing 0.01 MOVE toward an AI provider
 *   2. User makes API requests; after each, signs a voucher incrementing the cumulative amount
 *   3. Provider periodically settles vouchers on-chain to claim earned funds
 *   4. When done, provider closes the channel — user gets refund of unused deposit
 *
 * This demonstrates how micropayments work without per-request on-chain transactions.
 * 50 API calls produce only 3 on-chain txns (open, settle, close).
 */

import { Account, AccountAddress } from "@moveindustries/ts-sdk";
import {
  client,
  fundFromFaucet,
  submitTx,
  REGISTRY_ADDR,
  TOKEN_METADATA_ADDR,
  MODULE_ADDRESS,
} from "./common/client.js";
import {
  signVoucher,
  getPublicKey,
  computeChannelId,
  randomSalt,
  toHex,
  Voucher,
} from "./common/voucher.js";

// --- Configuration ---
// MOVE has 8 decimals: 1 MOVE = 100_000_000
const COST_PER_REQUEST = 10_000n; // 0.0001 MOVE per API call
const INITIAL_DEPOSIT = 1_000_000n; // 0.01 MOVE
const NUM_REQUESTS = 50;
const SETTLE_EVERY = 20; // provider settles every 20 requests

async function main() {
  console.log("=== AI API Pay-Per-Use Example ===\n");

  const user = Account.generate();
  const provider = Account.generate();

  console.log(`User (payer):     ${user.accountAddress}`);
  console.log(`Provider (payee): ${provider.accountAddress}`);
  console.log(`Deposit:          ${Number(INITIAL_DEPOSIT) / 1e8} MOVE`);
  console.log(`Cost per request: ${Number(COST_PER_REQUEST) / 1e8} MOVE`);
  console.log();

  // Fund both accounts from the Movement testnet faucet.
  console.log("0. Funding accounts from faucet...");
  await fundFromFaucet(user);
  await fundFromFaucet(provider);
  console.log();

  // --- Step 1: Open channel ---
  const salt = randomSalt();
  const privKeyBytes = user.privateKey.toUint8Array();
  const pubKeyBytes = getPublicKey(privKeyBytes);

  // Compute channel ID client-side (matches on-chain computation).
  const tokenAddr = AccountAddress.fromString(TOKEN_METADATA_ADDR);
  const channelId = computeChannelId(
    user.accountAddress,
    provider.accountAddress,
    tokenAddr,
    salt,
    pubKeyBytes,
  );

  console.log("1. Opening payment channel...");
  const openResult = await submitTx(user, {
    function: `${MODULE_ADDRESS}::channel::open`,
    functionArguments: [
      REGISTRY_ADDR,
      provider.accountAddress.toString(),
      TOKEN_METADATA_ADDR,
      INITIAL_DEPOSIT,
      salt,
      pubKeyBytes,
    ],
  });
  console.log(`   Tx: ${openResult.hash}`);
  console.log(`   Channel ID: ${toHex(channelId)}\n`);

  // --- Step 2: Simulate API usage with off-chain vouchers ---
  console.log("2. Making API requests (off-chain vouchers)...");

  let cumulativeAmount = 0n;
  const vouchers: { voucher: Voucher; signature: Uint8Array }[] = [];

  for (let i = 1; i <= NUM_REQUESTS; i++) {
    cumulativeAmount += COST_PER_REQUEST;

    const voucher: Voucher = { channelId, cumulativeAmount };
    const signature = signVoucher(voucher, privKeyBytes);
    vouchers.push({ voucher, signature });

    if (i % 10 === 0) {
      console.log(
        `   Request ${i}: cumulative = ${Number(cumulativeAmount) / 1e8} MOVE`,
      );
    }

    // --- Step 3: Provider settles periodically ---
    if (i % SETTLE_EVERY === 0 && i < NUM_REQUESTS) {
      console.log(`\n3. Provider settling at request ${i}...`);
      const latest = vouchers[vouchers.length - 1];

      const settleResult = await submitTx(provider, {
        function: `${MODULE_ADDRESS}::channel::settle`,
        functionArguments: [
          REGISTRY_ADDR,
          Array.from(latest.voucher.channelId),
          latest.voucher.cumulativeAmount,
          Array.from(latest.signature),
          Array.from(pubKeyBytes),
        ],
      });
      console.log(
        `   Settled ${Number(cumulativeAmount) / 1e8} MOVE (tx: ${settleResult.hash})`,
      );
      console.log();
    }
  }

  // --- Step 4: Provider closes channel with final voucher ---
  console.log(`\n4. Provider closing channel with final settlement...`);
  const final = vouchers[vouchers.length - 1];

  const closeResult = await submitTx(provider, {
    function: `${MODULE_ADDRESS}::channel::close`,
    functionArguments: [
      REGISTRY_ADDR,
      Array.from(final.voucher.channelId),
      final.voucher.cumulativeAmount,
      Array.from(final.signature),
      Array.from(pubKeyBytes),
    ],
  });
  console.log(`   Tx: ${closeResult.hash}\n`);

  const totalPaid = Number(cumulativeAmount) / 1e8;
  const refund = Number(INITIAL_DEPOSIT - cumulativeAmount) / 1e8;

  console.log("=== Summary ===");
  console.log(`   API requests made:  ${NUM_REQUESTS}`);
  console.log(`   Total paid:         ${totalPaid} MOVE`);
  console.log(`   Refunded to user:   ${refund} MOVE`);
  console.log(`   On-chain txns:      3 (open + settle + close)`);
  console.log(`   Off-chain vouchers: ${NUM_REQUESTS}`);
}

main().catch(console.error);

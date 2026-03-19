/**
 * Example: Subscription Streaming Payments
 *
 * Simulates a monthly subscription where the service provider drains
 * the channel gradually over time rather than charging upfront.
 *
 * Flow:
 *   1. User opens a channel with 1 month of subscription cost (0.03 MOVE)
 *   2. Each "day", the user signs a voucher for the daily rate (0.001 MOVE/day)
 *   3. The service settles weekly to claim earned funds
 *   4. At month end, service closes the channel
 *
 * If the user wants to cancel mid-month, they call requestClose.
 * The service has 15 minutes to settle any outstanding vouchers,
 * then the user withdraws their remaining deposit.
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

// MOVE has 8 decimals
const MONTHLY_COST = 3_000_000n; // 0.03 MOVE
const DAILY_RATE = 100_000n; // 0.001 MOVE/day
const DAYS_IN_MONTH = 30;
const SETTLE_EVERY_DAYS = 7;

async function main() {
  console.log("=== Subscription Streaming Payment Example ===\n");

  const subscriber = Account.generate();
  const service = Account.generate();

  console.log(`Subscriber: ${subscriber.accountAddress}`);
  console.log(`Service:    ${service.accountAddress}`);
  console.log(`Monthly:    ${Number(MONTHLY_COST) / 1e8} MOVE`);
  console.log(`Daily rate: ${Number(DAILY_RATE) / 1e8} MOVE/day\n`);

  // Fund accounts.
  console.log("0. Funding accounts from faucet...");
  await fundFromFaucet(subscriber);
  await fundFromFaucet(service);
  console.log();

  // --- Open channel for one month ---
  const salt = randomSalt();
  const privKeyBytes = subscriber.privateKey.toUint8Array();
  const pubKeyBytes = getPublicKey(privKeyBytes);

  const tokenAddr = AccountAddress.fromString(TOKEN_METADATA_ADDR);
  const channelId = computeChannelId(
    subscriber.accountAddress,
    service.accountAddress,
    tokenAddr,
    salt,
    pubKeyBytes,
  );

  console.log("1. Subscriber opens channel for 1 month...");
  const openResult = await submitTx(subscriber, {
    function: `${MODULE_ADDRESS}::channel::open`,
    functionArguments: [
      REGISTRY_ADDR,
      service.accountAddress.toString(),
      TOKEN_METADATA_ADDR,
      MONTHLY_COST,
      salt,
      pubKeyBytes,
    ],
  });
  console.log(`   Tx: ${openResult.hash}`);
  console.log(`   Channel ID: ${toHex(channelId)}\n`);

  // --- Simulate daily voucher signing ---
  console.log("2. Simulating daily usage...\n");

  let cumulativeAmount = 0n;
  let onChainTxns = 1; // open

  for (let day = 1; day <= DAYS_IN_MONTH; day++) {
    cumulativeAmount += DAILY_RATE;

    const voucher: Voucher = { channelId, cumulativeAmount };
    const signature = signVoucher(voucher, privKeyBytes);

    if (day % 7 === 0) {
      console.log(
        `   Day ${day}: cumulative = ${Number(cumulativeAmount) / 1e8} MOVE`,
      );
    }

    // Service settles weekly.
    if (day % SETTLE_EVERY_DAYS === 0 && day < DAYS_IN_MONTH) {
      console.log(`   >> Service settles week ${day / 7} on-chain`);

      const settleResult = await submitTx(service, {
        function: `${MODULE_ADDRESS}::channel::settle`,
        functionArguments: [
          REGISTRY_ADDR,
          Array.from(channelId),
          cumulativeAmount,
          Array.from(signature),
          Array.from(pubKeyBytes),
        ],
      });
      console.log(`      Tx: ${settleResult.hash}\n`);
      onChainTxns++;
    }
  }

  // --- Month end: close channel ---
  console.log("3. Month ended. Service closes channel with final voucher...");

  const finalVoucher: Voucher = { channelId, cumulativeAmount };
  const finalSig = signVoucher(finalVoucher, privKeyBytes);

  const closeResult = await submitTx(service, {
    function: `${MODULE_ADDRESS}::channel::close`,
    functionArguments: [
      REGISTRY_ADDR,
      Array.from(channelId),
      cumulativeAmount,
      Array.from(finalSig),
      Array.from(pubKeyBytes),
    ],
  });
  console.log(`   Tx: ${closeResult.hash}\n`);
  onChainTxns++;

  console.log("=== Summary ===");
  console.log(`   Subscription days:  ${DAYS_IN_MONTH}`);
  console.log(`   Total charged:      ${Number(cumulativeAmount) / 1e8} MOVE`);
  console.log(
    `   Refunded:           ${Number(MONTHLY_COST - cumulativeAmount) / 1e8} MOVE`,
  );
  console.log(
    `   On-chain txns:      ${onChainTxns} (open + ${onChainTxns - 2} settles + close)`,
  );
  console.log(`   Off-chain vouchers: ${DAYS_IN_MONTH}`);
}

main().catch(console.error);

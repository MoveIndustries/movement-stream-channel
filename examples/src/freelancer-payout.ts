/**
 * Example: Freelancer Milestone Payout
 *
 * Simulates a client paying a freelancer as project milestones are completed.
 * The client escrows the full project budget, then releases funds incrementally.
 *
 * Flow:
 *   1. Client opens channel with full project budget (0.05 MOVE)
 *   2. Freelancer completes milestones; client signs voucher for each
 *   3. Freelancer settles after each milestone to claim funds
 *   4. After final milestone, freelancer closes the channel
 *
 * If the project is cancelled, the client requests close and recovers
 * unearned funds after the 15-minute grace period.
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

interface Milestone {
  name: string;
  payment: bigint; // in octas (8 decimals)
}

// MOVE has 8 decimals
const PROJECT_BUDGET = 5_000_000n; // 0.05 MOVE
const MILESTONES: Milestone[] = [
  { name: "Design & wireframes", payment: 500_000n }, // 0.005 MOVE
  { name: "Backend implementation", payment: 1_500_000n }, // 0.015 MOVE
  { name: "Frontend implementation", payment: 1_500_000n }, // 0.015 MOVE
  { name: "Testing & QA", payment: 1_000_000n }, // 0.01 MOVE
  { name: "Deployment & handoff", payment: 500_000n }, // 0.005 MOVE
];

async function main() {
  console.log("=== Freelancer Milestone Payout Example ===\n");

  const projectClient = Account.generate();
  const freelancer = Account.generate();

  console.log(`Client:     ${projectClient.accountAddress}`);
  console.log(`Freelancer: ${freelancer.accountAddress}`);
  console.log(`Budget:     ${Number(PROJECT_BUDGET) / 1e8} MOVE\n`);
  console.log("Milestones:");
  MILESTONES.forEach((m, i) =>
    console.log(`   ${i + 1}. ${m.name} — ${Number(m.payment) / 1e8} MOVE`),
  );
  console.log();

  // Fund accounts.
  console.log("0. Funding accounts from faucet...");
  await fundFromFaucet(projectClient);
  await fundFromFaucet(freelancer);
  console.log();

  // --- Step 1: Client escrows full budget ---
  const salt = randomSalt();
  const privKeyBytes = projectClient.privateKey.toUint8Array();
  const pubKeyBytes = getPublicKey(privKeyBytes);

  const tokenAddr = AccountAddress.fromString(TOKEN_METADATA_ADDR);
  const channelId = computeChannelId(
    projectClient.accountAddress,
    freelancer.accountAddress,
    tokenAddr,
    salt,
    pubKeyBytes,
  );

  console.log("1. Client opens channel with full project budget...");
  const openResult = await submitTx(projectClient, {
    function: `${MODULE_ADDRESS}::channel::open`,
    functionArguments: [
      REGISTRY_ADDR,
      freelancer.accountAddress.toString(),
      TOKEN_METADATA_ADDR,
      PROJECT_BUDGET,
      salt,
      pubKeyBytes,
    ],
  });
  console.log(`   Tx: ${openResult.hash}`);
  console.log(`   Channel ID: ${toHex(channelId)}\n`);

  // --- Step 2: Complete milestones ---
  let cumulativeAmount = 0n;

  for (let i = 0; i < MILESTONES.length; i++) {
    const milestone = MILESTONES[i];
    cumulativeAmount += milestone.payment;

    console.log(`2.${i + 1} Milestone: "${milestone.name}" completed`);
    console.log(
      `     Client signs voucher for ${Number(cumulativeAmount) / 1e8} MOVE cumulative`,
    );

    const voucher: Voucher = { channelId, cumulativeAmount };
    const signature = signVoucher(voucher, privKeyBytes);

    if (i < MILESTONES.length - 1) {
      // Intermediate milestone — freelancer settles.
      console.log(`     Freelancer settles on-chain...`);

      const settleResult = await submitTx(freelancer, {
        function: `${MODULE_ADDRESS}::channel::settle`,
        functionArguments: [
          REGISTRY_ADDR,
          Array.from(channelId),
          cumulativeAmount,
          Array.from(signature),
          Array.from(pubKeyBytes),
        ],
      });
      console.log(`     Tx: ${settleResult.hash}\n`);
    } else {
      // Final milestone — freelancer closes channel.
      console.log(`     Freelancer closes channel (final milestone)...`);

      const closeResult = await submitTx(freelancer, {
        function: `${MODULE_ADDRESS}::channel::close`,
        functionArguments: [
          REGISTRY_ADDR,
          Array.from(channelId),
          cumulativeAmount,
          Array.from(signature),
          Array.from(pubKeyBytes),
        ],
      });
      console.log(`     Tx: ${closeResult.hash}\n`);
    }
  }

  // --- Summary ---
  const totalPaid = Number(cumulativeAmount) / 1e8;
  const refund = Number(PROJECT_BUDGET - cumulativeAmount) / 1e8;

  console.log("=== Summary ===");
  console.log(`   Milestones completed: ${MILESTONES.length}`);
  console.log(`   Total paid:           ${totalPaid} MOVE`);
  console.log(`   Refunded to client:   ${refund} MOVE`);
  console.log(
    `   On-chain txns:        ${MILESTONES.length + 1} (open + ${MILESTONES.length - 1} settles + close)`,
  );
  console.log(`   Off-chain vouchers:   ${MILESTONES.length}`);
  console.log();
  console.log(
    "   Note: If project was cancelled at milestone 3, client would call",
  );
  console.log(
    "   requestClose(), wait 15 min grace period, then withdraw the",
  );
  console.log(`   remaining ${Number(PROJECT_BUDGET - 3_500_000n) / 1e8} MOVE.`);
}

main().catch(console.error);

import {
  Movement,
  MovementConfig,
  Network,
  Account,
  AccountAddress,
  CommittedTransactionResponse,
  InputEntryFunctionData,
} from "@moveindustries/ts-sdk";

// Movement testnet — SDK knows the fullnode, faucet, and indexer URLs.
const config = new MovementConfig({ network: Network.TESTNET });

export const client = new Movement(config);

// Deployed module address.
export const MODULE_ADDRESS =
  process.env.MODULE_ADDRESS ??
  "0x3e9edf3be513781a6db0706b652da425ad67f58b5cb366847126bf0fb716fc58";

// Registry address (same as deployer since initialize() stores it under the caller).
export const REGISTRY_ADDR = process.env.REGISTRY_ADDR ?? MODULE_ADDRESS;

// MOVE token FA metadata address on Movement testnet.
export const TOKEN_METADATA_ADDR = process.env.TOKEN_METADATA_ADDR ?? "0xa";

/** Fund an account from the Movement testnet faucet and migrate coins to FA. */
export async function fundFromFaucet(signer: Account, amount = 100_000_000) {
  const address = signer.accountAddress;
  console.log(`   Funding ${address.toString().slice(0, 10)}... with ${amount / 1e8} MOVE`);
  await client.fundAccount({ accountAddress: address, amount });

  // The faucet deposits into the legacy CoinStore, but the contract uses
  // Fungible Asset (FA). Migrate the CoinStore balance to a FA primary store.
  await submitTx(signer, {
    function: "0x1::coin::migrate_to_fungible_store",
    typeArguments: ["0x1::aptos_coin::AptosCoin"],
    functionArguments: [],
  });
}

/** Build, sign, submit a transaction and wait for confirmation. */
export async function submitTx(
  signer: Account,
  data: InputEntryFunctionData,
): Promise<CommittedTransactionResponse> {
  const txn = await client.transaction.build.simple({
    sender: signer.accountAddress,
    data,
  });
  const pending = await client.signAndSubmitTransaction({
    signer,
    transaction: txn,
  });
  const result = await client.waitForTransaction({
    transactionHash: pending.hash,
  });
  return result as CommittedTransactionResponse;
}

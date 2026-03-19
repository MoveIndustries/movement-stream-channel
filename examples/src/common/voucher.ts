import { ed25519 } from "@noble/curves/ed25519";
import { sha3_256 } from "@noble/hashes/sha3";
import { AccountAddress, Serializer } from "@moveindustries/ts-sdk";

/**
 * A voucher authorizes cumulative payment up to `cumulativeAmount` on a channel.
 * The payer (or authorized signer) signs this off-chain; the payee submits it on-chain.
 */
export interface Voucher {
  channelId: Uint8Array;
  cumulativeAmount: bigint;
}

/**
 * BCS-serialize a voucher to match the on-chain Voucher struct.
 *
 * Must match: struct Voucher { channel_id: vector<u8>, cumulative_amount: u64 }
 */
export function serializeVoucher(voucher: Voucher): Uint8Array {
  const serializer = new Serializer();
  serializer.serializeBytes(voucher.channelId);
  serializer.serializeU64(voucher.cumulativeAmount);
  return serializer.toUint8Array();
}

/**
 * Sign a voucher with an ed25519 private key.
 * Returns the 64-byte signature.
 */
export function signVoucher(
  voucher: Voucher,
  privateKey: Uint8Array,
): Uint8Array {
  const message = serializeVoucher(voucher);
  return ed25519.sign(message, privateKey);
}

/**
 * Verify a voucher signature.
 */
export function verifyVoucher(
  voucher: Voucher,
  signature: Uint8Array,
  publicKey: Uint8Array,
): boolean {
  const message = serializeVoucher(voucher);
  return ed25519.verify(signature, message, publicKey);
}

/**
 * Derive ed25519 public key from private key.
 */
export function getPublicKey(privateKey: Uint8Array): Uint8Array {
  return ed25519.getPublicKey(privateKey);
}

/**
 * Compute the channel ID client-side, matching the on-chain compute_channel_id.
 *
 * On-chain: sha3_256( bcs(payer) || bcs(payee) || bcs(token) || salt || authorized_signer_pubkey )
 * where bcs(address) is the raw 32 bytes (fixed-size, no length prefix).
 */
export function computeChannelId(
  payer: AccountAddress,
  payee: AccountAddress,
  token: AccountAddress,
  salt: Uint8Array,
  authorizedSignerPubkey: Uint8Array,
): Uint8Array {
  const payerBytes = payer.toUint8Array(); // 32 bytes
  const payeeBytes = payee.toUint8Array(); // 32 bytes
  const tokenBytes = token.toUint8Array(); // 32 bytes

  const data = new Uint8Array(
    payerBytes.length +
      payeeBytes.length +
      tokenBytes.length +
      salt.length +
      authorizedSignerPubkey.length,
  );
  let offset = 0;
  data.set(payerBytes, offset); offset += payerBytes.length;
  data.set(payeeBytes, offset); offset += payeeBytes.length;
  data.set(tokenBytes, offset); offset += tokenBytes.length;
  data.set(salt, offset); offset += salt.length;
  data.set(authorizedSignerPubkey, offset);

  return sha3_256(data);
}

/**
 * Helper to create a random salt (32 bytes).
 */
export function randomSalt(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(32));
}

/**
 * Format bytes as 0x-prefixed hex string.
 */
export function toHex(bytes: Uint8Array): string {
  return (
    "0x" +
    Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")
  );
}

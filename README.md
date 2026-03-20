# MovementStreamChannel for Movement Network

A port of [TempoStreamChannel](https://paymentauth.tempo.xyz/draft-tempo-stream-00) to Movement Network — a streaming payment channel escrow contract based on the Tempo open standard.

## What is MovementStreamChannel?

A streaming payment channel that lets two parties (payer and payee) exchange payments off-chain using signed vouchers, with only a few on-chain transactions for the entire lifecycle:

1. **Open** — Payer deposits tokens into escrow
2. **Stream** — Payer signs vouchers off-chain authorizing cumulative payment amounts
3. **Settle** — Payee submits vouchers on-chain to claim funds (can batch many vouchers into one settle)
4. **Close** — Payee closes the channel, settling the final voucher and refunding the remainder to the payer

This means 50 API calls can be paid for with just 3 on-chain transactions (open, settle, close).

## Contract

**Existing testnet deployment address:** `0x3e9edf3be513781a6db0706b652da425ad67f58b5cb366847126bf0fb716fc58`

Entry functions: `open`, `settle`, `top_up`, `close`, `request_close`, `withdraw`

### Build and test

```sh
movement move compile --named-addresses movement_stream=default
movement move test --named-addresses movement_stream=default
```

24 unit tests covering the full channel lifecycle including ed25519 voucher signature verification.

### Deploy

```sh
movement init --network custom --rest-url https://testnet.movementnetwork.xyz/v1
movement move publish --named-addresses movement_stream=default
movement move run --function-id 'default::channel::initialize'
```

## Examples

Three TypeScript scripts demonstrate different payment patterns on Movement testnet using the same contract. Each script generates fresh accounts, funds them from the testnet faucet, and runs a full channel lifecycle end-to-end.

### Setup

```sh
cd examples
pnpm install
```

### Run

```sh
pnpm run ai-api        # AI API pay-per-use
pnpm run subscription   # Monthly subscription streaming
pnpm run freelancer     # Freelancer milestone payouts
```

### 1. AI API Pay-Per-Use (`pnpm run ai-api`)

Simulates paying for 50 AI inference requests at 0.0001 MOVE each. The provider settles every 20 requests and closes at the end.

```
=== AI API Pay-Per-Use Example ===

User (payer):     0x94562de8bdaf063dbb06c50df52f37e26417d4bd4fc1483b8d3084e4dfeeef9c
Provider (payee): 0x032631b80e12c15bab4dea8958748bca1820c3accff1abfe43003f3bd09380eb
Deposit:          0.01 MOVE
Cost per request: 0.0001 MOVE

0. Funding accounts from faucet...
   Funding 0x94562de8... with 1 MOVE
   Funding 0x032631b8... with 1 MOVE

1. Opening payment channel...
   Tx: 0x3c3b4985cd80cc0c688c3f3d56c4344ca484bd8c83defd3378a8ca230662850d
   Channel ID: 0x700c6160ea909b47f942d0224f1d44e63158db649b97c1c4d12516db5a73b4f2

2. Making API requests (off-chain vouchers)...
   Request 10: cumulative = 0.001 MOVE
   Request 20: cumulative = 0.002 MOVE

3. Provider settling at request 20...
   Settled 0.002 MOVE (tx: 0x33e622645f376037f6ef84f6cc6554c857123cd6aa7245908af43b2ca4cd5e0e)

   Request 30: cumulative = 0.003 MOVE
   Request 40: cumulative = 0.004 MOVE

3. Provider settling at request 40...
   Settled 0.004 MOVE (tx: 0x42b9a14deda378963eea243452af31def7502130e64bbaa9522e8d0cbbb9b338)

   Request 50: cumulative = 0.005 MOVE

4. Provider closing channel with final settlement...
   Tx: 0x5e0c787eb6a1fbb84e77dfa6fc38a9e8a79f72a55d0f7d3be8f0b1e77af8945b

=== Summary ===
   API requests made:  50
   Total paid:         0.005 MOVE
   Refunded to user:   0.005 MOVE
   On-chain txns:      3 (open + settle + close)
   Off-chain vouchers: 50
```

### 2. Subscription Streaming (`pnpm run subscription`)

Simulates a 30-day subscription at 0.001 MOVE/day. The service settles weekly and closes at month end.

```
=== Subscription Streaming Payment Example ===

Subscriber: 0xf787cbaef5fc28cbe9bbf784bd02b4325cc722700f3b0a641b4afa33052acec1
Service:    0xe6b54d036675a6ef7594a23003b4f4146e9ffdb6fef87443e2e48e5d86fcc65b
Monthly:    0.03 MOVE
Daily rate: 0.001 MOVE/day

0. Funding accounts from faucet...

1. Subscriber opens channel for 1 month...
   Tx: 0x86fbc4a0...

2. Simulating daily usage...

   Day 7: cumulative = 0.007 MOVE
   >> Service settles week 1 on-chain

   Day 14: cumulative = 0.014 MOVE
   >> Service settles week 2 on-chain

   Day 21: cumulative = 0.021 MOVE
   >> Service settles week 3 on-chain

   Day 28: cumulative = 0.028 MOVE
   >> Service settles week 4 on-chain

3. Month ended. Service closes channel with final voucher...

=== Summary ===
   Subscription days:  30
   Total charged:      0.03 MOVE
   Refunded:           0 MOVE
   On-chain txns:      6 (open + 4 settles + close)
   Off-chain vouchers: 30
```

### 3. Freelancer Milestone Payout (`pnpm run freelancer`)

Simulates a 0.05 MOVE project budget escrowed across 5 milestones. The freelancer settles after each milestone and closes at the end.

```
=== Freelancer Milestone Payout Example ===

Client:     0xb0a3bbca0feeeaa9278c1b00da733cec298bb5779d5e25920cd59a98dd569a65
Freelancer: 0xf926ea6c3b95d8d8ad842d423c0babc72d970ece3e9549ce129eddb5ae3ea0a3
Budget:     0.05 MOVE

Milestones:
   1. Design & wireframes — 0.005 MOVE
   2. Backend implementation — 0.015 MOVE
   3. Frontend implementation — 0.015 MOVE
   4. Testing & QA — 0.01 MOVE
   5. Deployment & handoff — 0.005 MOVE

0. Funding accounts from faucet...

1. Client opens channel with full project budget...

2.1 Milestone: "Design & wireframes" completed
     Freelancer settles on-chain...

2.2 Milestone: "Backend implementation" completed
     Freelancer settles on-chain...

2.3 Milestone: "Frontend implementation" completed
     Freelancer settles on-chain...

2.4 Milestone: "Testing & QA" completed
     Freelancer settles on-chain...

2.5 Milestone: "Deployment & handoff" completed
     Freelancer closes channel (final milestone)...

=== Summary ===
   Milestones completed: 5
   Total paid:           0.05 MOVE
   Refunded to client:   0 MOVE
   On-chain txns:        6 (open + 4 settles + close)
   Off-chain vouchers:   5

   Note: If project was cancelled at milestone 3, client would call
   requestClose(), wait 15 min grace period, then withdraw the
   remaining 0.015 MOVE.
```

## How it works

```
Payer                          Payee                         On-chain
  |                              |                              |
  |-- open (deposit tokens) ---->|                         [1 tx: open]
  |                              |                              |
  |-- signed voucher #1 -------->|  (off-chain, free)           |
  |-- signed voucher #2 -------->|  (off-chain, free)           |
  |-- signed voucher #3 -------->|  (off-chain, free)           |
  |         ...                  |                              |
  |                              |-- settle (latest voucher) -->[1 tx: settle]
  |                              |                              |
  |-- signed voucher #N -------->|  (off-chain, free)           |
  |                              |                              |
  |                              |-- close (final voucher) ---->[1 tx: close]
  |                              |                              |
  |  <-- refund (unused deposit) |                              |
```

- **Vouchers** are BCS-serialized `{ channel_id, cumulative_amount }` signed with ed25519
- **Cumulative amounts** mean only the latest voucher matters — no double-spend risk
- **Grace period**: If the payer wants to close early, they call `request_close` and the payee has 15 minutes to settle any outstanding vouchers before the payer can `withdraw`

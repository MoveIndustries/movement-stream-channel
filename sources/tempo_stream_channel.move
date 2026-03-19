/// TempoStreamChannel — Unidirectional payment channel escrow for streaming payments.
///
/// Port of the Tempo open standard (draft-tempo-stream-00) to Aptos Move
/// using the Fungible Asset (FA) standard. Designed for Movement Network.
///
/// Flow:
///   1. Payer opens a channel, depositing FA tokens into module escrow
///   2. Payer signs vouchers off-chain (ed25519) authorizing cumulative amounts
///   3. Payee submits vouchers on-chain to settle (claim) funds
///   4. Channel closes cooperatively (payee) or after grace period (payer)
module tempo_stream::channel {
    use std::bcs;
    use std::signer;
    use std::vector;

    use aptos_std::smart_table::{Self, SmartTable};

    use aptos_std::ed25519;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    // -------
    // Errors
    // -------

    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_INVALID_PAYEE: u64 = 3;
    const E_ZERO_DEPOSIT: u64 = 4;
    const E_CHANNEL_EXISTS: u64 = 5;
    const E_CHANNEL_NOT_FOUND: u64 = 6;
    const E_CHANNEL_FINALIZED: u64 = 7;
    const E_NOT_PAYEE: u64 = 8;
    const E_NOT_PAYER: u64 = 9;
    const E_AMOUNT_EXCEEDS_DEPOSIT: u64 = 10;
    const E_AMOUNT_NOT_INCREASING: u64 = 11;
    const E_INVALID_SIGNATURE: u64 = 12;
    const E_CLOSE_NOT_READY: u64 = 13;
    const E_DEPOSIT_OVERFLOW: u64 = 14;

    // ---------
    // Constants
    // ---------

    /// Grace period before payer can withdraw after requesting close (15 minutes).
    const CLOSE_GRACE_PERIOD: u64 = 900;

    // -------
    // Structs
    // -------

    /// Global state: holds the escrow object and channel index.
    struct ChannelRegistry has key {
        /// Channels indexed by channel_id (sha3_256 hash).
        channels: SmartTable<vector<u8>, Channel>,
        /// Reference to extend the escrow object (for creating per-token stores).
        escrow_extend_ref: ExtendRef,
        /// Tracks which token stores have been created on the escrow object.
        known_stores: SmartTable<address, bool>,
    }

    /// A single payment channel.
    struct Channel has store, drop {
        payer: address,
        payee: address,
        /// Token metadata object address.
        token: address,
        /// Ed25519 public key authorized to sign vouchers. Empty = payer must sign.
        authorized_signer_pubkey: vector<u8>,
        deposit: u64,
        settled: u64,
        /// Timestamp when payer requested close. 0 = not requested.
        close_requested_at: u64,
        finalized: bool,
    }

    /// Voucher message that gets BCS-serialized and signed.
    struct Voucher has copy, drop {
        channel_id: vector<u8>,
        cumulative_amount: u64,
    }

    // ------
    // Events
    // ------

    #[event]
    struct ChannelOpened has drop, store {
        channel_id: vector<u8>,
        payer: address,
        payee: address,
        token: address,
        deposit: u64,
    }

    #[event]
    struct Settled has drop, store {
        channel_id: vector<u8>,
        payer: address,
        payee: address,
        cumulative_amount: u64,
        delta: u64,
    }

    #[event]
    struct TopUp has drop, store {
        channel_id: vector<u8>,
        payer: address,
        payee: address,
        additional_deposit: u64,
        new_deposit: u64,
    }

    #[event]
    struct CloseRequested has drop, store {
        channel_id: vector<u8>,
        payer: address,
        payee: address,
        close_grace_end: u64,
    }

    #[event]
    struct CloseRequestCancelled has drop, store {
        channel_id: vector<u8>,
        payer: address,
        payee: address,
    }

    #[event]
    struct ChannelClosed has drop, store {
        channel_id: vector<u8>,
        payer: address,
        payee: address,
        settled_to_payee: u64,
        refunded_to_payer: u64,
    }

    // --------------------
    // Initialize
    // --------------------

    /// Initialize the channel registry. Called once by the module deployer.
    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<ChannelRegistry>(admin_addr), E_ALREADY_INITIALIZED);

        // Create a dedicated escrow object to hold fungible stores.
        let constructor_ref = object::create_object(admin_addr);
        let escrow_extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(admin, ChannelRegistry {
            channels: smart_table::new(),
            escrow_extend_ref,
            known_stores: smart_table::new(),
        });
    }

    // --------------------
    // Public entry points
    // --------------------

    /// Open a new payment channel. Deposits `amount` of `token` into escrow.
    public entry fun open(
        payer_signer: &signer,
        registry_addr: address,
        payee: address,
        token: Object<Metadata>,
        amount: u64,
        salt: vector<u8>,
        authorized_signer_pubkey: vector<u8>,
    ) acquires ChannelRegistry {
        let payer = signer::address_of(payer_signer);
        assert!(payee != @0x0, E_INVALID_PAYEE);
        assert!(amount > 0, E_ZERO_DEPOSIT);

        let token_addr = object::object_address(&token);
        let channel_id = compute_channel_id(payer, payee, token_addr, salt, authorized_signer_pubkey);

        let registry = borrow_global_mut<ChannelRegistry>(registry_addr);
        assert!(!smart_table::contains(&registry.channels, channel_id), E_CHANNEL_EXISTS);

        // Ensure escrow has a store for this token.
        ensure_escrow_store(registry, token);

        // Transfer tokens from payer to escrow.
        let fa = primary_fungible_store::withdraw(payer_signer, token, amount);
        let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
        let escrow_addr = signer::address_of(&escrow_signer);
        let escrow_store = primary_fungible_store::ensure_primary_store_exists(escrow_addr, token);
        fungible_asset::deposit(escrow_store, fa);

        smart_table::add(&mut registry.channels, channel_id, Channel {
            payer,
            payee,
            token: token_addr,
            authorized_signer_pubkey,
            deposit: amount,
            settled: 0,
            close_requested_at: 0,
            finalized: false,
        });

        event::emit(ChannelOpened {
            channel_id,
            payer,
            payee,
            token: token_addr,
            deposit: amount,
        });
    }

    /// Settle funds using a signed voucher. Only callable by the payee.
    public entry fun settle(
        payee_signer: &signer,
        registry_addr: address,
        channel_id: vector<u8>,
        cumulative_amount: u64,
        signature: vector<u8>,
        public_key: vector<u8>,
    ) acquires ChannelRegistry {
        let caller = signer::address_of(payee_signer);
        let registry = borrow_global_mut<ChannelRegistry>(registry_addr);
        assert!(smart_table::contains(&registry.channels, channel_id), E_CHANNEL_NOT_FOUND);

        let channel = smart_table::borrow_mut(&mut registry.channels, channel_id);
        assert!(!channel.finalized, E_CHANNEL_FINALIZED);
        assert!(caller == channel.payee, E_NOT_PAYEE);
        assert!(cumulative_amount <= channel.deposit, E_AMOUNT_EXCEEDS_DEPOSIT);
        assert!(cumulative_amount > channel.settled, E_AMOUNT_NOT_INCREASING);

        // Verify voucher signature.
        verify_voucher(channel_id, cumulative_amount, signature, public_key, channel.authorized_signer_pubkey);

        let delta = cumulative_amount - channel.settled;
        channel.settled = cumulative_amount;
        let payee = channel.payee;
        let payer = channel.payer;
        let token_addr = channel.token;

        // Transfer delta from escrow to payee.
        let token = object::address_to_object<Metadata>(token_addr);
        let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
        let escrow_addr = signer::address_of(&escrow_signer);
        let escrow_store = primary_fungible_store::ensure_primary_store_exists(escrow_addr, token);
        let fa = fungible_asset::withdraw(&escrow_signer, escrow_store, delta);
        primary_fungible_store::deposit(payee, fa);

        event::emit(Settled {
            channel_id,
            payer,
            payee,
            cumulative_amount,
            delta,
        });
    }

    /// Add more funds to an existing channel. Only callable by the payer.
    public entry fun top_up(
        payer_signer: &signer,
        registry_addr: address,
        channel_id: vector<u8>,
        additional_deposit: u64,
    ) acquires ChannelRegistry {
        let caller = signer::address_of(payer_signer);
        assert!(additional_deposit > 0, E_ZERO_DEPOSIT);

        let registry = borrow_global_mut<ChannelRegistry>(registry_addr);
        assert!(smart_table::contains(&registry.channels, channel_id), E_CHANNEL_NOT_FOUND);

        let channel = smart_table::borrow_mut(&mut registry.channels, channel_id);
        assert!(!channel.finalized, E_CHANNEL_FINALIZED);
        assert!(caller == channel.payer, E_NOT_PAYER);

        let new_deposit = channel.deposit + additional_deposit;
        // Overflow check: u64 max
        assert!(new_deposit >= channel.deposit, E_DEPOSIT_OVERFLOW);
        channel.deposit = new_deposit;

        // Transfer additional tokens to escrow.
        let token = object::address_to_object<Metadata>(channel.token);
        let fa = primary_fungible_store::withdraw(payer_signer, token, additional_deposit);
        let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
        let escrow_addr = signer::address_of(&escrow_signer);
        let escrow_store = primary_fungible_store::ensure_primary_store_exists(escrow_addr, token);
        fungible_asset::deposit(escrow_store, fa);

        // Cancel pending close request if any.
        let payee = channel.payee;
        let payer = channel.payer;
        if (channel.close_requested_at != 0) {
            channel.close_requested_at = 0;
            event::emit(CloseRequestCancelled { channel_id, payer, payee });
        };

        event::emit(TopUp {
            channel_id,
            payer,
            payee,
            additional_deposit,
            new_deposit,
        });
    }

    /// Payer requests early closure. Starts the grace period.
    public entry fun request_close(
        payer_signer: &signer,
        registry_addr: address,
        channel_id: vector<u8>,
    ) acquires ChannelRegistry {
        let caller = signer::address_of(payer_signer);
        let registry = borrow_global_mut<ChannelRegistry>(registry_addr);
        assert!(smart_table::contains(&registry.channels, channel_id), E_CHANNEL_NOT_FOUND);

        let channel = smart_table::borrow_mut(&mut registry.channels, channel_id);
        assert!(!channel.finalized, E_CHANNEL_FINALIZED);
        assert!(caller == channel.payer, E_NOT_PAYER);

        if (channel.close_requested_at == 0) {
            let now = timestamp::now_seconds();
            channel.close_requested_at = now;
            event::emit(CloseRequested {
                channel_id,
                payer: channel.payer,
                payee: channel.payee,
                close_grace_end: now + CLOSE_GRACE_PERIOD,
            });
        };
    }

    /// Payee closes channel immediately with optional final settlement.
    public entry fun close(
        payee_signer: &signer,
        registry_addr: address,
        channel_id: vector<u8>,
        cumulative_amount: u64,
        signature: vector<u8>,
        public_key: vector<u8>,
    ) acquires ChannelRegistry {
        let caller = signer::address_of(payee_signer);
        let registry = borrow_global_mut<ChannelRegistry>(registry_addr);
        assert!(smart_table::contains(&registry.channels, channel_id), E_CHANNEL_NOT_FOUND);

        let channel = smart_table::borrow_mut(&mut registry.channels, channel_id);
        assert!(!channel.finalized, E_CHANNEL_FINALIZED);
        assert!(caller == channel.payee, E_NOT_PAYEE);

        let settled_amount = channel.settled;
        let payer = channel.payer;
        let payee = channel.payee;
        let token_addr = channel.token;
        let deposit = channel.deposit;

        let token = object::address_to_object<Metadata>(token_addr);
        let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
        let escrow_addr = signer::address_of(&escrow_signer);
        let escrow_store = primary_fungible_store::ensure_primary_store_exists(escrow_addr, token);

        // Final settlement if needed.
        if (cumulative_amount > settled_amount) {
            assert!(cumulative_amount <= deposit, E_AMOUNT_EXCEEDS_DEPOSIT);
            verify_voucher(channel_id, cumulative_amount, signature, public_key, channel.authorized_signer_pubkey);

            let delta = cumulative_amount - settled_amount;
            let fa = fungible_asset::withdraw(&escrow_signer, escrow_store, delta);
            primary_fungible_store::deposit(payee, fa);
            settled_amount = cumulative_amount;
        };

        // Refund remainder to payer.
        let refund_amount = deposit - settled_amount;
        if (refund_amount > 0) {
            let refund = fungible_asset::withdraw(&escrow_signer, escrow_store, refund_amount);
            primary_fungible_store::deposit(payer, refund);
        };

        // Finalize.
        channel.finalized = true;
        channel.settled = settled_amount;

        event::emit(ChannelClosed {
            channel_id,
            payer,
            payee,
            settled_to_payee: settled_amount,
            refunded_to_payer: refund_amount,
        });
    }

    /// Payer withdraws remaining funds after grace period expires.
    public entry fun withdraw(
        payer_signer: &signer,
        registry_addr: address,
        channel_id: vector<u8>,
    ) acquires ChannelRegistry {
        let caller = signer::address_of(payer_signer);
        let registry = borrow_global_mut<ChannelRegistry>(registry_addr);
        assert!(smart_table::contains(&registry.channels, channel_id), E_CHANNEL_NOT_FOUND);

        let channel = smart_table::borrow_mut(&mut registry.channels, channel_id);
        assert!(!channel.finalized, E_CHANNEL_FINALIZED);
        assert!(caller == channel.payer, E_NOT_PAYER);

        let now = timestamp::now_seconds();
        assert!(
            channel.close_requested_at != 0
                && now >= channel.close_requested_at + CLOSE_GRACE_PERIOD,
            E_CLOSE_NOT_READY,
        );

        let payer = channel.payer;
        let payee = channel.payee;
        let token_addr = channel.token;
        let deposit = channel.deposit;
        let settled_amount = channel.settled;

        let refund_amount = deposit - settled_amount;
        if (refund_amount > 0) {
            let token = object::address_to_object<Metadata>(token_addr);
            let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
            let escrow_addr = signer::address_of(&escrow_signer);
            let escrow_store = primary_fungible_store::ensure_primary_store_exists(escrow_addr, token);
            let refund = fungible_asset::withdraw(&escrow_signer, escrow_store, refund_amount);
            primary_fungible_store::deposit(payer, refund);
        };

        channel.finalized = true;

        event::emit(ChannelClosed {
            channel_id,
            payer,
            payee,
            settled_to_payee: settled_amount,
            refunded_to_payer: refund_amount,
        });
    }

    // --------------
    // View functions
    // --------------

    #[view]
    /// Compute the channel ID for given parameters.
    public fun compute_channel_id(
        payer: address,
        payee: address,
        token: address,
        salt: vector<u8>,
        authorized_signer_pubkey: vector<u8>,
    ): vector<u8> {
        let data = bcs::to_bytes(&payer);
        vector::append(&mut data, bcs::to_bytes(&payee));
        vector::append(&mut data, bcs::to_bytes(&token));
        vector::append(&mut data, salt);
        vector::append(&mut data, authorized_signer_pubkey);
        std::hash::sha3_256(data)
    }

    #[view]
    /// Get channel state. Returns (payer, payee, token, deposit, settled, close_requested_at, finalized).
    public fun get_channel(
        registry_addr: address,
        channel_id: vector<u8>,
    ): (address, address, address, u64, u64, u64, bool) acquires ChannelRegistry {
        let registry = borrow_global<ChannelRegistry>(registry_addr);
        assert!(smart_table::contains(&registry.channels, channel_id), E_CHANNEL_NOT_FOUND);
        let ch = smart_table::borrow(&registry.channels, channel_id);
        (ch.payer, ch.payee, ch.token, ch.deposit, ch.settled, ch.close_requested_at, ch.finalized)
    }

    #[view]
    /// Get the grace period constant.
    public fun close_grace_period(): u64 {
        CLOSE_GRACE_PERIOD
    }

    // ------------------
    // Internal functions
    // ------------------

    /// Ensure the escrow object has a primary fungible store for the given token.
    fun ensure_escrow_store(registry: &mut ChannelRegistry, token: Object<Metadata>) {
        let token_addr = object::object_address(&token);
        if (!smart_table::contains(&registry.known_stores, token_addr)) {
            let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
            let escrow_addr = signer::address_of(&escrow_signer);
            primary_fungible_store::ensure_primary_store_exists(escrow_addr, token);
            smart_table::add(&mut registry.known_stores, token_addr, true);
        };
    }

    /// Verify an ed25519 voucher signature.
    fun verify_voucher(
        channel_id: vector<u8>,
        cumulative_amount: u64,
        signature_bytes: vector<u8>,
        public_key_bytes: vector<u8>,
        authorized_pubkey: vector<u8>,
    ) {
        // If channel has an authorized signer, the provided key must match.
        if (vector::length(&authorized_pubkey) > 0) {
            assert!(public_key_bytes == authorized_pubkey, E_INVALID_SIGNATURE);
        };

        let voucher = Voucher { channel_id, cumulative_amount };
        let message = bcs::to_bytes(&voucher);

        let sig = ed25519::new_signature_from_bytes(signature_bytes);
        let pk = ed25519::new_unvalidated_public_key_from_bytes(public_key_bytes);
        assert!(
            ed25519::signature_verify_strict(&sig, &pk, message),
            E_INVALID_SIGNATURE,
        );
    }
}

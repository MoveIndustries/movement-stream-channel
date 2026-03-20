#[test_only]
module movement_stream::channel_tests {
    use std::bcs;
    use std::signer;
    use std::string;
    use std::vector;

    use aptos_std::ed25519;

    use aptos_framework::account;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use movement_stream::channel;

    // ----------------
    // Test helpers
    // ----------------

    /// Set up the test environment: create accounts, deploy a mock FA token,
    /// initialize the registry, and mint tokens to the payer.
    fun setup(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ): object::Object<Metadata> {
        // Initialize timestamp for tests.
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1_000_000_000); // 1000s

        // Create test accounts.
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(payer));
        account::create_account_for_test(signer::address_of(payee));

        // Create a mock FA token.
        let constructor_ref = object::create_named_object(admin, b"TestUSDC");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            std::option::none(), // no max supply
            string::utf8(b"Test USDC"),
            string::utf8(b"USDC"),
            6,
            string::utf8(b""),
            string::utf8(b""),
        );
        let token_metadata = object::object_from_constructor_ref<Metadata>(&constructor_ref);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);

        // Mint tokens to payer.
        let fa = fungible_asset::mint(&mint_ref, 100_000_000); // 100 USDC
        primary_fungible_store::deposit(signer::address_of(payer), fa);

        // Initialize the channel registry.
        channel::initialize(admin);

        token_metadata
    }

    fun default_salt(): vector<u8> {
        b"test_salt_00000000000000000000000"
    }

    fun open_channel(
        payer: &signer,
        admin_addr: address,
        payee_addr: address,
        token: object::Object<Metadata>,
        amount: u64,
    ): vector<u8> {
        let salt = default_salt();
        channel::open(
            payer,
            admin_addr,
            payee_addr,
            token,
            amount,
            salt,
            vector::empty(),
        );
        channel::compute_channel_id(
            signer::address_of(payer),
            payee_addr,
            object::object_address(&token),
            salt,
            vector::empty(),
        )
    }

    fun open_channel_with_signer(
        payer: &signer,
        admin_addr: address,
        payee_addr: address,
        token: object::Object<Metadata>,
        amount: u64,
        authorized_pubkey: vector<u8>,
    ): vector<u8> {
        let salt = default_salt();
        channel::open(
            payer,
            admin_addr,
            payee_addr,
            token,
            amount,
            salt,
            authorized_pubkey,
        );
        channel::compute_channel_id(
            signer::address_of(payer),
            payee_addr,
            object::object_address(&token),
            salt,
            authorized_pubkey,
        )
    }

    /// Sign a voucher matching the on-chain Voucher struct.
    /// Returns (signature_bytes, pubkey_bytes).
    fun sign_test_voucher(
        sk: &ed25519::SecretKey,
        pk: &ed25519::ValidatedPublicKey,
        channel_id: vector<u8>,
        cumulative_amount: u64,
    ): (vector<u8>, vector<u8>) {
        // BCS-serialize: vector<u8> then u64, matching struct field order.
        let msg = bcs::to_bytes(&channel_id);
        vector::append(&mut msg, bcs::to_bytes(&cumulative_amount));
        let sig = ed25519::sign_arbitrary_bytes(sk, msg);
        (ed25519::signature_to_bytes(&sig), ed25519::validated_public_key_to_bytes(pk))
    }

    // ----------------
    // Tests
    // ----------------

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_open_channel(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        // Check payer balance before.
        assert!(primary_fungible_store::balance(payer_addr, token) == 100_000_000, 0);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);

        // Payer balance decreased by deposit.
        assert!(primary_fungible_store::balance(payer_addr, token) == 90_000_000, 1);

        // Channel state is correct.
        let (ch_payer, ch_payee, ch_token, deposit, settled, close_req, finalized) =
            channel::get_channel(admin_addr, channel_id);
        assert!(ch_payer == payer_addr, 2);
        assert!(ch_payee == payee_addr, 3);
        assert!(ch_token == object::object_address(&token), 4);
        assert!(deposit == 10_000_000, 5);
        assert!(settled == 0, 6);
        assert!(close_req == 0, 7);
        assert!(!finalized, 8);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 5, location = movement_stream::channel)] // E_CHANNEL_EXISTS
    fun test_open_duplicate_channel(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        open_channel(payer, admin_addr, payee_addr, token, 10_000_000);
        // Same salt + params = same channel_id, should fail.
        open_channel(payer, admin_addr, payee_addr, token, 10_000_000);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 3, location = movement_stream::channel)] // E_INVALID_PAYEE
    fun test_open_zero_payee(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);

        channel::open(
            payer,
            admin_addr,
            @0x0,
            token,
            10_000_000,
            default_salt(),
            vector::empty(),
        );
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 4, location = movement_stream::channel)] // E_ZERO_DEPOSIT
    fun test_open_zero_deposit(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        channel::open(
            payer,
            admin_addr,
            payee_addr,
            token,
            0,
            default_salt(),
            vector::empty(),
        );
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_top_up(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);

        // Top up 5 USDC.
        channel::top_up(payer, admin_addr, channel_id, 5_000_000);

        // Payer balance: 100 - 10 - 5 = 85.
        assert!(primary_fungible_store::balance(payer_addr, token) == 85_000_000, 0);

        // Channel deposit increased.
        let (_payer, _payee, _token, deposit, _settled, _close_req, _fin) =
            channel::get_channel(admin_addr, channel_id);
        assert!(deposit == 15_000_000, 1);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 9, location = movement_stream::channel)] // E_NOT_PAYER
    fun test_top_up_not_payer(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);
        // Payee tries to top up — should fail.
        channel::top_up(payee, admin_addr, channel_id, 1_000_000);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_top_up_cancels_close_request(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);

        // Payer requests close.
        channel::request_close(payer, admin_addr, channel_id);
        let (_p, _pe, _t, _d, _s, close_req, _f) = channel::get_channel(admin_addr, channel_id);
        assert!(close_req != 0, 0);

        // Top up cancels the close request.
        channel::top_up(payer, admin_addr, channel_id, 1_000_000);
        let (_p2, _pe2, _t2, _d2, _s2, close_req2, _f2) = channel::get_channel(admin_addr, channel_id);
        assert!(close_req2 == 0, 1);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_request_close(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);

        channel::request_close(payer, admin_addr, channel_id);

        let (_p, _pe, _t, _d, _s, close_req, _f) = channel::get_channel(admin_addr, channel_id);
        assert!(close_req != 0, 0);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 13, location = movement_stream::channel)] // E_CLOSE_NOT_READY
    fun test_withdraw_before_grace_period(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);

        channel::request_close(payer, admin_addr, channel_id);
        // Try to withdraw immediately — grace period hasn't passed.
        channel::withdraw(payer, admin_addr, channel_id);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_withdraw_after_grace_period(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);

        channel::request_close(payer, admin_addr, channel_id);

        // Fast-forward past grace period (15 minutes = 900 seconds).
        // Current time is 1000s, so set to 1000 + 901 = 1901s.
        timestamp::update_global_time_for_test(1_901_000_000);

        channel::withdraw(payer, admin_addr, channel_id);

        // Payer gets full refund (nothing was settled).
        assert!(primary_fungible_store::balance(payer_addr, token) == 100_000_000, 0);

        // Channel is finalized.
        let (_p, _pe, _t, _d, _s, _c, finalized) = channel::get_channel(admin_addr, channel_id);
        assert!(finalized, 1);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 13, location = movement_stream::channel)] // E_CLOSE_NOT_READY
    fun test_withdraw_without_request(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);
        // No request_close — withdraw should fail.
        channel::withdraw(payer, admin_addr, channel_id);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 7, location = movement_stream::channel)] // E_CHANNEL_FINALIZED
    fun test_double_withdraw(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);
        channel::request_close(payer, admin_addr, channel_id);
        timestamp::update_global_time_for_test(1_901_000_000);

        channel::withdraw(payer, admin_addr, channel_id);
        // Second withdraw on finalized channel should fail.
        channel::withdraw(payer, admin_addr, channel_id);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 9, location = movement_stream::channel)] // E_NOT_PAYER
    fun test_request_close_not_payer(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let channel_id = open_channel(payer, admin_addr, payee_addr, token, 10_000_000);
        // Payee tries to request close — should fail.
        channel::request_close(payee, admin_addr, channel_id);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_close_grace_period_view(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let _token = setup(aptos_framework, admin, payer, payee);
        assert!(channel::close_grace_period() == 900, 0);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_compute_channel_id_deterministic(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let _token = setup(aptos_framework, admin, payer, payee);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        let id1 = channel::compute_channel_id(payer_addr, payee_addr, @0xCAFE, b"salt1", vector::empty());
        let id2 = channel::compute_channel_id(payer_addr, payee_addr, @0xCAFE, b"salt1", vector::empty());
        let id3 = channel::compute_channel_id(payer_addr, payee_addr, @0xCAFE, b"salt2", vector::empty());

        assert!(id1 == id2, 0); // same inputs = same id
        assert!(id1 != id3, 1); // different salt = different id
    }

    // --------------------------------
    // Settle / Close tests (ed25519)
    // --------------------------------

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_settle_with_signature(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        // Generate an authorized signer keypair.
        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Sign a voucher for 3 USDC cumulative.
        let (sig_bytes, pub_bytes) = sign_test_voucher(&sk, &vpk, channel_id, 3_000_000);

        // Payee settles.
        channel::settle(payee, admin_addr, channel_id, 3_000_000, sig_bytes, pub_bytes);

        // Payee received 3 USDC.
        assert!(primary_fungible_store::balance(payee_addr, token) == 3_000_000, 0);
        // Payer still has 90 (100 - 10 deposit).
        assert!(primary_fungible_store::balance(payer_addr, token) == 90_000_000, 1);

        // Channel state updated.
        let (_p, _pe, _t, deposit, settled, _c, _f) = channel::get_channel(admin_addr, channel_id);
        assert!(deposit == 10_000_000, 2);
        assert!(settled == 3_000_000, 3);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_settle_incremental(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // First settle: 2 USDC.
        let (sig1, pub1) = sign_test_voucher(&sk, &vpk, channel_id, 2_000_000);
        channel::settle(payee, admin_addr, channel_id, 2_000_000, sig1, pub1);
        assert!(primary_fungible_store::balance(payee_addr, token) == 2_000_000, 0);

        // Second settle: 5 USDC cumulative (delta = 3).
        let (sig2, pub2) = sign_test_voucher(&sk, &vpk, channel_id, 5_000_000);
        channel::settle(payee, admin_addr, channel_id, 5_000_000, sig2, pub2);
        assert!(primary_fungible_store::balance(payee_addr, token) == 5_000_000, 1);

        let (_p, _pe, _t, _d, settled, _c, _f) = channel::get_channel(admin_addr, channel_id);
        assert!(settled == 5_000_000, 2);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 11, location = movement_stream::channel)] // E_AMOUNT_NOT_INCREASING
    fun test_settle_not_increasing(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Settle 5 USDC.
        let (sig1, pub1) = sign_test_voucher(&sk, &vpk, channel_id, 5_000_000);
        channel::settle(payee, admin_addr, channel_id, 5_000_000, sig1, pub1);

        // Try to settle 3 USDC (less than current settled) — should fail.
        let (sig2, pub2) = sign_test_voucher(&sk, &vpk, channel_id, 3_000_000);
        channel::settle(payee, admin_addr, channel_id, 3_000_000, sig2, pub2);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 10, location = movement_stream::channel)] // E_AMOUNT_EXCEEDS_DEPOSIT
    fun test_settle_exceeds_deposit(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Try to settle more than deposit.
        let (sig, pubk) = sign_test_voucher(&sk, &vpk, channel_id, 20_000_000);
        channel::settle(payee, admin_addr, channel_id, 20_000_000, sig, pubk);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 8, location = movement_stream::channel)] // E_NOT_PAYEE
    fun test_settle_not_payee(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Payer tries to settle — should fail.
        let (sig, pubk) = sign_test_voucher(&sk, &vpk, channel_id, 3_000_000);
        channel::settle(payer, admin_addr, channel_id, 3_000_000, sig, pubk);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    #[expected_failure(abort_code = 12, location = movement_stream::channel)] // E_INVALID_SIGNATURE
    fun test_settle_wrong_key(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payee_addr = signer::address_of(payee);

        let (_sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Sign with a different key.
        let (wrong_sk, wrong_vpk) = ed25519::generate_keys();
        let (sig, _) = sign_test_voucher(&wrong_sk, &wrong_vpk, channel_id, 3_000_000);
        let wrong_pub = ed25519::validated_public_key_to_bytes(&wrong_vpk);
        channel::settle(payee, admin_addr, channel_id, 3_000_000, sig, wrong_pub);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_close_with_final_settlement(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Settle 3 USDC first.
        let (sig1, pub1) = sign_test_voucher(&sk, &vpk, channel_id, 3_000_000);
        channel::settle(payee, admin_addr, channel_id, 3_000_000, sig1, pub1);

        // Close with final voucher at 7 USDC cumulative.
        let (sig2, pub2) = sign_test_voucher(&sk, &vpk, channel_id, 7_000_000);
        channel::close(payee, admin_addr, channel_id, 7_000_000, sig2, pub2);

        // Payee received 7 total.
        assert!(primary_fungible_store::balance(payee_addr, token) == 7_000_000, 0);
        // Payer got 3 USDC refund (10 - 7).
        assert!(primary_fungible_store::balance(payer_addr, token) == 93_000_000, 1);

        // Channel finalized.
        let (_p, _pe, _t, _d, settled, _c, finalized) = channel::get_channel(admin_addr, channel_id);
        assert!(settled == 7_000_000, 2);
        assert!(finalized, 3);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_close_no_additional_settlement(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Settle 4 USDC.
        let (sig1, pub1) = sign_test_voucher(&sk, &vpk, channel_id, 4_000_000);
        channel::settle(payee, admin_addr, channel_id, 4_000_000, sig1, pub1);

        // Close at same amount (no additional settlement).
        channel::close(
            payee, admin_addr, channel_id, 4_000_000,
            vector::empty(), vector::empty(),
        );

        // Payee has 4, payer got 6 back.
        assert!(primary_fungible_store::balance(payee_addr, token) == 4_000_000, 0);
        assert!(primary_fungible_store::balance(payer_addr, token) == 96_000_000, 1);

        let (_p, _pe, _t, _d, _s, _c, finalized) = channel::get_channel(admin_addr, channel_id);
        assert!(finalized, 2);
    }

    #[test(aptos_framework = @0x1, admin = @movement_stream, payer = @0xA, payee = @0xB)]
    fun test_settle_then_withdraw_after_grace(
        aptos_framework: &signer,
        admin: &signer,
        payer: &signer,
        payee: &signer,
    ) {
        let token = setup(aptos_framework, admin, payer, payee);
        let admin_addr = signer::address_of(admin);
        let payer_addr = signer::address_of(payer);
        let payee_addr = signer::address_of(payee);

        let (sk, vpk) = ed25519::generate_keys();
        let pk_bytes = ed25519::validated_public_key_to_bytes(&vpk);

        let channel_id = open_channel_with_signer(
            payer, admin_addr, payee_addr, token, 10_000_000, pk_bytes,
        );

        // Settle 2 USDC.
        let (sig, pubk) = sign_test_voucher(&sk, &vpk, channel_id, 2_000_000);
        channel::settle(payee, admin_addr, channel_id, 2_000_000, sig, pubk);
        assert!(primary_fungible_store::balance(payee_addr, token) == 2_000_000, 0);

        // Payer requests close, waits grace period, withdraws remainder.
        channel::request_close(payer, admin_addr, channel_id);
        timestamp::update_global_time_for_test(1_901_000_000);
        channel::withdraw(payer, admin_addr, channel_id);

        // Payer gets back 8 (10 deposit - 2 settled).
        assert!(primary_fungible_store::balance(payer_addr, token) == 98_000_000, 1);
        // Payee kept 2.
        assert!(primary_fungible_store::balance(payee_addr, token) == 2_000_000, 2);

        let (_p, _pe, _t, _d, settled, _c, finalized) = channel::get_channel(admin_addr, channel_id);
        assert!(settled == 2_000_000, 3);
        assert!(finalized, 4);
    }
}

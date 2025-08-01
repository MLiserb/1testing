module swap_addr::swap {
    use std::signer;
    use std::vector;
    use std::bcs;
    use std::aptos_hash;
    use aptos_std::string::{Self, String};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::type_info::{Self, TypeInfo};
    use aptos_framework::table::{Self, Table};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_std::type_info as std_type_info;

    /// Safety deposit amount (in APT)
    const SAFETY_DEPOSIT_AMOUNT: u64 = 100000; // 0.001 APT

    /// Error constants
    const ESWAP_LEDGER_ALREADY_EXISTS: u64 = 1;
    const ESWAP_LEDGER_DOES_NOT_EXIST: u64 = 2;
    const EINVALID_AMOUNT: u64 = 3;
    const EORDER_DOES_NOT_EXIST: u64 = 4;
    const EORDER_ALREADY_FILLED_OR_CANCELLED: u64 = 5;
    const EORDER_EXPIRED: u64 = 6;
    const EORDER_NOT_EXPIRED: u64 = 7;
    const EINVALID_MAKER: u64 = 8;
    const EINSUFFICIENT_AMOUNT: u64 = 9;
    const EINVALID_COIN_TYPE: u64 = 10;
    const EINVALID_SECRET: u64 = 11;
    const EESCROWS_NOT_FUNDED: u64 = 12;
    const EINVALID_RESOLVER: u64 = 13;
    const ESECRET_ALREADY_REVEALED: u64 = 14;
    const EINVALID_SECRET_HASH: u64 = 15;
    const EORDER_NOT_DEPOSITED: u64 = 16;
    const ENOT_MAKER: u64 = 17;
    const EBAD_STATE: u64 = 18;

    /// Resource struct representing order metadata
    public struct OrderMetadata has store, drop, copy {
        id: u64,
        maker_address: address,
        escrow_address: address,    // Escrow holding maker's source coins
        coin_type: TypeInfo,
        amount: u64,
        min_amount: u64,
        expiration_timestamp_secs: u64,
        secret_hash: vector<u8>,        // Hash of the secret
        resolver_address: address,      // Address of resolver who deposited
        revealed_secret: vector<u8>,    // The actual secret (empty until revealed)
    }

    /// Resource struct for the swap ledger
    struct SwapLedger has key {
        orders: Table<u64, OrderMetadata>,
        order_id_counter: u64,
        signer_cap: SignerCapability,
    }

    /// Initialize the swap ledger
    public entry fun initialize_swap_ledger(module_owner: &signer) {
        let module_owner_addr = signer::address_of(module_owner);
        
        assert!(!exists<SwapLedger>(module_owner_addr), ESWAP_LEDGER_ALREADY_EXISTS);
        
        let seed = vector::empty<u8>();
        vector::append(&mut seed, b"swap_seed");
        let (_, signer_cap) = account::create_resource_account(module_owner, seed);
        
        move_to(module_owner, SwapLedger {
            orders: table::new(),
            order_id_counter: 0,
            signer_cap,});
    }

    public entry fun initialize_swap_ledger_v2<SrcCoinType>(module_owner: &signer) {
        let module_owner_addr = signer::address_of(module_owner);
        
        assert!(!exists<SwapLedger>(module_owner_addr), ESWAP_LEDGER_ALREADY_EXISTS);
        
        let seed = vector::empty<u8>();
        vector::append(&mut seed, b"swap_seed");
        let (_, signer_cap) = account::create_resource_account(module_owner, seed);
        
        move_to(module_owner, SwapLedger {
            orders: table::new(),
            order_id_counter: 0,
            signer_cap,});

        
        coin::register<SrcCoinType>(module_owner);
    }

    /// Phase 1: Announce - Maker creates order with secret hash and deposits funds
    public entry fun announce_order<SrcCoinType>(
        maker: &signer,
        src_amount: u64,
        min_dst_amount: u64,
        expiration_duration_secs: u64,
        secret_hash: vector<u8>
    ) acquires SwapLedger {
        // Validate inputs
        assert!(src_amount > 0, EINVALID_AMOUNT);
        assert!(min_dst_amount > 0, EINVALID_AMOUNT);
        assert!(vector::length(&secret_hash) == 32, EINVALID_SECRET_HASH);
        
        let maker_addr = signer::address_of(maker);
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        
        let ledger = borrow_global_mut<SwapLedger>(module_addr);
        
        // Generate order ID
        let order_id = ledger.order_id_counter;
        ledger.order_id_counter = order_id + 1;
        
        // Pre-approve the transfer (maker must have approved the amount)
        // In a real implementation, we'd check allowance here
        // assert!(coin::balance<SrcCoinType>(maker_addr) >= src_amount, EINSUFFICIENT_AMOUNT);
        // assert!(coin::balance<AptosCoin>(maker_addr) >= SAFETY_DEPOSIT_AMOUNT, EINSUFFICIENT_AMOUNT);
        
        // Create escrow addresses
        let src_seed = vector::empty<u8>();
        vector::append(&mut src_seed, b"src_escrow_");
        vector::append(&mut src_seed, bcs::to_bytes(&order_id));
        
        
        let escrow_signer = account::create_signer_with_capability(&ledger.signer_cap);
        let src_escrow_addr = account::create_resource_address(&signer::address_of(&escrow_signer), src_seed);
        
        // Create and register the source escrow account
        ensure_escrow_and_register<SrcCoinType>(&ledger.signer_cap, src_escrow_addr, src_seed);
        
        // Get type info
        let src_coin_type = type_info::type_of<SrcCoinType>();
        
        let expiration_timestamp = timestamp::now_seconds() + expiration_duration_secs;
        
        // Withdraw funds from maker and deposit to escrow
        let maker_coins = coin::withdraw<SrcCoinType>(maker, src_amount);
        coin::deposit(src_escrow_addr, maker_coins);
        
        // Create order with funded status
        let order = OrderMetadata {
            id: order_id,
            maker_address: maker_addr,
            escrow_address: src_escrow_addr,
            coin_type: src_coin_type,
            amount: src_amount,
            min_amount: min_dst_amount,
            expiration_timestamp_secs: expiration_timestamp,
            secret_hash,
            resolver_address: @0x0,
            revealed_secret: vector::empty<u8>(),
        };
        
        table::add(&mut ledger.orders, order_id, order);
    }

    public entry fun fund_src_escrow<SrcCoinType>(
    maker: &signer,
    order_id: u64
    ) acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Only the original maker may call this.
        assert!(signer::address_of(maker) == order.maker_address, ENOT_MAKER);

        // Make sure we are using the right coin type.
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        /* create escrow if needed & register coins */
        let src_seed = vector::empty<u8>();
        vector::append(&mut src_seed, b"src_escrow_");
        vector::append(&mut src_seed, bcs::to_bytes(&order_id));
        ensure_escrow_and_register<SrcCoinType>(&ledger.signer_cap, order.escrow_address, src_seed);

        /* move the funds */
        let maker_coins = coin::withdraw<SrcCoinType>(maker, order.amount);
        coin::deposit(order.escrow_address, maker_coins);

        /* maker's safety deposit in APT */
        // let safety_coins  = coin::withdraw<AptosCoin>(maker, SAFETY_DEPOSIT_AMOUNT);
        // coin::deposit(order.escrow_address, safety_coins);
    }

    public entry fun fund_dst_escrow<CoinType>(
    resolver: &signer,
    dst_amount: u64,
    expiration_duration_secs: u64,
    secret_hash: vector<u8>
    ) acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        let order_id = ledger.order_id_counter;
        ledger.order_id_counter = order_id + 1;

        /* order must not be expired */
        assert!(timestamp::now_seconds() < expiration_duration_secs, EORDER_EXPIRED);

        /* create / register destination escrow if needed */
        let dst_seed = vector::empty<u8>();
        vector::append(&mut dst_seed, b"dst_escrow_");
        vector::append(&mut dst_seed, bcs::to_bytes(&order_id));

        let escrow_signer = account::create_signer_with_capability(&ledger.signer_cap);
        let dst_escrow_addr = account::create_resource_address(&signer::address_of(&escrow_signer), dst_seed);

        // Create and register the source escrow account
        ensure_escrow_and_register<CoinType>(&ledger.signer_cap, dst_escrow_addr, dst_seed);
        
        // /* move the solver's funds */
        let dst_coins = coin::withdraw<CoinType>(resolver, dst_amount);
        coin::deposit(dst_escrow_addr, dst_coins);

        // /* solver's safety deposit in APT */
        // let safety = coin::withdraw<AptosCoin>(resolver, SAFETY_DEPOSIT_AMOUNT);
        // coin::deposit(dst_escrow_addr, safety);

         // Create order with funded status
        let order = OrderMetadata {
            id: order_id,
            maker_address: @0x0,
            escrow_address: dst_escrow_addr,
            coin_type: type_info::type_of<CoinType>(),
            amount: dst_amount,
            min_amount: 0,
            expiration_timestamp_secs: expiration_duration_secs,
            secret_hash,
            resolver_address: signer::address_of(resolver),
            revealed_secret: vector::empty<u8>(),
        };

        table::add(&mut ledger.orders, order_id, order);
    }

    
    /// Phase 2: Claim - Resolver provides secret to claim funds from maker's escrow
    public entry fun claim_funds<SrcCoinType>(
        resolver: &signer,
        order_id: u64,
        secret: vector<u8>
    ) acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that order hasn't expired
        assert!(timestamp::now_seconds() < order.expiration_timestamp_secs, EORDER_EXPIRED);

        // Check that secret hasn't been revealed yet (order not already completed)
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify secret hash using Keccak256
        let computed_hash = aptos_hash::keccak256(secret);
        assert!(computed_hash == order.secret_hash, EINVALID_SECRET);

        // Verify coin type matches
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Store the revealed secret
        order.revealed_secret = secret;

        // Transfer funds from escrow to resolver
        let escrow_signer = account::create_signer_with_capability(&ledger.signer_cap);
        let escrow_balance = coin::balance<SrcCoinType>(order.escrow_address);
        
        // Make sure escrow has sufficient funds
        assert!(escrow_balance >= order.amount, EINSUFFICIENT_AMOUNT);

        // Withdraw from escrow and deposit to resolver
        let coins = coin::withdraw<SrcCoinType>(&escrow_signer, order.amount);
        coin::deposit(signer::address_of(resolver), coins);

    }

    /// Cancel swap - returns funds to maker if order has expired
    public entry fun cancel_swap<SrcCoinType>(
        maker: &signer,
        order_id: u64
    ) acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Only the original maker can cancel
        assert!(signer::address_of(maker) == order.maker_address, EINVALID_MAKER);

        // Order must be expired to cancel
        assert!(timestamp::now_seconds() >= order.expiration_timestamp_secs, EORDER_NOT_EXPIRED);

        // Order must not have been completed already
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify coin type matches
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Mark as cancelled by setting a dummy revealed secret (non-empty)
        order.revealed_secret = vector::singleton(0u8);

        // Return funds from escrow to maker
        let escrow_signer = account::create_signer_with_capability(&ledger.signer_cap);
        let escrow_balance = coin::balance<SrcCoinType>(order.escrow_address);
        
        if (escrow_balance >= order.amount) {
            let coins = coin::withdraw<SrcCoinType>(&escrow_signer, order.amount);
            coin::deposit(order.maker_address, coins);
        };

        // Return safety deposit to maker
        // let apt_balance = coin::balance<AptosCoin>(order.escrow_address);
        // if (apt_balance >= SAFETY_DEPOSIT_AMOUNT) {
        //     let safety_coins = coin::withdraw<AptosCoin>(&escrow_signer, SAFETY_DEPOSIT_AMOUNT);
        //     coin::deposit(order.maker_address, safety_coins);
        // };
    }

    /// Ensures an escrow account exists and has the necessary coin types registered.
    /// This function:
    /// 1. Creates a resource account at the expected escrow address if it doesn't exist
    /// 2. Registers the specified CoinType in the escrow account if not already registered
    /// 3. Registers AptosCoin in the escrow account if not already registered (needed for safety deposits)
    fun ensure_escrow_and_register<CoinType>(
    signer_cap: &SignerCapability,
    escrow_addr: address,
    seed: vector<u8>
    ) {
        // If the resource account doesn't exist yet, create it.
        if (!account::exists_at(escrow_addr)) {
            let escrow_signer = account::create_signer_with_capability(signer_cap);
            account::create_resource_account(&escrow_signer, seed);
        };

        // Make sure CoinType and AptosCoin are registered in there.
        if (!coin::is_account_registered<CoinType>(escrow_addr)) {
            let esc = account::create_signer_with_capability(signer_cap);
            coin::register<CoinType>(&esc);
        };
        // if (!coin::is_account_registered<AptosCoin>(escrow_addr)) {
        //     let esc = account::create_signer_with_capability(signer_cap);
        //     coin::register<AptosCoin>(&esc);
        // };
    }


    /// Helper function to check if order is completed
    #[view]
    public fun is_order_completed(order_id: u64): bool acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global<SwapLedger>(module_addr);
        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow(&ledger.orders, order_id);
        !vector::is_empty(&order.revealed_secret)
    }

    /// Helper function to get revealed secret (if any)
    #[view]
    public fun get_revealed_secret(order_id: u64): vector<u8> acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global<SwapLedger>(module_addr);
        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow(&ledger.orders, order_id);
        order.revealed_secret
    }

    /// View function to get order details
    #[view]
    public fun get_order_details(order_id: u64): OrderMetadata acquires SwapLedger {
        let module_addr = @swap_addr;
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global<SwapLedger>(module_addr);
        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        *table::borrow(&ledger.orders, order_id)
    }

    // Public accessor functions for OrderMetadata fields
    public fun order_id(order: &OrderMetadata): u64 {
        order.id
    }

    public fun order_maker_address(order: &OrderMetadata): address {
        order.maker_address
    }

    public fun order_amount(order: &OrderMetadata): u64 {
        order.amount
    }

    public fun order_escrow_address(order: &OrderMetadata): address {
        order.escrow_address
    }

    public fun order_min_amount(order: &OrderMetadata): u64 {
        order.min_amount
    }

    public fun order_secret_hash(order: &OrderMetadata): &vector<u8> {
        &order.secret_hash
    }

    public fun order_resolver_address(order: &OrderMetadata): address {
        order.resolver_address
    }
}
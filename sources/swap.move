
module sui_1inch::swap {
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::hash;

    /// A struct to hold the details of a swap order.
    struct Order<T> has key, store {
        id: UID,
        /// The address of the user who created the order.
        maker: address,
        /// The address of the user who is taking the order.
        taker: address,
        /// The amount of tokens the maker is swapping.
        making_amount: u64,
        /// The amount of tokens the taker is swapping.
        taking_amount: u64,
        /// The escrow account for the maker's funds.
        escrow: Coin<T>,
        /// The hash of the secret that unlocks the swap.
        secret_hash: vector<u8>,
    }

    /// Create a new swap order.
    public fun create_order<T>(
        maker: address,
        taker: address,
        making_amount: u64,
        taking_amount: u64,
        escrow: Coin<T>,
        secret_hash: vector<u8>,
        ctx: &mut TxContext
    ): Order<T> {
        Order {
            id: object::new(ctx),
            maker,
            taker,
            making_amount,
            taking_amount,
            escrow,
            secret_hash,
        }
    }

    /// Fund the escrow with the maker's tokens.
    public fun fund_escrow<T>(
        order: &mut Order<T>,
        funds: Coin<T>
    ) {
        coin::join(&mut order.escrow, funds);
    }

    /// Release the funds to the taker.
    public fun release_funds<T>(
        order: Order<T>,
        secret: vector<u8>,
        ctx: &mut TxContext
    ) {
        // Verify the secret.
        let hash = hash::keccak256(&secret);
        assert!(hash == order.secret_hash, 1);

        // Transfer the funds to the taker.
        transfer::public_transfer(order.escrow, order.taker);

        // Delete the order object.
        let Order { id, maker, taker, making_amount, taking_amount, escrow, secret_hash } = order;
        object::delete(id);
    }

    /// Cancel the swap and return the funds to the maker.
    public fun cancel_swap<T>(
        order: Order<T>,
        ctx: &mut TxContext
    ) {
        // Transfer the funds back to the maker.
        transfer::public_transfer(order.escrow, order.maker);

        // Delete the order object.
        let Order { id, maker, taker, making_amount, taking_amount, escrow, secret_hash } = order;
        object::delete(id);
    }
}

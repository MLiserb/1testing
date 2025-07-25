
module sui_1inch::my_token {
    use std::option;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// The token - created by the module initializer and held in a singleton object.
    struct MY_TOKEN has drop {}

    /// Capabilities that are sent to the module initializer.
    struct TokenAdmin has key, store {
        treasury: TreasuryCap<MY_TOKEN>
    }

    fun init(witness: MY_TOKEN, ctx: &mut TxContext) {
        // Get a treasury cap for the coin and give it to the transaction sender.
        let (treasury, metadata) = coin::create_currency<MY_TOKEN>(
            witness,
            6, // decimals
            b"MTK",
            b"My Token",
            b"A sample token for the sui-1inch bridge.",
            option::none(),
            ctx
        );

        // Transfer the treasury cap to the sender of the transaction.
        transfer::public_transfer(
            TokenAdmin { treasury },
            tx_context::sender(ctx)
        );

        // Freeze the metadata object so it can't be changed.
        transfer::public_freeze_object(metadata);
    }

    /// Public getter for the total supply of the coin.
    public fun total_supply(cap: &TokenAdmin): u64 {
        coin::total_supply(&cap.treasury)
    }

    /// Mint new coins.
    public fun mint(
        cap: &mut TokenAdmin, amount: u64, recipient: address, ctx: &mut TxContext
    ) {
        coin::mint_and_transfer(&mut cap.treasury, amount, recipient, ctx)
    }

    /// Burn coins.
    public fun burn(cap: &mut TokenAdmin, coin: Coin<MY_TOKEN>) {
        coin::burn(&mut cap.treasury, coin)
    }
}

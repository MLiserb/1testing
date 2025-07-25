
#[test_only]
module sui_1inch::swap_test {
    use sui::test_scenario::{Self, next_tx, sender};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui_1inch::swap::{Self, Order};
    use sui_1inch::my_token::{Self, MY_TOKEN};

    const MAKER: address = @0x123;
    const TAKER: address = @0x456;

    #[test]
    fun test_swap_scenario() {
        let mut scenario = test_scenario::begin(MAKER);

        // Initialize the token
        next_tx(&mut scenario, MAKER);
        sui_1inch::my_token::init(MY_TOKEN {}, test_scenario::ctx(&mut scenario));

        // Mint some tokens to the maker
        next_tx(&mut scenario, MAKER);
        let admin_cap = scenario.take_from_sender<sui_1inch::my_token::TokenAdmin>();
        sui_1inch::my_token::mint(&mut admin_cap, 1000, MAKER, test_scenario::ctx(&mut scenario));
        scenario.return_to_sender(admin_cap);

        // Create a swap order
        next_tx(&mut scenario, MAKER);
        let maker_coin = scenario.take_from_sender<Coin<MY_TOKEN>>();
        let secret = b"my_secret";
        let secret_hash = sui::hash::keccak256(&secret);
        let order = swap::create_order(
            MAKER,
            TAKER,
            1000,
            500,
            maker_coin,
            secret_hash,
            test_scenario::ctx(&mut scenario)
        );
        transfer::public_transfer(order, MAKER);

        // Fund the escrow
        next_tx(&mut scenario, MAKER);
        let order = scenario.take_from_sender<Order<MY_TOKEN>>();
        let funds = scenario.take_from_sender<Coin<MY_TOKEN>>();
        swap::fund_escrow(&mut order, funds);
        scenario.return_to_sender(order);

        // Release the funds
        next_tx(&mut scenario, TAKER);
        let order = scenario.take_from_sender<Order<MY_TOKEN>>();
        swap::release_funds(order, secret, test_scenario::ctx(&mut scenario));

        // Check that the taker received the funds
        next_tx(&mut scenario, TAKER);
        let taker_coin = scenario.take_from_sender<Coin<MY_TOKEN>>();
        assert!(coin::value(&taker_coin) == 1000, 0);
        scenario.return_to_sender(taker_coin);

        test_scenario::end(scenario);
    }
}

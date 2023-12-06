// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module games::betting_game_tests {
    use sui::hanger::Hanger;
    use sui::coin::{Self, Coin};
    use sui::random::{Self, update_randomness_state_for_testing, Random};
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};
    use sui::transfer;

    use games::betting_game;

    fun mint(addr: address, amount: u64, scenario: &mut Scenario) {
        transfer::public_transfer(coin::mint_for_testing<SUI>(amount, test_scenario::ctx(scenario)), addr);
        test_scenario::next_tx(scenario, addr);
    }

    #[test]
    fun test_betting_game() {
        let user1 = @0x0;
        let user2 = @0x1;
        let scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        // Setup randomness
        random::create_for_testing(test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, user1);
        let random_state = test_scenario::take_shared<Random>(scenario);
        update_randomness_state_for_testing(
            &mut random_state,
            1,
            x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
            test_scenario::ctx(scenario)
        );

        // Create the game and get back the output objects.
        mint(user1, 100, scenario);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        betting_game::create(coin, 50, 99, test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, user1);
        let game = test_scenario::take_shared<Hanger<betting_game::Game>>(scenario);
        assert!(betting_game::get_balance(&game) == 100, 1);
        assert!(betting_game::get_epoch(&game) == 0, 1);

        // Play 4 turns (everything here is deterministic)
        test_scenario::next_tx(scenario, user2);
        mint(user2, 200, scenario);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        betting_game::play(&mut game, &random_state, coin, test_scenario::ctx(scenario));
        assert!(betting_game::get_balance(&game) == 200, 1); // lost 200

        test_scenario::next_tx(scenario, user2);
        mint(user2, 200, scenario);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        betting_game::play(&mut game, &random_state, coin, test_scenario::ctx(scenario));
        assert!(betting_game::get_balance(&game) == 2, 1); // won 200*99/100
        // check that received the right amount
        test_scenario::next_tx(scenario, user2);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        assert!(coin::value(&coin) == (198 + 200), 1);
        test_scenario::return_to_sender(scenario, coin);

        test_scenario::next_tx(scenario, user2);
        mint(user2, 100, scenario);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        betting_game::play(&mut game, &random_state, coin, test_scenario::ctx(scenario));
        assert!(betting_game::get_balance(&game) == 4, 1); // lost again (but the bet was only 2)

        test_scenario::next_tx(scenario, user2);
        mint(user2, 200, scenario);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        betting_game::play(&mut game, &random_state, coin, test_scenario::ctx(scenario));
        assert!(betting_game::get_balance(&game) == 1, 1); // won 4*99/100
        // check that received the right amount
        test_scenario::next_tx(scenario, user2);
        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
        assert!(coin::value(&coin) == (3 + 200), 1);
        test_scenario::return_to_sender(scenario, coin);

        // TODO: test also that the last coin is taken

        // Take remaining balance
        test_scenario::next_epoch(scenario, user1);
        let coin = betting_game::close(&mut game, test_scenario::ctx(scenario));
        assert!(coin::value(&coin) == 1, 1);
        coin::burn_for_testing(coin);

        test_scenario::return_shared(game);
        test_scenario::return_shared(random_state);
        test_scenario::end(scenario_val);
    }
}

// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A betting game that depends on Sui randomness.
///
/// Anyone can create a new game for the current epoch by depositing SUIs as the initial balance, and specifying the
/// winning probability and reward percentage. The creator can withdraw the remaining balance after the epoch is over.
///
/// Anyone can play the game by betting on X SUIs. They win X * 'reward percentage' with probability 'winning
/// probability' and otherwise loss the X SUIs.
///
module games::betting_game {
    use sui::hanger::{Self, Hanger};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::math;
    use sui::object::{Self, UID};
    use sui::random::{Self, Random, new_generator};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// Error codes
    const EInvalidAmount: u64 = 0;
    const EInvalidWinProb: u64 = 1;
    const EInvalidRewardPrec: u64 = 2;
    const EInvalidSender: u64 = 3;
    const EInvalidEpoch: u64 = 3;

    /// Game for a specific epoch.
    struct Game has key, store {
        id: UID,
        creator: address,
        epoch: u64,
        balance: Balance<SUI>, // Must not be exposed externally.
        winning_probability: u8,
        reward_percentage: u8,
    }

    /// Create a new game with a given initial reward and parameters for the current epoch.
    public fun create(
        reward: Coin<SUI>,
        winning_probability: u8,
        reward_percentage: u8,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&reward);
        assert!(amount > 0, EInvalidAmount);
        assert!(winning_probability > 0 && winning_probability < 100, EInvalidWinProb);
        assert!(reward_percentage > 0 && reward_percentage < 100, EInvalidRewardPrec);
        transfer::public_share_object(hanger::create(Game {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            epoch: tx_context::epoch(ctx),
            balance: coin::into_balance(reward),
            winning_probability,
            reward_percentage,
        }, ctx));
    }

    /// Creator can withdraw remaining balance if the game is over.
    public fun close(game: &mut Hanger<Game>, ctx: &mut TxContext): Coin<SUI> {
        let game = hanger::load_data_mut(game);
        assert!(tx_context::epoch(ctx) > game.epoch, EInvalidEpoch);
        assert!(tx_context::sender(ctx) == game.creator, EInvalidSender);
        let full_balance = balance::value(&game.balance);
        coin::take(&mut game.balance, full_balance, ctx)
    }

    /// Play one turn of the game.
    ///
    /// The function does not return anything to the caller to make sure its output cannot be used in later PTB
    /// commands.
    /// In addition, the function follows the same steps whether the user won or lost to make sure the gas consumption
    /// is different.
    ///
    /// TODO: validate in tests
    public fun play(game: &mut Hanger<Game>, r: &Random, coin: Coin<SUI>, ctx: &mut TxContext) {
        let game = hanger::load_data_mut(game);
        assert!(tx_context::epoch(ctx) == game.epoch, EInvalidEpoch);
        assert!(coin::value(&coin) > 0, EInvalidAmount);

        let bet = math::min(coin::value(&coin), balance::value(&game.balance));
        // Make sure every bet counts.
        let reward = (bet * (game.reward_percentage as u64)) / 100;
        reward = if (reward == 0) { bet } else { reward };
        // If lost, return the rest to the user.
        let amount_lost = coin::value(&coin) - bet;
        // If won, return entire input balance and the reward to the user.
        let amount_won = amount_lost + bet + reward;
        coin::put(&mut game.balance, coin);

        let generator = new_generator(r, ctx);
        let bet = random::generate_u8_in_range(&mut generator, 1, 100);
        let won = bet <= game.winning_probability;

        let amount = if (won) { amount_won } else { amount_lost };
        let to_user_coin = coin::take(&mut game.balance, amount, ctx);
        transfer::public_transfer(to_user_coin, tx_context::sender(ctx));
    }

    #[test_only]
    public fun get_balance(game: &Hanger<Game>): u64 {
        let game = hanger::load_data(game);
        balance::value(&game.balance)
    }

    #[test_only]
    public fun get_epoch(game: &Hanger<Game>): u64 {
        let game = hanger::load_data(game);
        game.epoch
    }

}

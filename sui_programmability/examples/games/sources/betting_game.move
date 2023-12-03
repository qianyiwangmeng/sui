// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A betting game that depends on Sui randomness.
///
/// Anyone can create a new game for the current epoch by depositing SUIs as the initial balance, and specifying the
/// winning probability and reward percentage. The creator can withdraw the remaining balance after the epoch is over.
///
/// Anyone can play the game by betting on X SUIs. They win X * 'reward percentage' with probability 'winning
/// probability' and otherwise loss X SUIs.
///
module games::betting_game {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
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
    struct Game has key {
        id: UID,
        creator: address,
        epoch: u64,
        balance: Balance<SUI>,
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
        transfer::share_object(Game {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            epoch: tx_context::epoch(ctx),
            balance: coin::into_balance(reward),
            winning_probability,
            reward_percentage,
        });
    }

    /// Creator can withdraw remaining balance if the game is over.
    public fun close(game: &mut Game, ctx: &mut TxContext): Coin<SUI> {
        assert!(tx_context::epoch(ctx) > game.epoch, EInvalidEpoch);
        assert!(tx_context::sender(ctx) == game.creator, EInvalidSender);
        let full_balance = balance::value(&game.balance);
        coin::take(&mut game.balance, full_balance, ctx)
    }

    /// Play one turn of the game.
    ///
    /// The function does not return anything to the caller to make sure its output cannot be used in later PTB
    /// commands.
    entry fun play(game: &mut Game, r: &Random, coin: Coin<SUI>, ctx: &mut TxContext) {
        assert!(tx_context::epoch(ctx) == game.epoch, EInvalidEpoch);
        assert!(coin::value(&coin) > 0 && balance::value(&game.balance) >= coin::value(&coin), EInvalidAmount);

        let generator = new_generator(r, ctx);
        let bet = random::generate_u8_in_range(&mut generator, 1, 100);
        let won = bet <= game.winning_probability;
        if (won) {
            let amount = (coin::value(&coin) * (game.reward_percentage as u64)) / 100;
            let all_coins = coin::take(&mut game.balance, amount, ctx);
            coin::join(&mut all_coins, coin);
            transfer::public_transfer(all_coins, tx_context::sender(ctx));
        } else {
            coin::put(&mut game.balance, coin);
        };
    }

    #[test_only]
    public fun get_balance(game: &Game): u64 {
        balance::value(&game.balance)
    }

    #[test_only]
    public fun get_epoch(game: &Game): u64 {
        game.epoch
    }
}

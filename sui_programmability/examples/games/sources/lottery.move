// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A basic lottery game that depends on Sui randomness.
///
/// Anyone can create a new lottery game with an end time and a cost per ticket. After the end time, anyone can trigger
/// a function to determine the winner, and the owner of the winning ticket can redeem the entire balance of the game.
///
module games::lottery {
    use std::option::{Self, Option};
    use sui::balance;
    use sui::balance::Balance;
    use sui::clock;
    use sui::clock::Clock;
    use sui::coin;
    use sui::coin::Coin;
    use sui::object::{Self, ID, UID};
    use sui::random;
    use sui::random::{Random, new_generator};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context;
    use sui::tx_context::TxContext;

    /// Error codes
    const EGameInProgress: u64 = 0;
    const EGameAlreadyCompleted: u64 = 1;
    const ENoParticipants: u64 = 2;
    const EInvalidAmount: u64 = 3;
    const EGameMistmatch: u64 = 4;
    const ENotWinner: u64 = 4;
    const EWrongGameWinner: u64 = 5;

    /// Game represents a set of parameters of a single game.
    struct Game has key {
        id: UID,
        cost_in_sui: u64,
        participants: u32,
        end_time: u64,
        winner_obj: Option<ID>,
        balance: Balance<SUI>,
    }

    struct GameWinner has key {
        id: UID,
        winner: u32,
    }

    /// Ticket represents a participant in a single game.
    struct Ticket has key {
        id: UID,
        game_id: ID,
        participant_index: u32,
    }

    struct DetermineWinnerCapability has key {
        id: UID,
        game_id: ID,
    }

    /// Create a shared-object Game.
    public fun create(end_time: u64, cost_in_sui: u64, ctx: &mut TxContext) {
        let game = Game {
            id: object::new(ctx),
            cost_in_sui,
            participants: 0,
            end_time,
            winner_obj: option::none(),
            balance: balance::zero(),
        };
        transfer::share_object(game);
    }

    /// Anyone can determine a winner.
    ///
    /// Since clock is somewhat controlled by validators, we use a 2-step process to guarantee that once
    /// 'determine_winner' is called, the game is indeed over. (If instead we used Clock in 'determine_winner', a
    /// malicious validator could send a transaction before 'end_time', wait for its randomness, and then decide if
    /// to set Clock so that the transaction would fail or not depending on the winner.)
    /// Here, a user must first retrieve a capability to prove that the game is over. This capability is returned
    /// as a new, transferred object, thus cannot be used atomically with 'determine_winner'. This guarantees
    /// that transactions that call 'determine_winner' are committed after the game is over.
    entry fun get_determine_winner_capability(game: &Game, clock: &Clock, ctx: &mut TxContext) {
        assert!(game.end_time <= clock::timestamp_ms(clock), EGameInProgress);
        assert!(game.participants > 0, ENoParticipants);
        transfer::transfer(
            DetermineWinnerCapability {
                id: object::new(ctx),
                game_id: object::id(game),
            },
            tx_context::sender(ctx));
    }

    /// The winner is determined randomly and stored in an newly created, id-linked shared object GameWinner.
    /// Since GameWinner is a new object, we do not worry about other commands using it in the same PTB.
    entry fun determine_winner(cap: DetermineWinnerCapability, game: &mut Game, r: &Random, ctx: &mut TxContext) {
        assert!(option::is_none(&game.winner_obj), EGameAlreadyCompleted);
        assert!(object::id(game) == cap.game_id, EGameMistmatch);
        destroy_detemine_winner_capability(cap);
        let generator = new_generator(r, ctx);
        let winner = random::generate_u32_in_range(&mut generator, 1, game.participants);
        let game_winner = GameWinner {
            id: object::new(ctx),
            winner,
        };
        game.winner_obj = option::some(object::id(&game_winner));
        transfer::share_object(game_winner);
    }

    /// Anyone can play and receive a ticket.
    public fun play(game: &mut Game, coin: Coin<SUI>, clock: &Clock, ctx: &mut TxContext): Ticket {
        assert!(game.end_time > clock::timestamp_ms(clock), EGameAlreadyCompleted);
        assert!(coin::value(&coin) == game.cost_in_sui, EInvalidAmount);

        game.participants = game.participants + 1;
        coin::put(&mut game.balance, coin);

        Ticket {
            id: object::new(ctx),
            game_id: object::id(game),
            participant_index: game.participants,
        }
    }

    /// The winner can take the prize.
    public fun redeem(ticket: Ticket, game: &mut Game, winner: &GameWinner, ctx: &mut TxContext): Coin<SUI> {
        assert!(object::id(game) == ticket.game_id, EGameMistmatch);
        assert!(option::contains(&game.winner_obj, &object::id(winner)), EWrongGameWinner);
        assert!(winner.winner == ticket.participant_index, ENotWinner);
        destroy_ticket(ticket);

        let full_balance = balance::value(&game.balance);
        coin::take(&mut game.balance, full_balance, ctx)
    }

    public fun destroy_ticket(ticket: Ticket) {
        let Ticket { id, game_id:  _, participant_index: _} = ticket;
        object::delete(id);
    }

    public fun destroy_detemine_winner_capability(cap: DetermineWinnerCapability) {
        let DetermineWinnerCapability { id, game_id: _ } = cap;
        object::delete(id);
    }

    #[test_only]
    public fun get_cost_in_sui(game: &Game): u64 {
        game.cost_in_sui
    }

    #[test_only]
    public fun get_end_time(game: &Game): u64 {
        game.end_time
    }

    #[test_only]
    public fun get_participants(game: &Game): u32 {
        game.participants
    }

    #[test_only]
    public fun get_winner_obj(game: &Game): Option<ID> {
        game.winner_obj
    }

    #[test_only]
    public fun get_balance(game: &Game): u64 {
        balance::value(&game.balance)
    }

    #[test_only]
    public fun get_winner(gw: &GameWinner): u32 {
        gw.winner
    }
}

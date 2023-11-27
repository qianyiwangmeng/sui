// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module sui::bridge_treasury {
    use std::type_name;

    use sui::coin::{Self, TreasuryCap, Coin};
    use sui::dynamic_field as df;
    use sui::object::UID;
    use sui::token_ids;
    use sui::tx_context::TxContext;

    friend sui::bridge;

    struct BridgeTreasury has store {
        id: UID
    }

    // bridged tokens
    struct USDC has drop {}

    struct BTC has drop {}

    struct ETH has drop {}

    public(friend) fun burn<T>(self: &mut BridgeTreasury, token: Coin<T>) {
        let treasury = get_treasury<T>(self);
        coin::burn(treasury, token);
    }

    public(friend) fun mint<T>(self: &mut BridgeTreasury, amount: u64, ctx: &mut TxContext): Coin<T> {
        let treasury = get_treasury<T>(self);
        coin::mint(treasury, amount, ctx)
    }

    fun get_treasury<T>(self: &mut BridgeTreasury): &mut TreasuryCap<T> {
        let type = type_name::get<T>();
        if (type == type_name::get<BTC>()) {
            df::borrow_mut<u8, TreasuryCap<T>>(&mut self.id, token_ids::btc())
        }else if (type == type_name::get<ETH>()) {
            df::borrow_mut<u8, TreasuryCap<T>>(&mut self.id, token_ids::eth())
        }else if (type == type_name::get<USDC>()) {
            df::borrow_mut<u8, TreasuryCap<T>>(&mut self.id, token_ids::usdc())
        }else {
            // Fatal error : Unsupported token type
            abort 1
        }
    }

    public fun is_bridged_token<T>(): bool {
        (type_name::get<T>() == type_name::get<BTC>()) ||
            (type_name::get<T>() == type_name::get<ETH>()) ||
            (type_name::get<T>() == type_name::get<USDC>())
    }
}
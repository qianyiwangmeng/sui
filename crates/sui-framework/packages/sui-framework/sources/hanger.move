// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Hanger is an object that stores internally a given type T. While Hanger is serializable via bcs::to_bytes, its
/// internal type is not directly serializable (as long as the caller does not expose the internal type).
module sui::hanger {

    use sui::dynamic_field;
    use sui::object;
    use sui::tx_context::TxContext;

    struct Hanger<phantom T: store> has key, store {
        id: object::UID,
    }

    /// Create a new Hanger object that contains a initial value of type `T`.
    public fun create<T: store>(data: T, ctx: &mut TxContext): Hanger<T> {
        let self = Hanger<T> {
            id: object::new(ctx),
        };
        dynamic_field::add(&mut self.id, 0, data);
        self
    }

    /// Load the inner value. Caller specifies an expected type T. If the type mismatch, the load will fail.
    public fun load_data<T: store>(self: &Hanger<T>): &T {
        dynamic_field::borrow(&self.id, 0)
    }

    /// Similar to load_value, but return a mutable reference.
    public fun load_data_mut<T: store>(self: &mut Hanger<T>): &mut T {
        dynamic_field::borrow_mut(&mut self.id, 0)
    }

    /// Destroy this container, and return the inner object.
    public fun destroy<T: store>(self: Hanger<T>): T {
        let Hanger { id } = self;
        let ret = dynamic_field::remove(&mut id, 0);
        object::delete(id);
        ret
    }

}

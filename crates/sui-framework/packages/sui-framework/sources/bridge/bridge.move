// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[allow(unused_const)]
module sui::bridge {
    use std::vector;

    use sui::address;
    use sui::balance;
    use sui::bcs;
    use sui::bridge_committee::{Self, BridgeCommittee};
    use sui::bridge_escrow::{Self, BridgeEscrow};
    use sui::bridge_treasury::{Self, BridgeTreasury, token_id};
    use sui::chain_ids;
    use sui::coin::{Self, Coin};
    use sui::event::emit;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    #[test_only]
    use sui::bridge_treasury::USDC;
    #[test_only]
    use sui::hex;
    #[test_only]
    use sui::test_scenario;
    use sui::versioned::Versioned;
    use sui::versioned;
    use sui::linked_table::LinkedTable;
    use sui::linked_table;

    struct Bridge has key {
        id: UID,
        inner: Versioned
    }

    struct BridgeInner has store {
        version: u64,

        // nonce for replay protection
        sequence_num: u64,
        // committee pub keys
        committee: BridgeCommittee,
        // Escrow for storing native tokens
        escrow: BridgeEscrow,
        // Bridge treasury for mint/burn bridged tokens
        treasury: BridgeTreasury,
        pending_messages: LinkedTable<BridgeMessageKey, BridgeMessage>,
        approved_messages: LinkedTable<BridgeMessageKey, ApprovedBridgeMessage>,
        frozen: bool,
        last_emergency_op_seq_num: u64,
    }

    // message types
    const TOKEN: u8 = 0;
    const COMMITTEE_BLOCKLIST: u8 = 1;
    const EMERGENCY_OP: u8 = 2;

    //const COMMITTEE_CHANGE: u8 = 2;
    //const NFT: u8 = 4;

    // Emergency Op types
    const FREEZE: u8 = 0;
    const UNFREEZE: u8 = 1;

    struct BridgeMessage has copy, store, drop {
        // 0: token , 1: object ? TBD
        message_type: u8,
        message_version: u8,
        seq_num: u64,
        source_chain: u8,
        payload: vector<u8>
    }

    struct ApprovedBridgeMessage has store {
        message: BridgeMessage,
        approved_epoch: u64,
        signatures: vector<vector<u8>>,
    }

    struct BridgeMessageKey has copy, drop, store {
        source_chain: u8,
        bridge_seq_num: u64
    }

    struct BridgeEvent has copy, drop {
        message: BridgeMessage,
        message_bytes: vector<u8>
    }

    struct TokenBridgePayload {
        sender_address: vector<u8>,
        target_chain: u8,
        target_address: vector<u8>,
        token_type: u8,
        amount: u64
    }

    struct EmergencyOpPayload {
        op_type: u8
    }

    const EUnexpectedMessageType: u64 = 0;
    const EUnauthorisedClaim: u64 = 1;
    const EMalformedMessageError: u64 = 2;
    const EUnexpectedTokenType: u64 = 3;
    const EUnexpectedChainID: u64 = 4;
    const ENotSystemAddress: u64 = 5;
    const EUnexpectedSeqNum: u64 = 6;
    const EWrongInnerVersion: u64 = 7;

    const CURRENT_VERSION: u64 = 1;

    #[allow(unused_function)]
    fun create(ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @0x0, ENotSystemAddress);
        let bridge_inner = BridgeInner {
            version: CURRENT_VERSION,
            sequence_num: 0,
            committee: bridge_committee::create_genesis_static_committee(),
            escrow: bridge_escrow::create(ctx),
            treasury: bridge_treasury::create(ctx),
            pending_messages: linked_table::new<BridgeMessageKey, BridgeMessage>(ctx),
            approved_messages: linked_table::new<BridgeMessageKey, ApprovedBridgeMessage>(ctx),
            frozen: false,
            last_emergency_op_seq_num: 0
        };
        let bridge = Bridge{
            id: object::bridge(),
            inner : versioned::create(CURRENT_VERSION, bridge_inner, ctx)
        };
        transfer::share_object(bridge)
    }

    fun load_inner_mut(
        self: &mut Bridge,
    ): &mut BridgeInner {
        let version = versioned::version(&self.inner);

        // Replace this with a lazy update function when we add a new version of the inner object.
        assert!(version == CURRENT_VERSION, EWrongInnerVersion);
        let inner: &mut BridgeInner = versioned::load_value_mut(&mut self.inner);
        assert!(inner.version == version, EWrongInnerVersion);
        inner
    }

    #[allow(unused_function)] // TODO: remove annotation after implementing user-facing API
    fun load_inner(
        self: &Bridge,
    ): &BridgeInner {
        let version = versioned::version(&self.inner);

        // Replace this with a lazy update function when we add a new version of the inner object.
        assert!(version == CURRENT_VERSION, EWrongInnerVersion);
        let inner: &BridgeInner = versioned::load_value(&self.inner);
        assert!(inner.version == version, EWrongInnerVersion);
        inner
    }

    fun serialise_token_bridge_payload<T>(
        sender: address,
        target_chain: u8,
        target_address: vector<u8>,
        token: &Coin<T>
    ): vector<u8> {
        let payload = vector[];
        vector::append(&mut payload, bcs::to_bytes(&address::to_bytes(sender)));
        vector::push_back(&mut payload, target_chain);
        vector::append(&mut payload, bcs::to_bytes(&target_address));
        vector::append(&mut payload, bcs::to_bytes(&token_id<T>()));
        vector::append(&mut payload, bcs::to_bytes(&balance::value(coin::balance(token))));
        payload
    }

    fun deserialise_token_bridge_payload(message: vector<u8>): TokenBridgePayload {
        let bcs = bcs::new(message);
        let sender_address = bcs::peel_vec_u8(&mut bcs);
        let target_chain = bcs::peel_u8(&mut bcs);
        let target_address = bcs::peel_vec_u8(&mut bcs);
        let token_type = bcs::peel_u8(&mut bcs);
        let amount = bcs::peel_u64(&mut bcs);
        TokenBridgePayload {
            sender_address,
            target_chain,
            target_address,
            token_type,
            amount
        }
    }

    fun deserialise_emergency_op_payload(message: vector<u8>): EmergencyOpPayload {
        let bcs = bcs::new(message);
        EmergencyOpPayload {
            op_type: bcs::peel_u8(&mut bcs)
        }
    }

    fun deserialise_message(message: vector<u8>): BridgeMessage {
        let bcs = bcs::new(message);
        BridgeMessage {
            message_type: bcs::peel_u8(&mut bcs),
            message_version: bcs::peel_u8(&mut bcs),
            seq_num: bcs::peel_u64(&mut bcs),
            source_chain: bcs::peel_u8(&mut bcs),
            payload: bcs::into_remainder_bytes(bcs)
        }
    }

    fun serialise_message(message: BridgeMessage): vector<u8> {
        let BridgeMessage {
            message_type,
            message_version: version,
            seq_num: bridge_seq_num,
            source_chain,
            payload
        } = message;

        let message = vector[];
        vector::push_back(&mut message, message_type);
        vector::push_back(&mut message, version);
        vector::append(&mut message, bcs::to_bytes(&bridge_seq_num));
        vector::push_back(&mut message, source_chain);
        vector::append(&mut message, payload);
        message
    }

    // Create bridge request to send token to other chain, the request will be in pending state until approved
    public fun send_token<T>(
        self: &mut Bridge,
        target_chain: u8,
        target_address: vector<u8>,
        token: Coin<T>,
        ctx: &mut TxContext
    ) {
        let inner = load_inner_mut(self);
        let bridge_seq_num = inner.sequence_num;
        inner.sequence_num = inner.sequence_num + 1;
        // create bridge message
        let payload = serialise_token_bridge_payload(tx_context::sender(ctx),target_chain, target_address, &token);
        let message = BridgeMessage {
            message_type: TOKEN,
            message_version: 1,
            source_chain: chain_ids::sui(),
            seq_num: bridge_seq_num,
            payload
        };
        // burn / escrow token
        if (bridge_treasury::is_bridged_token<T>()) {
            bridge_treasury::burn(&mut inner.treasury, token);
        }else {
            bridge_escrow::escrow_token(&mut inner.escrow, token);
        };
        // Store pending bridge request
        let key = BridgeMessageKey { source_chain: chain_ids::sui(), bridge_seq_num };
        linked_table::push_back(&mut inner.pending_messages, key, message);

        // emit event
        // TODO: Approvals for bridge to other chains will not be consummed because claim happens on other chain, we need to archieve old approvals on Sui.
        emit(BridgeEvent { message, message_bytes: serialise_message(message) })
    }

    // Record bridge message approvels in Sui, call by the bridge client
    public fun approve_bridge_message(
        self: &mut Bridge,
        raw_message: vector<u8>,
        signatures: vector<vector<u8>>,
        ctx: &TxContext
    ) {
        let inner = load_inner_mut(self);
        // varify signatures
        bridge_committee::verify_signatures(&inner.committee, raw_message, signatures);
        let message = deserialise_message(raw_message);
        // retrieve pending message if source chain is Sui
        if (message.source_chain == chain_ids::sui()) {
            let key = BridgeMessageKey { source_chain: chain_ids::sui(), bridge_seq_num: message.seq_num };
            let recorded_message = linked_table::remove(&mut inner.pending_messages,key);
            let message_bytes = serialise_message(recorded_message);
            assert!(message_bytes == raw_message, EMalformedMessageError);
        };
        assert!(message.source_chain != chain_ids::sui(), EUnexpectedChainID);
        let approved_message = ApprovedBridgeMessage {
            message,
            approved_epoch: tx_context::epoch(ctx),
            signatures,
        };
        let key = BridgeMessageKey { source_chain: message.source_chain, bridge_seq_num: message.seq_num };
        // Store approval
        linked_table::push_back(&mut inner.approved_messages, key, approved_message);
    }

    // Claim token from approved bridge message
    fun claim_token_internal<T>(
        self: &mut Bridge,
        source_chain: u8,
        bridge_seq_num: u64,
        ctx: &mut TxContext
    ): (Coin<T>, address) {
        let inner = load_inner_mut(self);
        let key = BridgeMessageKey { source_chain, bridge_seq_num };
        // retrieve approved bridge message
        let ApprovedBridgeMessage {
            message,
            approved_epoch: _,
            signatures: _,
        } = linked_table::remove(&mut inner.approved_messages, key);

        // extract token message
        let TokenBridgePayload {
            sender_address: _,
            target_chain,
            target_address,
            token_type,
            amount
        } = deserialise_token_bridge_payload(message.payload);

        // ensure target chain is Sui
        assert!(target_chain == chain_ids::sui(), EUnexpectedChainID);
        // get owner address
        let owner = address::from_bytes(target_address);
        // ensure this is a token bridge message
        assert!(message.message_type == TOKEN, EUnexpectedMessageType);
        // check token type
        assert!(bridge_treasury::token_id<T>() == token_type, EUnexpectedTokenType);
        // claim from escrow or treasury
        let token = if (bridge_treasury::is_bridged_token<T>()) {
            bridge_treasury::mint<T>(&mut inner.treasury, amount, ctx)
        }else {
            bridge_escrow::claim_token(&mut inner.escrow, amount, ctx)
        };
        (token, owner)
    }

    // This function can only be called by the token recipient
    public fun claim_token<T>(self: &mut Bridge, source_chain: u8, bridge_seq_num: u64, ctx: &mut TxContext): Coin<T> {
        let (token, owner) = claim_token_internal<T>(self, source_chain, bridge_seq_num, ctx);
        // Only token owner can claim the token
        assert!(tx_context::sender(ctx) == owner, EUnauthorisedClaim);
        token
    }

    // This function can be called by anyone to claim and transfer the token to the recipient
    public fun claim_and_transfer_token<T>(
        self: &mut Bridge,
        source_chain: u8,
        bridge_seq_num: u64,
        ctx: &mut TxContext
    ) {
        let (token, owner) = claim_token_internal<T>(self, source_chain, bridge_seq_num, ctx);
        transfer::public_transfer(token, owner)
    }

    public fun execute_emergency_op(
        self: &mut Bridge,
        emergency_op_message: vector<u8>,
        signatures: vector<vector<u8>>
    ) {
        let inner = load_inner_mut(self);
        bridge_committee::verify_signatures(&inner.committee,emergency_op_message,signatures);
        let message = deserialise_message(emergency_op_message);
        assert!(message.message_type == EMERGENCY_OP, EUnexpectedMessageType);
        // check emergency ops seq number
        assert!(message.seq_num == inner.last_emergency_op_seq_num + 1, EUnexpectedSeqNum);
        let EmergencyOpPayload { op_type } = deserialise_emergency_op_payload(message.payload);

        if (op_type == FREEZE) {
            inner.frozen == true;
        }else if (op_type == UNFREEZE) {
            inner.frozen == false;
        }else {
            abort 0
        };
        inner.last_emergency_op_seq_num = message.seq_num;
    }

    #[test]
    fun test_message_serialisation() {
        let sender_address = address::from_u256(100);
        let scenario = test_scenario::begin(sender_address);
        let ctx = test_scenario::ctx(&mut scenario);

        let coin = coin::mint_for_testing<USDC>(12345, ctx);

        let token_bridge_message = BridgeMessage {
            message_type: TOKEN,
            message_version: 1,
            source_chain: chain_ids::sui(),
            seq_num: 10,
            payload: serialise_token_bridge_payload(
                sender_address,
                chain_ids::eth(),
                address::to_bytes(address::from_u256(200)),
                &coin
            )
        };

        let message = serialise_message(token_bridge_message);
        let expected_msg = hex::decode(
            b"03010a0000000000000000200000000000000000000000000000000000000000000000000000000000000064012000000000000000000000000000000000000000000000000000000000000000c8033930000000000000"
        );

        assert!(message == expected_msg, 0);

        let deserialised = deserialise_message(message);
        assert!(token_bridge_message == deserialised, 0);

        coin::burn_for_testing(coin);
        test_scenario::end(scenario);
    }
}

// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[allow(unused_use)]
module sui::bridge_governance {
    use std::vector;

    use sui::ecdsa_r1;
    use sui::vec_map::{Self, VecMap};

    const ESignatureBelowThreshold: u64 = 0;

    struct BridgeCommittee has store {
        // commitee pub key and weight
        pub_keys: VecMap<vector<u8>, u64>,
        threshold: u64
    }

    public fun verify_signatures(
        committee: &BridgeCommittee,
        message: vector<u8>,
        signatures: vector<vector<u8>>
    ) {
        let (i, signature_counts) = (0, vector::length(&signatures));
        let threshold = 0;
        while (i < signature_counts) {
            let signature = vector::borrow(&signatures, i);
            let pubkey = ecdsa_r1::secp256r1_ecrecover(signature, &message, 1);
            // get committee signature weight and check pubkey is part of the committee
            let weight = vec_map::get(&committee.pub_keys, &pubkey);
            threshold = threshold + *weight;
            i = i + 1;
        };
        assert!(threshold >= committee.threshold, ESignatureBelowThreshold)
    }


}
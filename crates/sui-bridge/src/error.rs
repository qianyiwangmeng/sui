// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::crypto::BridgeAuthorityPublicKey;

#[derive(Debug)]
pub enum BridgeError {
    // The input is not an invalid transaction digest/hash
    InvalidTxHash,
    // The referenced transaction failed
    OriginTxFailed,
    // The referenced transction does not exist
    TxNotFound,
    // The referenced transaction does not contain bridge events
    NoBridgeEventsInTx,
    // Internal Bridge error
    InternalError(String),
    // Transient Ethereum provider error
    TransientProviderError(String),
    // Invalid BridgeCommittee
    InvalidBridgeCommittee(String),
    // Invalid Bridge authority signature
    InvalidBridgeAuthoritySignature((BridgeAuthorityPublicKey, String)),
    // Entity is not in the Bridge committee or is blocklisted
    InvalidBridgeAuthority(BridgeAuthorityPublicKey),
    // Uncategorized error
    Generic(anyhow::Error),
}

pub type BridgeResult<T> = Result<T, BridgeError>;

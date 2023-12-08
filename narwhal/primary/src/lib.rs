// Copyright (c) 2021, Facebook, Inc. and its affiliates
// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
#![warn(
    future_incompatible,
    nonstandard_style,
    rust_2018_idioms,
    rust_2021_compatibility
)]

mod aggregators;
mod broadcaster;
mod certificate_fetcher;
mod certifier;
pub mod consensus;
mod core;
mod fetcher;
mod primary;
mod producer;
mod proposer;
mod state_handler;
mod synchronizer;
mod verifier;

#[cfg(test)]
#[path = "tests/common.rs"]
mod common;
mod metrics;

#[cfg(test)]
#[path = "tests/certificate_tests.rs"]
mod certificate_tests;

mod dag_state;
#[cfg(test)]
#[path = "tests/rpc_tests.rs"]
mod rpc_tests;

pub use crate::{
    metrics::PrimaryChannelMetrics,
    primary::{Primary, CHANNEL_CAPACITY, NUM_SHUTDOWN_RECEIVERS},
};

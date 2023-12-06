// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::authority::AuthorityStore;
use crate::transaction_output_writer::TransactionOutputs;

use dashmap::DashMap;
use moka::sync::Cache as MokaCache;
use parking_lot::Mutex;
use std::collections::BTreeMap;
use std::sync::Arc;
use sui_types::base_types::{EpochId, ObjectID, SequenceNumber};
use sui_types::digests::{TransactionDigest, TransactionEffectsDigest};
use sui_types::effects::TransactionEffects;
use sui_types::error::{SuiError, SuiResult, UserInputError};
use sui_types::message_envelope::Message;
use sui_types::object::Object;
use sui_types::storage::{MarkerValue, ObjectKey, ObjectStore, PackageObject};

pub(crate) trait ExecutionCacheRead: Send + Sync {
    fn get_package_object(&self, id: &ObjectID) -> SuiResult<Option<PackageObject>>;
    fn force_reload_system_packages(&self, system_package_ids: &[ObjectID]);

    fn get_object(&self, id: &ObjectID) -> SuiResult<Option<Object>>;

    fn get_object_by_key(
        &self,
        object_id: &ObjectID,
        version: SequenceNumber,
    ) -> SuiResult<Option<Object>>;

    fn multi_get_object_by_key(&self, object_keys: &[ObjectKey]) -> SuiResult<Vec<Option<Object>>>;

    /// If the shared object was deleted, return deletion info for the current live version
    fn get_last_shared_object_deletion_info(
        &self,
        object_id: &ObjectID,
        epoch_id: EpochId,
    ) -> SuiResult<Option<(SequenceNumber, TransactionDigest)>>;

    /// If the shared object was deleted, return deletion info for the specified version.
    fn get_deleted_shared_object_previous_tx_digest(
        &self,
        object_id: &ObjectID,
        version: &SequenceNumber,
        epoch_id: EpochId,
    ) -> SuiResult<Option<TransactionDigest>>;

    fn have_received_object_at_version(
        &self,
        object_id: &ObjectID,
        version: SequenceNumber,
        epoch_id: EpochId,
    ) -> SuiResult<bool>;
}

pub(crate) trait ExecutionCacheWrite: Send + Sync {
    fn update_state(&self, epoch_id: EpochId, tx_outputs: TransactionOutputs) -> SuiResult;
}

pub(crate) struct InMemoryCache {
    // Objects are not cached using an LRU because we manage cache evictions manually due to sui
    // semantics.
    objects: DashMap<ObjectID, BTreeMap<SequenceNumber, Object>>,

    // packages are cache separately from objects because they are immutable and can be used by any
    // number of transactions
    packages: MokaCache<ObjectID, PackageObject>,

    // Markers for received objects and deleted shared objects. This cache can be invalidated at
    // any time, but if there is an entry, it must contain the most recent marker for the object.
    // Note that MokaCache can only return items by value, so we store the map as an Arc<Mutex>.
    // (There should be no contention on the inner mutex, it is used only for interior mutability.)
    markers: MokaCache<ObjectID, Arc<Mutex<BTreeMap<SequenceNumber, MarkerValue>>>>,

    // Objects that were read at transaction signing time - allows us to access them again at
    // execution time with a single lock / hash lookup
    transaction_objects: MokaCache<TransactionDigest, Vec<Object>>,

    transaction_effects: DashMap<TransactionEffectsDigest, TransactionEffects>,

    executed_effects_digests: DashMap<TransactionDigest, TransactionEffectsDigest>,

    // Transaction outputs that have not yet been written to the DB. Items are removed from this
    // table as they are flushed to the db.
    pending_transaction_writes: DashMap<TransactionDigest, TransactionOutputs>,

    store: Arc<AuthorityStore>,
}

impl InMemoryCache {
    pub fn new(store: Arc<AuthorityStore>) -> Self {
        let packages = MokaCache::builder()
            .max_capacity(10000)
            .initial_capacity(10000)
            .build();
        let markers = MokaCache::builder()
            .max_capacity(10000)
            .initial_capacity(10000)
            .build();
        let transaction_objects = MokaCache::builder()
            .max_capacity(10000)
            .initial_capacity(10000)
            .build();

        Self {
            objects: DashMap::new(),
            packages,
            markers,
            transaction_objects,
            transaction_effects: DashMap::new(),
            executed_effects_digests: DashMap::new(),
            pending_transaction_writes: DashMap::new(),
            store,
        }
    }

    fn insert_object(&self, object_id: &ObjectID, object: &Object) {
        self.objects
            .entry(*object_id)
            .or_default()
            .insert(object.version(), object.clone());
    }
}

fn get_last<K, V>(map: &BTreeMap<K, V>) -> (&K, &V) {
    map.iter().next_back().expect("map cannot be empty")
}

impl ExecutionCacheRead for InMemoryCache {
    fn get_package_object(&self, package_id: &ObjectID) -> SuiResult<Option<PackageObject>> {
        if let Some(p) = self.packages.get(package_id) {
            #[cfg(debug_assertions)]
            {
                assert_eq!(
                    self.store.get_object(package_id).unwrap().unwrap().digest(),
                    p.object().digest(),
                    "Package object cache is inconsistent for package {:?}",
                    package_id
                )
            }
            return Ok(Some(p));
        }

        if let Some(p) = self.store.get_object(package_id)? {
            if p.is_package() {
                let p = PackageObject::new(p);
                self.packages.insert(*package_id, p.clone());
                Ok(Some(p))
            } else {
                Err(SuiError::UserInputError {
                    error: UserInputError::MoveObjectAsPackage {
                        object_id: *package_id,
                    },
                })
            }
        } else {
            Ok(None)
        }
    }

    fn force_reload_system_packages(&self, system_package_ids: &[ObjectID]) {
        for package_id in system_package_ids {
            if let Some(p) = self
                .store
                .get_object(package_id)
                .expect("Failed to update system packages")
            {
                assert!(p.is_package());
                self.packages.insert(*package_id, PackageObject::new(p));
            }
            // It's possible that a package is not found if it's newly added system package ID
            // that hasn't got created yet. This should be very very rare though.
        }
    }

    fn get_object(&self, id: &ObjectID) -> SuiResult<Option<Object>> {
        if let Some(objects) = self.objects.get(id) {
            return Ok(Some(get_last(&*objects).1.clone()));
        }

        // We don't insert objects into the cache because they are usually only
        // read once.
        // TODO: we might want to cache immutable reads (RO shared objects and immutable objects)
        self.store.get_object(id)
    }

    fn get_object_by_key(
        &self,
        object_id: &ObjectID,
        version: SequenceNumber,
    ) -> SuiResult<Option<Object>> {
        if let Some(objects) = self.objects.get(object_id) {
            if let Some(object) = objects.get(&version) {
                return Ok(Some(object.clone()));
            }
        }

        // We don't insert objects into the cache because they are usually only
        // read once.
        self.store.get_object_by_key(object_id, version)
    }

    fn multi_get_object_by_key(
        &self,
        object_keys: &[ObjectKey],
    ) -> Result<Vec<Option<Object>>, SuiError> {
        let mut results = vec![None; object_keys.len()];
        let mut fallback_keys = Vec::with_capacity(object_keys.len());
        let mut fetch_indices = Vec::with_capacity(object_keys.len());

        for (i, key) in object_keys.iter().enumerate() {
            if let Some(object) = self.get_object_by_key(&key.0, key.1)? {
                results[i] = Some(object);
            } else {
                fallback_keys.push(*key);
                fetch_indices.push(i);
            }
        }

        let store_results = self.store.multi_get_object_by_key(&fallback_keys)?;
        assert_eq!(store_results.len(), fetch_indices.len());
        assert_eq!(store_results.len(), fallback_keys.len());

        for (i, result) in fetch_indices.into_iter().zip(store_results.into_iter()) {
            results[i] = result;
        }

        Ok(results)
    }

    /// If the shared object was deleted, return deletion info for the current live version
    fn get_last_shared_object_deletion_info(
        &self,
        object_id: &ObjectID,
        epoch_id: EpochId,
    ) -> SuiResult<Option<(SequenceNumber, TransactionDigest)>> {
        if let Some(markers) = self.markers.get(object_id) {
            if let (version, MarkerValue::SharedDeleted(digest)) = get_last(&*markers.lock()) {
                return Ok(Some((*version, *digest)));
            }
        }

        // TODO: should we update the cache?
        self.store
            .get_last_shared_object_deletion_info(object_id, epoch_id)
    }

    /// If the shared object was deleted, return deletion info for the specified version.
    fn get_deleted_shared_object_previous_tx_digest(
        &self,
        object_id: &ObjectID,
        version: &SequenceNumber,
        epoch_id: EpochId,
    ) -> SuiResult<Option<TransactionDigest>> {
        if let Some(markers) = self.markers.get(object_id) {
            if let Some(MarkerValue::SharedDeleted(digest)) = markers.lock().get(version) {
                return Ok(Some(*digest));
            }
        }

        self.store
            .get_deleted_shared_object_previous_tx_digest(object_id, version, epoch_id)
    }

    fn have_received_object_at_version(
        &self,
        object_id: &ObjectID,
        version: SequenceNumber,
        epoch_id: EpochId,
    ) -> SuiResult<bool> {
        if let Some(markers) = self.markers.get(object_id) {
            if let Some(MarkerValue::Received) = markers.lock().get(&version) {
                return Ok(true);
            }
        }

        self.store
            .have_received_object_at_version(object_id, version, epoch_id)
    }
}

impl ExecutionCacheWrite for InMemoryCache {
    fn update_state(&self, _epoch_id: EpochId, tx_outputs: TransactionOutputs) -> SuiResult {
        let TransactionOutputs {
            transaction,
            effects,
            markers,
            written,
            ..
        } = &tx_outputs;

        // Update all marekrs
        for (object_key, marker_value) in markers.iter() {
            self.markers
                .entry_by_ref(&object_key.0)
                .or_insert_with(|| Arc::new(Mutex::new(BTreeMap::new())))
                .value()
                .lock()
                .insert(object_key.1, *marker_value);
        }

        // Write children before parents to ensure that readers do not observe a parent object
        // before its most recent children are visible.
        for (object_id, object) in written.iter() {
            if object.is_child_object() {
                self.insert_object(object_id, object);
            }
        }
        for (object_id, object) in written.iter() {
            if !object.is_child_object() {
                self.insert_object(object_id, object);
                if object.is_package() {
                    self.packages
                        .insert(*object_id, PackageObject::new(object.clone()));
                }
            }
        }

        let effects_digest = effects.digest();

        self.transaction_effects
            .insert(effects_digest, effects.clone());

        self.executed_effects_digests
            .insert(*transaction.digest(), effects_digest);

        self.pending_transaction_writes
            .insert(*transaction.digest(), tx_outputs);

        Ok(())
    }
}

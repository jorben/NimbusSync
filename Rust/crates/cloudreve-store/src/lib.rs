//! SQLite state store used by both the app and File Provider processes.
//!
//! The store owns facts that must survive process termination. Network calls,
//! hashing and system signalling happen outside transactions.

use cloudreve_protocol::{CapabilitySnapshot, SyncAnchor};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;
use uuid::Uuid;

pub const SCHEMA_VERSION: i64 = 7;
pub const JOURNAL_RETENTION_COUNT: i64 = 100_000;
pub const JOURNAL_HARD_LIMIT_COUNT: i64 = 1_000_000;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("schema is fenced: {0}")]
    SchemaFenced(String),
    #[error("unknown domain")]
    UnknownDomain,
    #[error("local callback changes are not provider-visible")]
    LocalChangeNotProviderVisible,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DomainRecord {
    pub domain_id: Uuid,
    pub origin: String,
    pub account_id: String,
    pub display_name: String,
    pub root_entity_id: String,
    pub root_uri: String,
    pub scope_key: String,
    pub status: String,
    pub secret_ref: String,
    pub capability_revision: u64,
    pub capability_snapshot: CapabilitySnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemRecord {
    pub item_id: Uuid,
    pub remote_id: Option<String>,
    pub parent_id: Option<Uuid>,
    pub name: String,
    pub kind: String,
    pub uri: String,
    pub content_version: Vec<u8>,
    pub metadata_version: Vec<u8>,
    pub size: u64,
    pub trashed: bool,
    pub tombstone: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChangeRecord {
    pub item_id: Uuid,
    pub old_parent_id: Option<Uuid>,
    pub new_parent_id: Option<Uuid>,
    pub kind: String,
    pub version: Vec<u8>,
    pub origin: String,
    pub provider_visible: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JournalEntry {
    pub sequence: i64,
    pub epoch: Uuid,
    pub record: ChangeRecord,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChangeBatch {
    pub changes: Vec<JournalEntry>,
    pub next_anchor: SyncAnchor,
    pub more_coming: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OperationRecord {
    pub operation_id: Uuid,
    pub replay_key: String,
    pub kind: String,
    pub item_id: Option<Uuid>,
    pub expected_version: Option<Vec<u8>>,
    pub changed_fields: Vec<String>,
    pub state: String,
    pub source_generation: u64,
    pub cancel_requested: bool,
}

pub type OperationOutcome = (String, Option<Uuid>, Option<String>);

pub struct StateStore {
    connection: Connection,
}

impl StateStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StoreError> {
        let connection = Connection::open(path)?;
        let mut store = Self { connection };
        store.configure()?;
        store.migrate()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        let connection = Connection::open_in_memory()?;
        let mut store = Self { connection };
        store.configure()?;
        store.migrate()?;
        Ok(store)
    }

    fn configure(&self) -> Result<(), StoreError> {
        self.connection.execute_batch(
            "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = FULL; PRAGMA busy_timeout = 3000;",
        )?;
        Ok(())
    }

    pub fn migrate(&mut self) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute_batch(SCHEMA_SQL)?;
        transaction.execute(
            "INSERT OR IGNORE INTO schema_meta (singleton, version, generation, compat_min, compat_max, migration_state) VALUES (1, ?1, ?1, ?1, ?1, 'ready')",
            params![SCHEMA_VERSION],
        )?;
        let version: i64 = transaction.query_row(
            "SELECT version FROM schema_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        if version != SCHEMA_VERSION {
            return Err(StoreError::SchemaFenced(format!(
                "expected {}, found {}",
                SCHEMA_VERSION, version
            )));
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn quick_check(&self) -> Result<bool, StoreError> {
        let result: String = self
            .connection
            .query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        Ok(result.eq_ignore_ascii_case("ok"))
    }

    pub fn schema_version(&self) -> Result<i64, StoreError> {
        Ok(self.connection.query_row(
            "SELECT version FROM schema_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?)
    }

    pub fn backup_to(&self, destination: impl AsRef<Path>) -> Result<(), StoreError> {
        self.connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
        self.connection
            .backup(rusqlite::MAIN_DB, destination, None)?;
        Ok(())
    }

    pub fn insert_domain(&mut self, record: &DomainRecord) -> Result<(), StoreError> {
        let snapshot = serde_json::to_string(&record.capability_snapshot)?;
        self.connection.execute(
            "INSERT INTO domains (domain_id, origin, display_name, account_id, root_entity_id, root_uri, scope_key, status, secret_ref, capability_revision, capability_snapshot) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![record.domain_id.to_string(), record.origin, record.display_name, record.account_id, record.root_entity_id, record.root_uri, record.scope_key, record.status, record.secret_ref, record.capability_revision as i64, snapshot],
        )?;
        self.connection.execute(
            "INSERT OR IGNORE INTO sync_state (singleton, epoch, min_valid_sequence, next_sequence, domain_version_revision, reconcile_status) VALUES (1, ?1, 0, 1, 0, 'initializing')",
            params![Uuid::new_v4().to_string()],
        )?;
        Ok(())
    }

    pub fn append_change(&mut self, change: &ChangeRecord) -> Result<JournalEntry, StoreError> {
        if !change.provider_visible {
            return Err(StoreError::LocalChangeNotProviderVisible);
        }
        let transaction = self.connection.transaction()?;
        let (epoch_string, sequence, domain_version): (String, i64, i64) = transaction.query_row(
            "SELECT epoch, next_sequence, domain_version_revision FROM sync_state WHERE singleton = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
        let epoch = Uuid::parse_str(&epoch_string).unwrap_or_else(|_| Uuid::new_v4());
        let payload = serde_json::to_vec(change)?;
        if payload.len() > 64 * 1024 {
            return Err(StoreError::SchemaFenced(
                "journal payload exceeds 64 KiB".into(),
            ));
        }
        transaction.execute(
            "INSERT INTO change_journal (sequence, epoch, item_uuid, old_parent_uuid, new_parent_uuid, change_kind, version, item_payload, item_version, origin, delivery_audience) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?7, ?9, 'working_set')",
            params![sequence, epoch.to_string(), change.item_id.to_string(), change.old_parent_id.map(|value| value.to_string()), change.new_parent_id.map(|value| value.to_string()), change.kind, change.version, payload, change.origin],
        )?;
        transaction.execute(
            "INSERT INTO signal_outbox (signal_id, working_set_revision, state, attempt) VALUES (?1, ?2, 'pending', 0) ON CONFLICT(working_set_revision) DO UPDATE SET state = 'pending'",
            params![Uuid::new_v4().to_string(), sequence],
        )?;
        transaction.execute(
            "UPDATE sync_state SET next_sequence = ?1, domain_version_revision = ?2 WHERE singleton = 1",
            params![sequence + 1, domain_version + 1],
        )?;
        transaction.commit()?;
        Ok(JournalEntry {
            sequence,
            epoch,
            record: change.clone(),
            payload,
        })
    }

    pub fn current_anchor(&self, domain_id: Uuid, scope: &str) -> Result<SyncAnchor, StoreError> {
        let (epoch_string, sequence, min_sequence): (String, i64, i64) = self
            .connection
            .query_row(
            "SELECT epoch, next_sequence, min_valid_sequence FROM sync_state WHERE singleton = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
        Ok(SyncAnchor::new(
            domain_id,
            scope,
            Uuid::parse_str(&epoch_string).unwrap_or_else(|_| Uuid::new_v4()),
            sequence.saturating_sub(1).max(min_sequence) as u64,
        ))
    }

    pub fn enumerate_changes(
        &self,
        anchor: &SyncAnchor,
        limit: usize,
        domain_id: Uuid,
        scope: &str,
    ) -> Result<ChangeBatch, StoreError> {
        let current = self.current_anchor(domain_id, scope)?;
        let min_sequence: i64 = self.connection.query_row(
            "SELECT min_valid_sequence FROM sync_state WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        anchor
            .validate(domain_id, scope, current.epoch, min_sequence.max(0) as u64)
            .map_err(|_| StoreError::SchemaFenced("sync anchor expired or mismatched".into()))?;
        let mut statement = self.connection.prepare(
            "SELECT sequence, epoch, item_uuid, old_parent_uuid, new_parent_uuid, change_kind, version, item_payload, origin FROM change_journal WHERE sequence > ?1 ORDER BY sequence ASC LIMIT ?2",
        )?;
        let rows = statement
            .query_map(
                params![anchor.sequence as i64, limit.max(1) as i64],
                |row| {
                    let item_id = Uuid::parse_str(&row.get::<_, String>(2)?)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?;
                    let old_parent_id = row
                        .get::<_, Option<String>>(3)?
                        .and_then(|value| Uuid::parse_str(&value).ok());
                    let new_parent_id = row
                        .get::<_, Option<String>>(4)?
                        .and_then(|value| Uuid::parse_str(&value).ok());
                    let epoch = Uuid::parse_str(&row.get::<_, String>(1)?)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?;
                    Ok(JournalEntry {
                        sequence: row.get(0)?,
                        epoch,
                        record: ChangeRecord {
                            item_id,
                            old_parent_id,
                            new_parent_id,
                            kind: row.get(5)?,
                            version: row.get(6)?,
                            origin: row.get(8)?,
                            provider_visible: true,
                        },
                        payload: row.get(7)?,
                    })
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        let scanned_count = rows.len();
        let scanned_last = rows
            .last()
            .map(|entry| entry.sequence as u64)
            .unwrap_or(anchor.sequence);
        let is_working_set = scope == "working_set";
        let rows = rows
            .into_iter()
            .filter(|entry| {
                is_working_set
                    || entry
                        .record
                        .old_parent_id
                        .map(|id| format!("cri-{id}") == scope)
                        .unwrap_or(false)
                    || entry
                        .record
                        .new_parent_id
                        .map(|id| format!("cri-{id}") == scope)
                        .unwrap_or(false)
            })
            .collect::<Vec<_>>();
        let last_sequence = scanned_last;
        let more = scanned_count >= limit.max(1)
            && self.connection.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM change_journal WHERE sequence > ?1",
                params![last_sequence as i64],
                |row| row.get(0),
            )? > 0;
        let mut next = current.clone();
        next.sequence = last_sequence;
        Ok(ChangeBatch {
            changes: rows,
            next_anchor: next,
            more_coming: more,
        })
    }

    pub fn pending_outbox_count(&self) -> Result<i64, StoreError> {
        Ok(self.connection.query_row(
            "SELECT COUNT(*) FROM signal_outbox WHERE state = 'pending'",
            [],
            |row| row.get(0),
        )?)
    }

    pub fn acknowledge_outbox(&mut self, revision: i64) -> Result<(), StoreError> {
        self.connection.execute("UPDATE signal_outbox SET state = 'acknowledged', acknowledged_at = unixepoch() WHERE working_set_revision <= ?1", params![revision])?;
        Ok(())
    }

    pub fn upsert_operation(
        &mut self,
        operation: &OperationRecord,
    ) -> Result<OperationRecord, StoreError> {
        if let Some(existing) = self.connection.query_row(
            "SELECT operation_id, replay_key, kind, item_uuid, expected_version, changed_fields, state, source_generation, cancel_requested FROM operations WHERE replay_key = ?1",
            params![operation.replay_key],
            operation_from_row,
        ).optional()? {
            return Ok(existing);
        }
        self.connection.execute(
            "INSERT INTO operations (operation_id, replay_key, kind, item_uuid, expected_version, changed_fields, state, source_generation, cancel_requested) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![operation.operation_id.to_string(), operation.replay_key, operation.kind, operation.item_id.map(|value| value.to_string()), operation.expected_version, serde_json::to_string(&operation.changed_fields)?, operation.state, operation.source_generation as i64, operation.cancel_requested as i64],
        )?;
        Ok(operation.clone())
    }

    pub fn commit_operation(
        &mut self,
        operation_id: Uuid,
        state: &str,
        item_id: Option<Uuid>,
        outcome: Option<&str>,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE operations SET state = ?1, item_uuid = ?2, outcome = ?3, updated_at = unixepoch() WHERE operation_id = ?4",
            params![state, item_id.map(|value| value.to_string()), outcome, operation_id.to_string()],
        )?;
        Ok(())
    }

    pub fn operation_outcome(
        &self,
        replay_key: &str,
    ) -> Result<Option<OperationOutcome>, StoreError> {
        self.connection
            .query_row(
                "SELECT state, item_uuid, outcome FROM operations WHERE replay_key = ?1",
                params![replay_key],
                |row| {
                    let item_id = row
                        .get::<_, Option<String>>(1)?
                        .and_then(|value| Uuid::parse_str(&value).ok());
                    Ok((row.get(0)?, item_id, row.get(2)?))
                },
            )
            .optional()
            .map_err(StoreError::from)
    }

    pub fn request_cancel(&mut self, operation_id: Uuid) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE operations SET cancel_requested = 1 WHERE operation_id = ?1",
            params![operation_id.to_string()],
        )?;
        Ok(())
    }

    pub fn has_dirty_work(&self) -> Result<bool, StoreError> {
        let count: i64 = self.connection.query_row(
            "SELECT (SELECT COUNT(*) FROM operations WHERE state NOT IN ('committed', 'cancelled', 'permanently_failed', 'resolved')) + (SELECT COUNT(*) FROM conflicts WHERE state = 'pending') + (SELECT COUNT(*) FROM upload_sessions WHERE state NOT IN ('completed', 'abandoned'))",
            [],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn compact_journal(&mut self) -> Result<(), StoreError> {
        let count: i64 =
            self.connection
                .query_row("SELECT COUNT(*) FROM change_journal", [], |row| row.get(0))?;
        if count <= JOURNAL_HARD_LIMIT_COUNT {
            return Ok(());
        }
        let retained_minimum: i64 = self.connection.query_row(
            "SELECT sequence FROM change_journal ORDER BY sequence DESC LIMIT 1 OFFSET ?1",
            params![JOURNAL_RETENTION_COUNT - 1],
            |row| row.get(0),
        )?;
        let deleted_through = retained_minimum.saturating_sub(1);
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "DELETE FROM change_journal WHERE sequence <= ?1",
            params![deleted_through],
        )?;
        transaction.execute(
            "UPDATE sync_state SET min_valid_sequence = ?1",
            params![deleted_through],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn insert_item(&mut self, item: &ItemRecord) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO items (item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, content_version, metadata_version, size, trashed, tombstone) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) ON CONFLICT(item_uuid) DO UPDATE SET remote_entity_id = excluded.remote_entity_id, parent_uuid = excluded.parent_uuid, remote_name = excluded.remote_name, kind = excluded.kind, current_remote_uri = excluded.current_remote_uri, content_version = excluded.content_version, metadata_version = excluded.metadata_version, size = excluded.size, trashed = excluded.trashed, tombstone = excluded.tombstone",
            params![item.item_id.to_string(), item.remote_id, item.parent_id.map(|value| value.to_string()), item.name, item.kind, item.uri, item.content_version, item.metadata_version, item.size as i64, item.trashed as i64, item.tombstone as i64],
        )?;
        Ok(())
    }

    pub fn insert_items_batch(&mut self, items: &[ItemRecord]) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        for item in items {
            transaction.execute(
                "INSERT OR REPLACE INTO items (item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, content_version, metadata_version, size, trashed, tombstone) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![item.item_id.to_string(), item.remote_id, item.parent_id.map(|value| value.to_string()), item.name, item.kind, item.uri, item.content_version, item.metadata_version, item.size as i64, item.trashed as i64, item.tombstone as i64],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_item_ids(&self, parent_id: Option<Uuid>) -> Result<Vec<Uuid>, StoreError> {
        let mut statement = self.connection.prepare("SELECT item_uuid FROM items WHERE parent_uuid IS ?1 AND tombstone = 0 ORDER BY remote_name COLLATE NOCASE, item_uuid")?;
        let rows = statement
            .query_map(params![parent_id.map(|value| value.to_string())], |row| {
                Uuid::parse_str(&row.get::<_, String>(0)?)
                    .map_err(|_| rusqlite::Error::InvalidQuery)
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

fn operation_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<OperationRecord> {
    Ok(OperationRecord {
        operation_id: Uuid::parse_str(&row.get::<_, String>(0)?)
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
        replay_key: row.get(1)?,
        kind: row.get(2)?,
        item_id: row
            .get::<_, Option<String>>(3)?
            .and_then(|value| Uuid::parse_str(&value).ok()),
        expected_version: row.get(4)?,
        changed_fields: row
            .get::<_, Option<String>>(5)?
            .and_then(|value| serde_json::from_str(&value).ok())
            .unwrap_or_default(),
        state: row.get(6)?,
        source_generation: row.get::<_, i64>(7)? as u64,
        cancel_requested: row.get::<_, i64>(8)? != 0,
    })
}

pub fn schema_manifest() -> &'static [&'static str] {
    &[
        "auth_lease",
        "change_journal",
        "conflicts",
        "directory_snapshot_generations",
        "directory_snapshot_heads",
        "directory_snapshot_items",
        "directory_snapshots",
        "domain_actions",
        "domains",
        "exclusion_intents",
        "item_local_state",
        "items",
        "materialized_containers",
        "operations",
        "pending_creations",
        "pending_items",
        "preferences",
        "process_heartbeats",
        "projection_refresh_jobs",
        "reconcile_runs",
        "schema_meta",
        "signal_outbox",
        "sync_state",
        "system_pending_observations",
        "system_set_state",
        "tasks",
        "upload_parts",
        "upload_sessions",
        "visited_containers",
    ]
}

pub fn shared_schema_manifest() -> serde_json::Value {
    serde_json::from_str(include_str!("../../../schema-manifest.json"))
        .expect("shared schema manifest must be valid JSON")
}

pub fn schema_column_manifest() -> &'static [(&'static str, &'static [&'static str])] {
    &[
        (
            "change_journal",
            &[
                "sequence",
                "epoch",
                "item_uuid",
                "old_parent_uuid",
                "new_parent_uuid",
                "change_kind",
                "version",
                "item_payload",
                "item_version",
                "origin",
                "delivery_audience",
                "created_at",
            ],
        ),
        (
            "directory_snapshot_generations",
            &[
                "snapshot_id",
                "domain_id",
                "parent_uuid",
                "generation",
                "server_snapshot_token",
                "next_cursor",
                "state",
                "item_count",
                "created_at",
                "updated_at",
                "expires_at",
            ],
        ),
        (
            "domains",
            &[
                "domain_id",
                "display_name",
                "origin",
                "account_id",
                "root_entity_id",
                "root_uri",
                "scope_key",
                "status",
                "secret_ref",
                "capability_revision",
                "capability_snapshot",
                "icon_url",
            ],
        ),
        (
            "items",
            &[
                "item_uuid",
                "remote_entity_id",
                "parent_uuid",
                "trash_original_parent_uuid",
                "remote_name",
                "kind",
                "current_remote_uri",
                "content_version",
                "metadata_version",
                "size",
                "remote_version",
                "trashed",
                "tombstone",
                "created_at",
                "modified_at",
                "can_read",
                "can_write",
                "can_add_children",
                "can_trash",
                "can_delete",
                "content_type",
            ],
        ),
        (
            "directory_snapshot_heads",
            &[
                "domain_id",
                "parent_uuid",
                "current_snapshot_id",
                "current_generation",
            ],
        ),
        (
            "directory_snapshot_items",
            &["snapshot_id", "order_index", "item_uuid", "item_payload"],
        ),
        (
            "item_local_state",
            &[
                "item_uuid",
                "materialized",
                "visited",
                "keep_policy",
                "upload_state",
                "download_state",
                "upload_error",
                "download_error",
                "system_visible",
                "view_excluded",
                "last_used_at",
                "updated_at",
            ],
        ),
        (
            "system_set_state",
            &[
                "set_kind",
                "system_anchor",
                "refresh_required",
                "refresh_cursor",
                "current_generation",
                "active_generation",
                "active_owner",
                "active_started_at",
                "scan_state",
                "maximum_size_reached",
                "domain_version",
                "last_completed_at",
                "updated_at",
            ],
        ),
    ]
}

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS schema_meta (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL, generation INTEGER NOT NULL, compat_min INTEGER NOT NULL, compat_max INTEGER NOT NULL, migration_state TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS domains (domain_id TEXT PRIMARY KEY, display_name TEXT NOT NULL, origin TEXT NOT NULL, account_id TEXT NOT NULL, root_entity_id TEXT NOT NULL, root_uri TEXT NOT NULL, scope_key TEXT NOT NULL, status TEXT NOT NULL, secret_ref TEXT NOT NULL, capability_revision INTEGER NOT NULL, capability_snapshot TEXT NOT NULL, icon_url TEXT);
CREATE TABLE IF NOT EXISTS domain_actions (action_id TEXT PRIMARY KEY, domain_id TEXT NOT NULL, kind TEXT NOT NULL, step TEXT NOT NULL, state TEXT NOT NULL, secret_ref TEXT, error TEXT, created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS process_heartbeats (role TEXT PRIMARY KEY, instance_id TEXT NOT NULL, bundle_version TEXT NOT NULL, schema_generation INTEGER NOT NULL, last_seen INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_state (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), epoch TEXT NOT NULL, next_sequence INTEGER NOT NULL DEFAULT 0, min_valid_sequence INTEGER NOT NULL DEFAULT 0, domain_version_revision INTEGER NOT NULL DEFAULT 0, last_event_at INTEGER, event_client_id TEXT, last_reconcile_at INTEGER, reconcile_status TEXT NOT NULL DEFAULT 'initializing', projection_schema_revision INTEGER NOT NULL DEFAULT 2, last_applied_projection_schema_revision INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS items (item_uuid TEXT PRIMARY KEY, remote_entity_id TEXT, parent_uuid TEXT, trash_original_parent_uuid TEXT, remote_name TEXT NOT NULL, kind TEXT NOT NULL, current_remote_uri TEXT NOT NULL, content_version BLOB NOT NULL, metadata_version BLOB NOT NULL, size INTEGER NOT NULL DEFAULT 0, remote_version TEXT, trashed INTEGER NOT NULL DEFAULT 0, tombstone INTEGER NOT NULL DEFAULT 0, created_at INTEGER, modified_at INTEGER, can_read INTEGER NOT NULL DEFAULT 0, can_write INTEGER NOT NULL DEFAULT 0, can_add_children INTEGER NOT NULL DEFAULT 0, can_trash INTEGER NOT NULL DEFAULT 0, can_delete INTEGER NOT NULL DEFAULT 0, content_type TEXT NOT NULL DEFAULT 'public.data');
CREATE UNIQUE INDEX IF NOT EXISTS items_remote_id ON items(remote_entity_id) WHERE remote_entity_id IS NOT NULL AND tombstone = 0;
CREATE INDEX IF NOT EXISTS items_parent_name ON items(parent_uuid, remote_name COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS directory_snapshots (parent_uuid TEXT PRIMARY KEY, snapshot_generation INTEGER NOT NULL, order_key TEXT NOT NULL, complete INTEGER NOT NULL, server_cursor TEXT, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS materialized_containers (item_uuid TEXT PRIMARY KEY, is_materialized INTEGER NOT NULL, observed_generation INTEGER, state_source TEXT NOT NULL DEFAULT 'unknown', updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS visited_containers (item_uuid TEXT PRIMARY KEY, last_seen_generation INTEGER NOT NULL DEFAULT 0, system_visible INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS item_local_state (item_uuid TEXT PRIMARY KEY, materialized INTEGER NOT NULL DEFAULT 0, visited INTEGER NOT NULL DEFAULT 0, keep_policy TEXT NOT NULL DEFAULT 'inherit', upload_state TEXT NOT NULL DEFAULT 'none', download_state TEXT NOT NULL DEFAULT 'none', upload_error TEXT, download_error TEXT, system_visible INTEGER NOT NULL DEFAULT 0, view_excluded INTEGER NOT NULL DEFAULT 0, last_used_at INTEGER, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS system_set_state (set_kind TEXT PRIMARY KEY, system_anchor BLOB, refresh_required INTEGER NOT NULL DEFAULT 0, refresh_cursor BLOB, current_generation INTEGER NOT NULL DEFAULT 0, active_generation INTEGER, active_owner TEXT, active_started_at INTEGER, scan_state TEXT NOT NULL DEFAULT 'idle', maximum_size_reached INTEGER NOT NULL DEFAULT 0, domain_version BLOB, last_completed_at INTEGER, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS system_pending_observations (item_uuid TEXT PRIMARY KEY, is_pending INTEGER NOT NULL, published_payload BLOB, observed_generation INTEGER, observed_payload BLOB, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS pending_items (item_uuid TEXT PRIMARY KEY, template_id TEXT, upload_error TEXT, download_error TEXT, published_generation INTEGER NOT NULL DEFAULT 0, observation_state TEXT NOT NULL DEFAULT 'pending', updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS change_journal (sequence INTEGER PRIMARY KEY, epoch TEXT NOT NULL, item_uuid TEXT NOT NULL, old_parent_uuid TEXT, new_parent_uuid TEXT, change_kind TEXT NOT NULL, version BLOB NOT NULL, item_payload BLOB, item_version BLOB, origin TEXT NOT NULL, delivery_audience TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE INDEX IF NOT EXISTS change_journal_epoch_sequence ON change_journal(epoch, sequence);
CREATE TABLE IF NOT EXISTS signal_outbox (signal_id TEXT PRIMARY KEY, working_set_revision INTEGER NOT NULL UNIQUE, state TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER, acknowledged_at INTEGER, created_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS pending_creations (system_template_id TEXT PRIMARY KEY, item_uuid TEXT NOT NULL, operation_id TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, replay_key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, item_uuid TEXT, expected_version BLOB, changed_fields TEXT, source_generation INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL, step TEXT, cancel_requested INTEGER NOT NULL DEFAULT 0, lease_owner TEXT, lease_expires_at INTEGER, attempt INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER, outcome TEXT, error_code TEXT, history_hidden INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS exclusion_intents (intent_id TEXT PRIMARY KEY, item_uuid TEXT, system_item_identifier TEXT, rule_revision INTEGER NOT NULL, kind TEXT NOT NULL, source_generation INTEGER NOT NULL, expected_version BLOB, path_hash BLOB, expires_at INTEGER, state TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (unixepoch()), consumed_at INTEGER);
CREATE TABLE IF NOT EXISTS upload_sessions (operation_id TEXT PRIMARY KEY, remote_session_ref TEXT, secret_ref TEXT, fingerprint BLOB NOT NULL, provider TEXT NOT NULL, chunk_size INTEGER NOT NULL, expires_at INTEGER, state TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS upload_parts (operation_id TEXT NOT NULL, part_index INTEGER NOT NULL, offset INTEGER NOT NULL, length INTEGER NOT NULL, source_hash BLOB, etag TEXT, state TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(operation_id, part_index));
CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, operation_id TEXT, item_identifier TEXT, direction TEXT NOT NULL, state TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, total_bytes INTEGER, error_code TEXT, created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS conflicts (conflict_id TEXT PRIMARY KEY, item_uuid TEXT, kind TEXT NOT NULL, base_metadata TEXT NOT NULL, remote_metadata TEXT NOT NULL, local_metadata TEXT NOT NULL, pending_item_id TEXT, source_generation INTEGER NOT NULL, state TEXT NOT NULL, resolution TEXT, remote_version BLOB, local_source_kind TEXT, expected_base_version BLOB, expected_source_hash BLOB, expected_source_size INTEGER, resolution_intent TEXT, resolution_state TEXT, created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE IF NOT EXISTS reconcile_runs (run_id TEXT PRIMARY KEY, scope TEXT NOT NULL, generation INTEGER NOT NULL, phase TEXT NOT NULL, cursor TEXT, state TEXT NOT NULL, started_at INTEGER NOT NULL DEFAULT (unixepoch()), completed_at INTEGER);
CREATE TABLE IF NOT EXISTS directory_snapshot_generations (snapshot_id TEXT PRIMARY KEY, domain_id TEXT NOT NULL, parent_uuid TEXT NOT NULL, generation INTEGER NOT NULL, server_snapshot_token BLOB, next_cursor BLOB, state TEXT NOT NULL, item_count INTEGER, created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()), expires_at INTEGER NOT NULL, UNIQUE(domain_id, parent_uuid, generation));
CREATE TABLE IF NOT EXISTS directory_snapshot_items (snapshot_id TEXT NOT NULL, order_index INTEGER NOT NULL, item_uuid TEXT NOT NULL, item_payload BLOB NOT NULL, PRIMARY KEY(snapshot_id, order_index), UNIQUE(snapshot_id, item_uuid), FOREIGN KEY(snapshot_id) REFERENCES directory_snapshot_generations(snapshot_id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS directory_snapshot_heads (domain_id TEXT NOT NULL, parent_uuid TEXT NOT NULL, current_snapshot_id TEXT NOT NULL, current_generation INTEGER NOT NULL, PRIMARY KEY(domain_id, parent_uuid), FOREIGN KEY(current_snapshot_id) REFERENCES directory_snapshot_generations(snapshot_id) ON DELETE RESTRICT);
CREATE TABLE IF NOT EXISTS projection_refresh_jobs (job_id TEXT PRIMARY KEY, domain_id TEXT NOT NULL, target_revision INTEGER NOT NULL, scope TEXT NOT NULL, cursor TEXT, state TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, last_error TEXT, feature_fallback_enabled INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE INDEX IF NOT EXISTS directory_snapshot_generations_lookup ON directory_snapshot_generations(domain_id, parent_uuid, state, generation);
CREATE INDEX IF NOT EXISTS directory_snapshot_items_item ON directory_snapshot_items(snapshot_id, item_uuid);
CREATE INDEX IF NOT EXISTS item_local_state_materialized ON item_local_state(materialized, visited, system_visible);
CREATE INDEX IF NOT EXISTS projection_refresh_jobs_domain_state ON projection_refresh_jobs(domain_id, state, updated_at);
CREATE TABLE IF NOT EXISTS auth_lease (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), owner_instance_id TEXT, lease_epoch INTEGER NOT NULL DEFAULT 0, expires_at INTEGER, credential_generation INTEGER NOT NULL DEFAULT 0, last_refresh_outcome TEXT);
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use cloudreve_protocol::CapabilitySnapshot;

    fn domain() -> DomainRecord {
        DomainRecord {
            domain_id: Uuid::new_v4(),
            origin: "https://example.com".into(),
            account_id: "account".into(),
            display_name: "Test".into(),
            root_entity_id: "root".into(),
            root_uri: "/".into(),
            scope_key: "scope".into(),
            status: "healthy".into(),
            secret_ref: "credential-ref".into(),
            capability_revision: 1,
            capability_snapshot: CapabilitySnapshot::read_only_default(),
        }
    }

    #[test]
    fn schema_is_complete_and_quick_check_is_safe() {
        let store = StateStore::open_in_memory().unwrap();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);
        assert!(store.quick_check().unwrap());
        assert_eq!(schema_manifest().len(), 29);
        let shared_manifest = shared_schema_manifest();
        let shared_tables = shared_manifest["tables"]
            .as_array()
            .expect("shared tables")
            .iter()
            .map(|value| value.as_str().expect("table name"))
            .collect::<Vec<_>>();
        assert_eq!(shared_tables, schema_manifest());
        let shared_columns = shared_manifest["columns"]
            .as_object()
            .expect("shared columns");
        for table in schema_manifest() {
            let expected = shared_columns[*table]
                .as_array()
                .expect("table columns")
                .iter()
                .map(|value| value.as_str().expect("column name"))
                .collect::<Vec<_>>();
            let mut statement = store
                .connection
                .prepare(&format!("PRAGMA table_info({})", table))
                .unwrap();
            let actual = statement
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap();
            assert_eq!(actual, expected, "schema columns drifted for {table}");
        }
        let actual_indexes = store
            .connection
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        let expected_indexes = shared_manifest["indexes"]
            .as_array()
            .expect("shared indexes")
            .iter()
            .map(|value| value.as_str().expect("index name").to_string())
            .collect::<Vec<_>>();
        assert_eq!(actual_indexes, expected_indexes);
        assert_eq!(schema_column_manifest().len(), 8);
        for table in [
            "domains",
            "items",
            "change_journal",
            "signal_outbox",
            "operations",
            "upload_sessions",
            "conflicts",
        ] {
            assert!(store
                .connection
                .query_row::<i64, _, _>(&format!("SELECT COUNT(*) FROM {}", table), [], |row| row
                    .get(0))
                .is_ok());
        }
    }

    #[test]
    fn journal_and_outbox_commit_together_and_resume_after_restart() {
        let mut store = StateStore::open_in_memory().unwrap();
        let domain = domain();
        store.insert_domain(&domain).unwrap();
        let item_id = Uuid::new_v4();
        let entry = store
            .append_change(&ChangeRecord {
                item_id,
                old_parent_id: None,
                new_parent_id: None,
                kind: "created".into(),
                version: vec![1],
                origin: "remote".into(),
                provider_visible: true,
            })
            .unwrap();
        assert_eq!(entry.sequence, 1);
        assert_eq!(store.pending_outbox_count().unwrap(), 1);
        let anchor = SyncAnchor::new(domain.domain_id, "working_set", entry.epoch, 0);
        let batch = store
            .enumerate_changes(&anchor, 50, anchor.domain_id, &anchor.scope)
            .unwrap();
        assert_eq!(batch.changes.len(), 1);
        store.acknowledge_outbox(entry.sequence).unwrap();
        assert_eq!(store.pending_outbox_count().unwrap(), 0);
    }

    #[test]
    fn replay_key_is_idempotent_and_cancel_is_persistent() {
        let mut store = StateStore::open_in_memory().unwrap();
        let op = OperationRecord {
            operation_id: Uuid::new_v4(),
            replay_key: "template-1".into(),
            kind: "create".into(),
            item_id: None,
            expected_version: None,
            changed_fields: Vec::new(),
            state: "queued".into(),
            source_generation: 1,
            cancel_requested: false,
        };
        let first = store.upsert_operation(&op).unwrap();
        let second = store
            .upsert_operation(&OperationRecord {
                operation_id: Uuid::new_v4(),
                ..op.clone()
            })
            .unwrap();
        assert_eq!(first.operation_id, second.operation_id);
        store.request_cancel(first.operation_id).unwrap();
        let cancelled = store.upsert_operation(&op).unwrap();
        assert!(cancelled.cancel_requested);
    }
}

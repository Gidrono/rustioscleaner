//! SQLite store for assets, scores, clusters, decisions, scheduler checkpoints.

mod migrations;

use anyhow::{Context, Result};
use chrono::{TimeZone, Utc};
use cleaner_core::scheduler::{PowerState, SchedulerState, ThermalLevel};
use cleaner_core::types::{AssetFeatures, AssetId, AssetMeta, AssetRecord, Reason, Scores};
use cleaner_core::{Decision, ReviewItem, ReviewQueue};
use rusqlite::{params, Connection, OptionalExtension};

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path).context("open sqlite")?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA foreign_keys=ON;
             PRAGMA synchronous=NORMAL;",
        )?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys=ON;")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        migrations::run(&self.conn)
    }

    pub fn upsert_meta(&self, meta: &AssetMeta) -> Result<()> {
        self.conn.execute(
            "INSERT INTO assets (
                id, created_at, is_favorite, is_hidden, is_screenshot, is_burst, is_live,
                burst_id, latitude, longitude, pixel_width, pixel_height, byte_size,
                is_locally_available, secondary_backup_label, tier_completed
             ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,0)
             ON CONFLICT(id) DO UPDATE SET
                created_at=excluded.created_at,
                is_favorite=excluded.is_favorite,
                is_hidden=excluded.is_hidden,
                is_screenshot=excluded.is_screenshot,
                is_burst=excluded.is_burst,
                is_live=excluded.is_live,
                burst_id=excluded.burst_id,
                latitude=excluded.latitude,
                longitude=excluded.longitude,
                pixel_width=excluded.pixel_width,
                pixel_height=excluded.pixel_height,
                byte_size=excluded.byte_size,
                is_locally_available=excluded.is_locally_available,
                secondary_backup_label=excluded.secondary_backup_label",
            params![
                meta.id.as_str(),
                meta.created_at.timestamp(),
                meta.is_favorite as i32,
                meta.is_hidden as i32,
                meta.is_screenshot as i32,
                meta.is_burst as i32,
                meta.is_live as i32,
                meta.burst_id,
                meta.latitude,
                meta.longitude,
                meta.pixel_width,
                meta.pixel_height,
                meta.byte_size as i64,
                meta.is_locally_available as i32,
                meta.secondary_backup_label,
            ],
        )?;
        Ok(())
    }

    pub fn save_analysis(&self, record: &AssetRecord) -> Result<()> {
        self.upsert_meta(&record.meta)?;
        let features_json = serde_json::to_string(&record.features)?;
        let reasons_json = serde_json::to_string(&record.reasons)?;
        self.conn.execute(
            "UPDATE assets SET
                features_json=?2,
                junk=?3, miss=?4, aesthetic=?5,
                reasons_json=?6,
                cluster_id=?7,
                is_best_in_cluster=?8,
                tier_completed=?9,
                analyzed_at=?10
             WHERE id=?1",
            params![
                record.meta.id.as_str(),
                features_json,
                record.scores.junk,
                record.scores.miss,
                record.scores.aesthetic,
                reasons_json,
                record.cluster_id,
                record.is_best_in_cluster as i32,
                record.tier_completed as i32,
                record.analyzed_at.map(|t| t.timestamp()),
            ],
        )?;
        Ok(())
    }

    pub fn get_record(&self, id: &AssetId) -> Result<Option<AssetRecord>> {
        self.conn
            .query_row(
                "SELECT id, created_at, is_favorite, is_hidden, is_screenshot, is_burst, is_live,
                        burst_id, latitude, longitude, pixel_width, pixel_height, byte_size,
                        is_locally_available, secondary_backup_label,
                        features_json, junk, miss, aesthetic, reasons_json,
                        cluster_id, is_best_in_cluster, tier_completed, analyzed_at
                 FROM assets WHERE id=?1",
                params![id.as_str()],
                |row| Ok(row_to_record(row)),
            )
            .optional()
            .context("get_record")?
            .transpose()
    }

    pub fn ids_below_tier(&self, tier: u8) -> Result<Vec<AssetId>> {
        let mut stmt = self.conn.prepare(
            "SELECT id FROM assets WHERE tier_completed < ?1 AND is_favorite=0 AND is_hidden=0
             ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map(params![tier as i32], |r| {
            Ok(AssetId::new(r.get::<_, String>(0)?))
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn ambiguous_junk_ids(&self, low: f32, high: f32) -> Result<Vec<AssetId>> {
        // Candidates for VLM: junk score in ambiguous band, tier2 done, no VLM yet.
        let mut stmt = self.conn.prepare(
            "SELECT id FROM assets
             WHERE tier_completed = 2 AND junk >= ?1 AND junk <= ?2
               AND is_favorite=0 AND is_hidden=0
             ORDER BY ABS(junk - 0.5) ASC",
        )?;
        let rows = stmt.query_map(params![low, high], |r| {
            Ok(AssetId::new(r.get::<_, String>(0)?))
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn build_review_queue(&self, junk_thresh: f32, miss_thresh: f32) -> Result<ReviewQueue> {
        // Heaviest on disk first so early tosses free the most space.
        // Secondary-backup assets get a slightly softer threshold (matches fusion slack).
        let soft_junk = (junk_thresh - 0.08).max(0.35);
        let soft_miss = (miss_thresh - 0.08).max(0.40);
        let mut stmt = self.conn.prepare(
            "SELECT id, junk, miss, aesthetic, reasons_json, cluster_id, is_best_in_cluster
             FROM assets
             WHERE is_favorite=0 AND is_hidden=0
               AND (
                 CASE
                   WHEN secondary_backup_label IS NOT NULL AND length(trim(secondary_backup_label)) > 0
                     THEN (junk >= ?3 OR miss >= ?4)
                   ELSE (junk >= ?1 OR miss >= ?2)
                 END
               )
               AND (cluster_id IS NULL OR is_best_in_cluster=0)
             ORDER BY byte_size DESC, (pixel_width * pixel_height) DESC, MAX(junk, miss) DESC",
        )?;
        let items = stmt
            .query_map(params![junk_thresh, miss_thresh, soft_junk, soft_miss], |row| {
                let id: String = row.get(0)?;
                let reasons_json: String = row.get(4)?;
                let reasons: Vec<Reason> = serde_json::from_str(&reasons_json).unwrap_or_default();
                let cluster_id: Option<String> = row.get(5)?;
                Ok(ReviewItem {
                    asset_id: AssetId::new(id),
                    scores: Scores {
                        junk: row.get(1)?,
                        miss: row.get(2)?,
                        aesthetic: row.get(3)?,
                    },
                    reasons,
                    cluster_id,
                    is_best_in_cluster: row.get::<_, i32>(6)? != 0,
                    cluster_size: 1,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(ReviewQueue::new(items))
    }

    pub fn record_decision(&self, id: &AssetId, decision: Decision) -> Result<()> {
        self.conn.execute(
            "INSERT INTO decisions (asset_id, decision, decided_at) VALUES (?1,?2,?3)",
            params![id.as_str(), decision_str(decision), Utc::now().timestamp()],
        )?;
        Ok(())
    }

    pub fn save_scheduler(&self, state: &SchedulerState) -> Result<()> {
        let json = serde_json::to_string(state)?;
        self.conn.execute(
            "INSERT INTO kv (key, value) VALUES ('scheduler', ?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![json],
        )?;
        Ok(())
    }

    pub fn load_scheduler(&self) -> Result<SchedulerState> {
        let json: Option<String> = self
            .conn
            .query_row("SELECT value FROM kv WHERE key='scheduler'", [], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(match json {
            Some(j) => serde_json::from_str(&j).unwrap_or_default(),
            None => SchedulerState::default(),
        })
    }

    pub fn set_change_token(&self, token: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO kv (key, value) VALUES ('photo_change_token', ?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![token],
        )?;
        Ok(())
    }

    pub fn get_change_token(&self) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT value FROM kv WHERE key='photo_change_token'",
                [],
                |r| r.get(0),
            )
            .optional()
            .context("change_token")
    }

    pub fn asset_count(&self) -> Result<u64> {
        let n: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM assets", [], |r| r.get(0))?;
        Ok(n as u64)
    }

    pub fn update_cluster(
        &self,
        cluster_id: &str,
        member_ids: &[AssetId],
        best_id: &AssetId,
    ) -> Result<()> {
        for id in member_ids {
            self.conn.execute(
                "UPDATE assets SET cluster_id=?1, is_best_in_cluster=?2 WHERE id=?3",
                params![cluster_id, (id == best_id) as i32, id.as_str()],
            )?;
        }
        Ok(())
    }

    /// Device observation helper for FFI.
    pub fn observe_and_checkpoint(
        &self,
        thermal: ThermalLevel,
        power: PowerState,
        ram_gb: u32,
    ) -> Result<SchedulerState> {
        let mut state = self.load_scheduler()?;
        state.observe_device(thermal, power, ram_gb);
        self.save_scheduler(&state)?;
        Ok(state)
    }
}

fn decision_str(d: Decision) -> &'static str {
    match d {
        Decision::Keep => "keep",
        Decision::Toss => "toss",
        Decision::Skip => "skip",
        Decision::Undo => "undo",
    }
}

fn row_to_record(row: &rusqlite::Row<'_>) -> Result<AssetRecord> {
    let id: String = row.get(0)?;
    let created: i64 = row.get(1)?;
    let features_json: Option<String> = row.get(15)?;
    let reasons_json: Option<String> = row.get(19)?;
    let features: AssetFeatures = features_json
        .as_deref()
        .and_then(|j| serde_json::from_str(j).ok())
        .unwrap_or_default();
    let reasons: Vec<Reason> = reasons_json
        .as_deref()
        .and_then(|j| serde_json::from_str(j).ok())
        .unwrap_or_default();
    let analyzed: Option<i64> = row.get(23)?;
    Ok(AssetRecord {
        meta: AssetMeta {
            id: AssetId::new(id),
            created_at: Utc
                .timestamp_opt(created, 0)
                .single()
                .unwrap_or_else(Utc::now),
            is_favorite: row.get::<_, i32>(2)? != 0,
            is_hidden: row.get::<_, i32>(3)? != 0,
            is_screenshot: row.get::<_, i32>(4)? != 0,
            is_burst: row.get::<_, i32>(5)? != 0,
            is_live: row.get::<_, i32>(6)? != 0,
            burst_id: row.get(7)?,
            latitude: row.get(8)?,
            longitude: row.get(9)?,
            pixel_width: row.get::<_, i64>(10)? as u32,
            pixel_height: row.get::<_, i64>(11)? as u32,
            byte_size: row.get::<_, i64>(12)? as u64,
            is_locally_available: row.get::<_, i32>(13)? != 0,
            secondary_backup_label: row.get(14)?,
        },
        features,
        scores: Scores {
            junk: row.get(16)?,
            miss: row.get(17)?,
            aesthetic: row.get(18)?,
        },
        reasons,
        cluster_id: row.get(20)?,
        is_best_in_cluster: row.get::<_, i32>(21)? != 0,
        tier_completed: row.get::<_, i32>(22)? as u8,
        analyzed_at: analyzed.and_then(|t| Utc.timestamp_opt(t, 0).single()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use cleaner_core::signals::PixelSignals;
    use cleaner_core::types::AssetFeatures;

    fn junk_record(id: &str, w: u32, h: u32, junk: f32) -> AssetRecord {
        junk_record_with_bytes(id, w, h, junk, 0)
    }

    fn junk_record_with_bytes(id: &str, w: u32, h: u32, junk: f32, byte_size: u64) -> AssetRecord {
        AssetRecord {
            meta: AssetMeta {
                id: AssetId::new(id),
                created_at: Utc::now(),
                is_favorite: false,
                is_hidden: false,
                is_screenshot: false,
                is_burst: false,
                is_live: false,
                burst_id: None,
                latitude: None,
                longitude: None,
                pixel_width: w,
                pixel_height: h,
                byte_size,
                is_locally_available: true,
                secondary_backup_label: None,
            },
            features: AssetFeatures {
                pixel: Some(PixelSignals {
                    is_pocket_shot: true,
                    ..Default::default()
                }),
                ..Default::default()
            },
            scores: Scores {
                junk,
                miss: 0.0,
                aesthetic: 0.1,
            },
            reasons: vec![],
            cluster_id: None,
            is_best_in_cluster: false,
            tier_completed: 1,
            analyzed_at: Some(Utc::now()),
        }
    }

    #[test]
    fn upsert_and_queue() {
        let store = Store::open_in_memory().unwrap();
        store.save_analysis(&junk_record("p1", 100, 100, 0.9)).unwrap();
        assert_eq!(store.asset_count().unwrap(), 1);
        let q = store.build_review_queue(0.5, 0.5).unwrap();
        assert_eq!(q.remaining(), 1);
    }

    #[test]
    fn review_queue_orders_heaviest_first() {
        let store = Store::open_in_memory().unwrap();
        // Same pixel area — byte_size must decide order (not ingest/date order).
        store
            .save_analysis(&junk_record_with_bytes("small", 4032, 3024, 0.99, 1_000_000))
            .unwrap();
        store
            .save_analysis(&junk_record_with_bytes("large", 4032, 3024, 0.6, 8_000_000))
            .unwrap();
        store
            .save_analysis(&junk_record_with_bytes("medium", 4032, 3024, 0.8, 3_000_000))
            .unwrap();

        let q = store.build_review_queue(0.5, 0.5).unwrap();
        assert_eq!(q.remaining(), 3);
        let ids: Vec<_> = q
            .pending
            .iter()
            .map(|i| i.asset_id.as_str().to_string())
            .collect();
        assert_eq!(ids, vec!["large", "medium", "small"]);
    }
}

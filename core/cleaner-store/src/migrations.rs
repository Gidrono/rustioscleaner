use anyhow::Result;
use rusqlite::Connection;

const MIGRATION_V1: &str = r#"
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    is_hidden INTEGER NOT NULL DEFAULT 0,
    is_screenshot INTEGER NOT NULL DEFAULT 0,
    is_burst INTEGER NOT NULL DEFAULT 0,
    is_live INTEGER NOT NULL DEFAULT 0,
    burst_id TEXT,
    latitude REAL,
    longitude REAL,
    pixel_width INTEGER NOT NULL DEFAULT 0,
    pixel_height INTEGER NOT NULL DEFAULT 0,
    features_json TEXT,
    junk REAL NOT NULL DEFAULT 0,
    miss REAL NOT NULL DEFAULT 0,
    aesthetic REAL NOT NULL DEFAULT 0.5,
    reasons_json TEXT,
    cluster_id TEXT,
    is_best_in_cluster INTEGER NOT NULL DEFAULT 0,
    tier_completed INTEGER NOT NULL DEFAULT 0,
    analyzed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_assets_tier ON assets(tier_completed);
CREATE INDEX IF NOT EXISTS idx_assets_junk ON assets(junk);
CREATE INDEX IF NOT EXISTS idx_assets_miss ON assets(miss);
CREATE INDEX IF NOT EXISTS idx_assets_cluster ON assets(cluster_id);
CREATE INDEX IF NOT EXISTS idx_assets_created ON assets(created_at);

CREATE TABLE IF NOT EXISTS decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    asset_id TEXT NOT NULL,
    decision TEXT NOT NULL,
    decided_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_decisions_asset ON decisions(asset_id);

CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"#;

const MIGRATION_V2: &str = r#"
ALTER TABLE assets ADD COLUMN byte_size INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_assets_byte_size ON assets(byte_size);
"#;

const MIGRATION_V3: &str = r#"
ALTER TABLE assets ADD COLUMN is_locally_available INTEGER NOT NULL DEFAULT 1;
ALTER TABLE assets ADD COLUMN secondary_backup_label TEXT;
"#;

pub fn run(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        );",
    )?;
    let current: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    if current < 1 {
        conn.execute_batch(MIGRATION_V1)?;
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at) VALUES (1, strftime('%s','now'))",
            [],
        )?;
    }
    let current: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if current < 2 {
        conn.execute_batch(MIGRATION_V2)?;
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at) VALUES (2, strftime('%s','now'))",
            [],
        )?;
    }
    let current: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if current < 3 {
        conn.execute_batch(MIGRATION_V3)?;
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at) VALUES (3, strftime('%s','now'))",
            [],
        )?;
    }
    Ok(())
}

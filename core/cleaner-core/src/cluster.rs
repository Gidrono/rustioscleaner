//! Near-duplicate clustering by time window + dHash + embedding cosine.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::signals::dhash_distance;
use crate::types::{AssetId, AssetRecord};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterConfig {
    /// Max seconds between photos to be candidates for the same cluster.
    pub time_window_secs: i64,
    /// Max haversine meters (None = ignore location).
    pub location_meters: Option<f64>,
    /// Max dHash hamming distance to link.
    pub dhash_threshold: u32,
    /// Min cosine similarity on embeddings to link (if both have embeddings).
    pub embedding_cosine_min: f32,
}

impl Default for ClusterConfig {
    fn default() -> Self {
        Self {
            time_window_secs: 30,
            location_meters: Some(50.0),
            dhash_threshold: 10,
            embedding_cosine_min: 0.88,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhotoCluster {
    pub id: String,
    pub member_ids: Vec<AssetId>,
}

#[derive(Default)]
struct UnionFind {
    parent: Vec<usize>,
}

impl UnionFind {
    fn new(n: usize) -> Self {
        Self {
            parent: (0..n).collect(),
        }
    }

    fn find(&mut self, x: usize) -> usize {
        if self.parent[x] != x {
            let p = self.find(self.parent[x]);
            self.parent[x] = p;
        }
        self.parent[x]
    }

    fn union(&mut self, a: usize, b: usize) {
        let ra = self.find(a);
        let rb = self.find(b);
        if ra != rb {
            self.parent[rb] = ra;
        }
    }
}

/// Cluster assets that are near-duplicates within local time windows.
pub fn cluster_near_duplicates(
    records: &[AssetRecord],
    config: &ClusterConfig,
) -> Vec<PhotoCluster> {
    let n = records.len();
    if n == 0 {
        return vec![];
    }

    // Sort indices by created_at.
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by_key(|&i| records[i].meta.created_at);

    let mut uf = UnionFind::new(n);
    let window = Duration::seconds(config.time_window_secs);

    for (pos, &i) in order.iter().enumerate() {
        let t_i = records[i].meta.created_at;
        for &j in order.iter().skip(pos + 1) {
            let t_j = records[j].meta.created_at;
            if t_j - t_i > window {
                break;
            }
            if !location_ok(&records[i], &records[j], config) {
                continue;
            }
            if same_burst(&records[i], &records[j]) || similar(records, i, j, config) {
                uf.union(i, j);
            }
        }
    }

    let mut groups: std::collections::HashMap<usize, Vec<AssetId>> =
        std::collections::HashMap::new();
    for (i, record) in records.iter().enumerate() {
        let root = uf.find(i);
        groups.entry(root).or_default().push(record.meta.id.clone());
    }

    groups
        .into_values()
        .filter(|m| m.len() >= 2)
        .map(|member_ids| PhotoCluster {
            id: Uuid::new_v4().to_string(),
            member_ids,
        })
        .collect()
}

fn same_burst(a: &AssetRecord, b: &AssetRecord) -> bool {
    match (&a.meta.burst_id, &b.meta.burst_id) {
        (Some(x), Some(y)) if !x.is_empty() => x == y,
        _ => false,
    }
}

fn location_ok(a: &AssetRecord, b: &AssetRecord, config: &ClusterConfig) -> bool {
    let Some(max_m) = config.location_meters else {
        return true;
    };
    match (
        a.meta.latitude,
        a.meta.longitude,
        b.meta.latitude,
        b.meta.longitude,
    ) {
        (Some(lat1), Some(lon1), Some(lat2), Some(lon2)) => {
            haversine_m(lat1, lon1, lat2, lon2) <= max_m
        }
        _ => true, // missing location → allow
    }
}

fn similar(records: &[AssetRecord], i: usize, j: usize, config: &ClusterConfig) -> bool {
    let a = &records[i];
    let b = &records[j];

    let dhash_ok = match (
        a.features.pixel.as_ref().map(|p| p.dhash),
        b.features.pixel.as_ref().map(|p| p.dhash),
    ) {
        (Some(ha), Some(hb)) => dhash_distance(ha, hb) <= config.dhash_threshold,
        _ => false,
    };

    let emb_ok = match (
        a.features.embedding.as_ref().map(|e| &e.embedding),
        b.features.embedding.as_ref().map(|e| &e.embedding),
    ) {
        (Some(ea), Some(eb)) if !ea.is_empty() && ea.len() == eb.len() => {
            cosine(ea, eb) >= config.embedding_cosine_min
        }
        _ => false,
    };

    dhash_ok || emb_ok
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for (&x, &y) in a.iter().zip(b.iter()) {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    let denom = na.sqrt() * nb.sqrt();
    if denom < 1e-12 {
        0.0
    } else {
        dot / denom
    }
}

pub fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let to_rad = |d: f64| d * std::f64::consts::PI / 180.0;
    let (phi1, phi2) = (to_rad(lat1), to_rad(lat2));
    let dphi = to_rad(lat2 - lat1);
    let dlambda = to_rad(lon2 - lon1);
    let a = (dphi / 2.0).sin().powi(2) + phi1.cos() * phi2.cos() * (dlambda / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
}

/// Helper for tests / CLI: seconds between.
pub fn within_window(a: DateTime<Utc>, b: DateTime<Utc>, secs: i64) -> bool {
    (a - b).num_seconds().abs() <= secs
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::PixelSignals;
    use crate::types::{AssetFeatures, AssetId, AssetMeta, Scores};
    use chrono::TimeZone;

    fn rec(id: &str, secs: i64, dhash: u64) -> AssetRecord {
        AssetRecord {
            meta: AssetMeta {
                id: AssetId::new(id),
                created_at: Utc.timestamp_opt(1_700_000_000 + secs, 0).unwrap(),
                is_favorite: false,
                is_hidden: false,
                is_screenshot: false,
                is_burst: false,
                is_live: false,
                burst_id: None,
                latitude: Some(37.77),
                longitude: Some(-122.42),
                pixel_width: 100,
                pixel_height: 100,
            },
            features: AssetFeatures {
                pixel: Some(PixelSignals {
                    dhash,
                    ..Default::default()
                }),
                ..Default::default()
            },
            scores: Scores::default(),
            reasons: vec![],
            cluster_id: None,
            is_best_in_cluster: false,
            tier_completed: 1,
            analyzed_at: None,
        }
    }

    #[test]
    fn clusters_near_dhash_within_window() {
        let records = vec![
            rec("a", 0, 0b1111_0000),
            rec("b", 5, 0b1111_0001),   // distance 1
            rec("c", 100, 0b0000_1111), // far in time
        ];
        let clusters = cluster_near_duplicates(&records, &ClusterConfig::default());
        assert_eq!(clusters.len(), 1);
        assert_eq!(clusters[0].member_ids.len(), 2);
    }

    #[test]
    fn cosine_identical() {
        let v = vec![1.0, 0.0, 0.0];
        assert!((cosine(&v, &v) - 1.0).abs() < 1e-5);
    }
}

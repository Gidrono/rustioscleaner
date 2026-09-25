//! UniFFI surface for the Swift shell.

uniffi::setup_scaffolding!();

use std::sync::Mutex;

use chrono::{TimeZone, Utc};
use cleaner_core::cluster::{cluster_near_duplicates, ClusterConfig};
use cleaner_core::fusion::fuse_scores;
use cleaner_core::queue::{Decision, ReviewQueue};
use cleaner_core::ranker::rank_cluster;
use cleaner_core::scheduler::{PowerState, SchedulerState, ThermalLevel, WorkTier};
use cleaner_core::signals::analyze_rgba;
use cleaner_core::types::{
    AssetFeatures, AssetId, AssetMeta, AssetRecord, CompositionFeatures, EmbeddingFeatures,
    FaceFeatures, Reason, ReasonKind, Scores, TextFeatures, VlmResult,
};
use cleaner_core::weights::FusionWeights;
use cleaner_store::Store;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CleanerError {
    #[error("{msg}")]
    Message { msg: String },
}

impl From<anyhow::Error> for CleanerError {
    fn from(e: anyhow::Error) -> Self {
        Self::Message { msg: e.to_string() }
    }
}

impl From<cleaner_core::signals::SignalError> for CleanerError {
    fn from(e: cleaner_core::signals::SignalError) -> Self {
        Self::Message { msg: e.to_string() }
    }
}

// --- FFI-friendly plain types ---

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiAssetMeta {
    pub id: String,
    pub created_at_unix: i64,
    pub is_favorite: bool,
    pub is_hidden: bool,
    pub is_screenshot: bool,
    pub is_burst: bool,
    pub is_live: bool,
    pub burst_id: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub pixel_width: u32,
    pub pixel_height: u32,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiFaceFeatures {
    pub face_count: u32,
    pub avg_capture_quality: f32,
    pub blink_count: u32,
    pub looking_away_count: u32,
    pub mouth_open_count: u32,
    pub any_blink: bool,
    pub any_looking_away: bool,
    pub any_mouth_open: bool,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiTextFeatures {
    pub has_dense_text: bool,
    pub has_barcode: bool,
    pub has_document: bool,
    pub text_block_count: u32,
    pub utility_keyword_hits: u32,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiCompositionFeatures {
    pub subject_placement: f32,
    pub subject_coverage: f32,
    pub cropped_subject: bool,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiJunkSimilarity {
    pub label: String,
    pub similarity: f32,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiEmbeddingFeatures {
    pub embedding: Vec<f32>,
    pub aesthetic_raw: f32,
    pub junk_similarities: Vec<FfiJunkSimilarity>,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiVlmResult {
    pub category: String,
    pub ephemeral: bool,
    pub reason: String,
    pub confidence: f32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiPixelSignals {
    pub blur_variance: f32,
    pub dark_fraction: f32,
    pub bright_fraction: f32,
    pub mean_luminance: f32,
    pub dhash: u64,
    pub is_pocket_shot: bool,
    pub uniformity: f32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiScores {
    pub junk: f32,
    pub miss: f32,
    pub aesthetic: f32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiReason {
    pub kind: String,
    pub detail: String,
    pub confidence: f32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiFusionResult {
    pub scores: FfiScores,
    pub reasons: Vec<FfiReason>,
    pub should_queue: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiReviewItem {
    pub asset_id: String,
    pub scores: FfiScores,
    pub reasons: Vec<FfiReason>,
    pub cluster_id: Option<String>,
    pub is_best_in_cluster: bool,
    pub cluster_size: u32,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum FfiDecision {
    Keep,
    Toss,
    Skip,
    Undo,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum FfiThermal {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum FfiPower {
    Battery,
    Charging,
    Full,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum FfiWorkTier {
    Pixel,
    VisionMl,
    Vlm,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiWorkBatch {
    pub tier: FfiWorkTier,
    pub asset_ids: Vec<String>,
    pub recommended_batch_size: u32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiSchedulerSnapshot {
    pub paused: bool,
    pub pause_reason: Option<String>,
    pub batch_size: u32,
    pub tier1_done: u64,
    pub tier2_done: u64,
    pub tier3_done: u64,
    pub can_run_vlm: bool,
}

/// Analyze a downsampled RGBA thumbnail (Tier 1).
#[uniffi::export]
pub fn analyze_thumbnail(
    width: u32,
    height: u32,
    rgba: Vec<u8>,
) -> Result<FfiPixelSignals, CleanerError> {
    let s = analyze_rgba(width, height, &rgba)?;
    Ok(FfiPixelSignals {
        blur_variance: s.blur_variance,
        dark_fraction: s.dark_fraction,
        bright_fraction: s.bright_fraction,
        mean_luminance: s.mean_luminance,
        dhash: s.dhash,
        is_pocket_shot: s.is_pocket_shot,
        uniformity: s.uniformity,
    })
}

fn meta_from_ffi(m: &FfiAssetMeta) -> AssetMeta {
    AssetMeta {
        id: AssetId::new(m.id.clone()),
        created_at: Utc
            .timestamp_opt(m.created_at_unix, 0)
            .single()
            .unwrap_or_else(Utc::now),
        is_favorite: m.is_favorite,
        is_hidden: m.is_hidden,
        is_screenshot: m.is_screenshot,
        is_burst: m.is_burst,
        is_live: m.is_live,
        burst_id: m.burst_id.clone(),
        latitude: m.latitude,
        longitude: m.longitude,
        pixel_width: m.pixel_width,
        pixel_height: m.pixel_height,
    }
}

fn reason_kind_label(k: &ReasonKind) -> String {
    format!("{k:?}")
}

fn reason_to_ffi(r: &Reason) -> FfiReason {
    FfiReason {
        kind: r.kind.label().to_string(),
        detail: r.detail.clone(),
        confidence: r.confidence,
    }
}

/// Fuse analyzer outputs into scores + reasons.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn fuse_asset(
    meta: FfiAssetMeta,
    pixel: Option<FfiPixelSignals>,
    face: Option<FfiFaceFeatures>,
    text: Option<FfiTextFeatures>,
    composition: Option<FfiCompositionFeatures>,
    embedding: Option<FfiEmbeddingFeatures>,
    vlm: Option<FfiVlmResult>,
    weights_toml: Option<String>,
) -> Result<FfiFusionResult, CleanerError> {
    let weights = match weights_toml {
        Some(s) => FusionWeights::from_toml(&s)
            .map_err(|e| CleanerError::Message { msg: e.to_string() })?,
        None => FusionWeights::default(),
    };

    let features = AssetFeatures {
        pixel: pixel.map(|p| cleaner_core::signals::PixelSignals {
            blur_variance: p.blur_variance,
            dark_fraction: p.dark_fraction,
            bright_fraction: p.bright_fraction,
            mean_luminance: p.mean_luminance,
            dhash: p.dhash,
            is_pocket_shot: p.is_pocket_shot,
            uniformity: p.uniformity,
        }),
        face: face.map(|f| FaceFeatures {
            face_count: f.face_count,
            avg_capture_quality: f.avg_capture_quality,
            blink_count: f.blink_count,
            looking_away_count: f.looking_away_count,
            mouth_open_count: f.mouth_open_count,
            any_blink: f.any_blink,
            any_looking_away: f.any_looking_away,
            any_mouth_open: f.any_mouth_open,
        }),
        text: text.map(|t| TextFeatures {
            has_dense_text: t.has_dense_text,
            has_barcode: t.has_barcode,
            has_document: t.has_document,
            text_block_count: t.text_block_count,
            utility_keyword_hits: t.utility_keyword_hits,
        }),
        composition: composition.map(|c| CompositionFeatures {
            subject_placement: c.subject_placement,
            subject_coverage: c.subject_coverage,
            cropped_subject: c.cropped_subject,
        }),
        embedding: embedding.map(|e| EmbeddingFeatures {
            embedding: e.embedding,
            aesthetic_raw: e.aesthetic_raw,
            junk_similarities: e
                .junk_similarities
                .into_iter()
                .map(|j| (j.label, j.similarity))
                .collect(),
        }),
        vlm: vlm.map(|v| VlmResult {
            category: v.category,
            ephemeral: v.ephemeral,
            reason: v.reason,
            confidence: v.confidence,
        }),
    };

    let result = fuse_scores(&meta_from_ffi(&meta), &features, &weights);
    Ok(FfiFusionResult {
        scores: FfiScores {
            junk: result.scores.junk,
            miss: result.scores.miss,
            aesthetic: result.scores.aesthetic,
        },
        reasons: result.reasons.iter().map(reason_to_ffi).collect(),
        should_queue: result.should_queue,
    })
}

/// Opaque engine holding the SQLite store + in-memory review queue.
#[derive(uniffi::Object)]
pub struct CleanerEngine {
    inner: Mutex<EngineInner>,
}

struct EngineInner {
    store: Store,
    queue: ReviewQueue,
    weights: FusionWeights,
}

#[uniffi::export]
impl CleanerEngine {
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Self, CleanerError> {
        let store = Store::open(&db_path)?;
        Ok(Self {
            inner: Mutex::new(EngineInner {
                store,
                queue: ReviewQueue::default(),
                weights: FusionWeights::default(),
            }),
        })
    }

    pub fn set_weights_toml(&self, toml: String) -> Result<(), CleanerError> {
        let w = FusionWeights::from_toml(&toml)
            .map_err(|e| CleanerError::Message { msg: e.to_string() })?;
        self.inner.lock().unwrap().weights = w;
        Ok(())
    }

    pub fn upsert_meta(&self, meta: FfiAssetMeta) -> Result<(), CleanerError> {
        self.inner
            .lock()
            .unwrap()
            .store
            .upsert_meta(&meta_from_ffi(&meta))?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn save_fused(
        &self,
        meta: FfiAssetMeta,
        pixel: Option<FfiPixelSignals>,
        face: Option<FfiFaceFeatures>,
        text: Option<FfiTextFeatures>,
        composition: Option<FfiCompositionFeatures>,
        embedding: Option<FfiEmbeddingFeatures>,
        vlm: Option<FfiVlmResult>,
        tier_completed: u8,
    ) -> Result<FfiFusionResult, CleanerError> {
        let fused = fuse_asset(
            meta.clone(),
            pixel.clone(),
            face.clone(),
            text.clone(),
            composition.clone(),
            embedding.clone(),
            vlm.clone(),
            None,
        )?;
        let features = AssetFeatures {
            pixel: pixel.map(|p| cleaner_core::signals::PixelSignals {
                blur_variance: p.blur_variance,
                dark_fraction: p.dark_fraction,
                bright_fraction: p.bright_fraction,
                mean_luminance: p.mean_luminance,
                dhash: p.dhash,
                is_pocket_shot: p.is_pocket_shot,
                uniformity: p.uniformity,
            }),
            face: face.map(|f| FaceFeatures {
                face_count: f.face_count,
                avg_capture_quality: f.avg_capture_quality,
                blink_count: f.blink_count,
                looking_away_count: f.looking_away_count,
                mouth_open_count: f.mouth_open_count,
                any_blink: f.any_blink,
                any_looking_away: f.any_looking_away,
                any_mouth_open: f.any_mouth_open,
            }),
            text: text.map(|t| TextFeatures {
                has_dense_text: t.has_dense_text,
                has_barcode: t.has_barcode,
                has_document: t.has_document,
                text_block_count: t.text_block_count,
                utility_keyword_hits: t.utility_keyword_hits,
            }),
            composition: composition.map(|c| CompositionFeatures {
                subject_placement: c.subject_placement,
                subject_coverage: c.subject_coverage,
                cropped_subject: c.cropped_subject,
            }),
            embedding: embedding.map(|e| EmbeddingFeatures {
                embedding: e.embedding,
                aesthetic_raw: e.aesthetic_raw,
                junk_similarities: e
                    .junk_similarities
                    .into_iter()
                    .map(|j| (j.label, j.similarity))
                    .collect(),
            }),
            vlm: vlm.map(|v| VlmResult {
                category: v.category,
                ephemeral: v.ephemeral,
                reason: v.reason,
                confidence: v.confidence,
            }),
        };
        let record = AssetRecord {
            meta: meta_from_ffi(&meta),
            features,
            scores: Scores {
                junk: fused.scores.junk,
                miss: fused.scores.miss,
                aesthetic: fused.scores.aesthetic,
            },
            reasons: fused
                .reasons
                .iter()
                .map(|r| Reason::new(ReasonKind::Custom, r.detail.clone(), r.confidence))
                .collect(),
            cluster_id: None,
            is_best_in_cluster: false,
            tier_completed,
            analyzed_at: Some(Utc::now()),
        };
        // Preserve proper reason kinds by re-fusing with store path using fusion module directly
        let eng = self.inner.lock().unwrap();
        let proper = fuse_scores(&record.meta, &record.features, &eng.weights);
        let record = AssetRecord {
            scores: proper.scores.clone(),
            reasons: proper.reasons.clone(),
            ..record
        };
        eng.store.save_analysis(&record)?;
        Ok(FfiFusionResult {
            scores: FfiScores {
                junk: proper.scores.junk,
                miss: proper.scores.miss,
                aesthetic: proper.scores.aesthetic,
            },
            reasons: proper.reasons.iter().map(reason_to_ffi).collect(),
            should_queue: proper.should_queue,
        })
    }

    pub fn asset_count(&self) -> Result<u64, CleanerError> {
        Ok(self.inner.lock().unwrap().store.asset_count()?)
    }

    pub fn rebuild_review_queue(&self) -> Result<u32, CleanerError> {
        let mut eng = self.inner.lock().unwrap();
        let q = eng.store.build_review_queue(
            eng.weights.junk_queue_threshold,
            eng.weights.miss_queue_threshold,
        )?;
        let n = q.remaining() as u32;
        eng.queue = q;
        Ok(n)
    }

    pub fn peek_review(&self) -> Option<FfiReviewItem> {
        let eng = self.inner.lock().unwrap();
        eng.queue.peek().map(|i| FfiReviewItem {
            asset_id: i.asset_id.as_str().to_string(),
            scores: FfiScores {
                junk: i.scores.junk,
                miss: i.scores.miss,
                aesthetic: i.scores.aesthetic,
            },
            reasons: i.reasons.iter().map(reason_to_ffi).collect(),
            cluster_id: i.cluster_id.clone(),
            is_best_in_cluster: i.is_best_in_cluster,
            cluster_size: i.cluster_size,
        })
    }

    pub fn decide(&self, decision: FfiDecision) -> Result<Option<String>, CleanerError> {
        let mut eng = self.inner.lock().unwrap();
        let d = match decision {
            FfiDecision::Keep => Decision::Keep,
            FfiDecision::Toss => Decision::Toss,
            FfiDecision::Skip => Decision::Skip,
            FfiDecision::Undo => Decision::Undo,
        };
        let id = eng.queue.decide(d);
        if let Some(ref asset_id) = id {
            if !matches!(d, Decision::Undo) {
                eng.store.record_decision(asset_id, d)?;
            }
        }
        Ok(id.map(|a| a.as_str().to_string()))
    }

    pub fn staged_toss_ids(&self) -> Vec<String> {
        self.inner
            .lock()
            .unwrap()
            .queue
            .tossed
            .iter()
            .map(|a| a.as_str().to_string())
            .collect()
    }

    pub fn take_tossed(&self) -> Vec<String> {
        self.inner
            .lock()
            .unwrap()
            .queue
            .take_tossed()
            .into_iter()
            .map(|a| a.as_str().to_string())
            .collect()
    }

    pub fn remaining_review(&self) -> u32 {
        self.inner.lock().unwrap().queue.remaining() as u32
    }

    pub fn set_change_token(&self, token: String) -> Result<(), CleanerError> {
        self.inner.lock().unwrap().store.set_change_token(&token)?;
        Ok(())
    }

    pub fn get_change_token(&self) -> Result<Option<String>, CleanerError> {
        Ok(self.inner.lock().unwrap().store.get_change_token()?)
    }

    pub fn observe_device(
        &self,
        thermal: FfiThermal,
        power: FfiPower,
        ram_gb: u32,
    ) -> Result<FfiSchedulerSnapshot, CleanerError> {
        let thermal = match thermal {
            FfiThermal::Nominal => ThermalLevel::Nominal,
            FfiThermal::Fair => ThermalLevel::Fair,
            FfiThermal::Serious => ThermalLevel::Serious,
            FfiThermal::Critical => ThermalLevel::Critical,
        };
        let power = match power {
            FfiPower::Battery => PowerState::Battery,
            FfiPower::Charging => PowerState::Charging,
            FfiPower::Full => PowerState::Full,
        };
        let eng = self.inner.lock().unwrap();
        let state = eng.store.observe_and_checkpoint(thermal, power, ram_gb)?;
        Ok(snapshot(&state, power, ram_gb))
    }

    pub fn next_work_batch(
        &self,
        power: FfiPower,
        ram_gb: u32,
    ) -> Result<Option<FfiWorkBatch>, CleanerError> {
        let power = match power {
            FfiPower::Battery => PowerState::Battery,
            FfiPower::Charging => PowerState::Charging,
            FfiPower::Full => PowerState::Full,
        };
        let eng = self.inner.lock().unwrap();
        let state = eng.store.load_scheduler()?;
        let t1 = eng.store.ids_below_tier(1)?;
        let t2 = eng.store.ids_below_tier(2)?;
        let t3 = eng.store.ambiguous_junk_ids(0.35, 0.70)?;
        Ok(state
            .next_batch(&t1, &t2, &t3, power, ram_gb)
            .map(|b| FfiWorkBatch {
                tier: match b.tier {
                    WorkTier::Pixel => FfiWorkTier::Pixel,
                    WorkTier::VisionMl => FfiWorkTier::VisionMl,
                    WorkTier::Vlm => FfiWorkTier::Vlm,
                    WorkTier::Meta => FfiWorkTier::Pixel,
                },
                asset_ids: b
                    .asset_ids
                    .into_iter()
                    .map(|a| a.as_str().to_string())
                    .collect(),
                recommended_batch_size: b.recommended_batch_size,
            }))
    }

    pub fn record_batch_progress(
        &self,
        tier: FfiWorkTier,
        count: u64,
        cursor: Option<String>,
    ) -> Result<(), CleanerError> {
        let eng = self.inner.lock().unwrap();
        let mut state = eng.store.load_scheduler()?;
        let t = match tier {
            FfiWorkTier::Pixel => WorkTier::Pixel,
            FfiWorkTier::VisionMl => WorkTier::VisionMl,
            FfiWorkTier::Vlm => WorkTier::Vlm,
        };
        state.record_progress(t, count, cursor);
        eng.store.save_scheduler(&state)?;
        Ok(())
    }

    /// Re-cluster recently analyzed assets and mark best-of-burst.
    pub fn recluster_recent(&self, limit: u32) -> Result<u32, CleanerError> {
        let eng = self.inner.lock().unwrap();
        // Load up to `limit` records with tier >= 1
        let ids = eng.store.ids_below_tier(99)?; // all non-fav
        let mut records = Vec::new();
        for id in ids.into_iter().take(limit as usize) {
            if let Some(r) = eng.store.get_record(&id)? {
                if r.tier_completed >= 1 {
                    records.push(r);
                }
            }
        }
        drop(eng);

        let clusters = cluster_near_duplicates(&records, &ClusterConfig::default());
        let eng = self.inner.lock().unwrap();
        let mut updated = 0u32;
        for c in clusters {
            let owned: Vec<AssetRecord> = c
                .member_ids
                .iter()
                .filter_map(|id| eng.store.get_record(id).ok().flatten())
                .collect();
            let refs: Vec<&AssetRecord> = owned.iter().collect();
            if let Some(ranked) = rank_cluster(&c.id, &refs) {
                eng.store
                    .update_cluster(&c.id, &c.member_ids, &ranked.best_id)?;
                for (id, reasons) in ranked.reasons_by_id {
                    if let Some(mut rec) = eng.store.get_record(&id)? {
                        rec.reasons = reasons;
                        rec.scores.junk = rec.scores.junk.max(0.6);
                        rec.cluster_id = Some(c.id.clone());
                        rec.is_best_in_cluster = false;
                        eng.store.save_analysis(&rec)?;
                    }
                }
                if let Some(mut best) = eng.store.get_record(&ranked.best_id)? {
                    best.cluster_id = Some(c.id.clone());
                    best.is_best_in_cluster = true;
                    eng.store.save_analysis(&best)?;
                }
                updated += 1;
            }
        }
        Ok(updated)
    }
}

fn snapshot(state: &SchedulerState, power: PowerState, ram_gb: u32) -> FfiSchedulerSnapshot {
    FfiSchedulerSnapshot {
        paused: state.paused,
        pause_reason: state.pause_reason.clone(),
        batch_size: state.batch_size,
        tier1_done: state.tier1_done,
        tier2_done: state.tier2_done,
        tier3_done: state.tier3_done,
        can_run_vlm: state.can_run_vlm(power, ram_gb),
    }
}

/// Default fusion weights as TOML (for Settings / contributors).
#[uniffi::export]
pub fn default_weights_toml() -> String {
    cleaner_core::weights::DEFAULT_WEIGHTS_TOML.to_string()
}

// Silence unused warning in some builds
#[allow(dead_code)]
fn _reason_kind_label(k: &ReasonKind) -> String {
    reason_kind_label(k)
}

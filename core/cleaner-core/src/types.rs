//! Shared domain types for assets, reasons, and scores.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Stable local identifier mirroring PHAsset.localIdentifier.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AssetId(pub String);

impl AssetId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for AssetId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Tier-0 metadata from PhotosKit (no pixel work).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetMeta {
    pub id: AssetId,
    pub created_at: DateTime<Utc>,
    pub is_favorite: bool,
    pub is_hidden: bool,
    pub is_screenshot: bool,
    pub is_burst: bool,
    pub is_live: bool,
    pub burst_id: Option<String>,
    /// Latitude if available.
    pub latitude: Option<f64>,
    /// Longitude if available.
    pub longitude: Option<f64>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// On-disk bytes from PhotoKit resources (0 if unknown).
    pub byte_size: u64,
    /// True when all primary PhotoKit resources are on-device (not Optimize Storage stubs).
    pub is_locally_available: bool,
    /// User-declared secondary backup label (e.g. "Google Photos"). Not device-verified.
    pub secondary_backup_label: Option<String>,
}

/// Human-readable reason a photo was flagged.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReasonKind {
    Blur,
    Underexposed,
    Overexposed,
    PocketShot,
    Screenshot,
    Blink,
    LookingAway,
    MouthOpen,
    ReceiptOrDocument,
    BarcodeOrLabel,
    UtilityJunk,
    NearDuplicate,
    LowerAesthetic,
    VlmEphemeral,
    /// Full-resolution file lives in iCloud (Optimize iPhone Storage).
    CloudOriginal,
    /// User declared a secondary backup (Google Photos / other) — not API-verified.
    SecondaryBackup,
    Custom,
}

impl ReasonKind {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Blur => "Blurry",
            Self::Underexposed => "Too dark",
            Self::Overexposed => "Blown out",
            Self::PocketShot => "Pocket / accidental",
            Self::Screenshot => "Screenshot",
            Self::Blink => "Blink detected",
            Self::LookingAway => "Looking away",
            Self::MouthOpen => "Mouth open (experimental)",
            Self::ReceiptOrDocument => "Looks like a document",
            Self::BarcodeOrLabel => "Barcode / label",
            Self::UtilityJunk => "Utility junk",
            Self::NearDuplicate => "Near duplicate",
            Self::LowerAesthetic => "Better shot exists",
            Self::VlmEphemeral => "Ephemeral utility shot",
            Self::CloudOriginal => "iCloud original",
            Self::SecondaryBackup => "Secondary backup",
            Self::Custom => "Flagged",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reason {
    pub kind: ReasonKind,
    pub detail: String,
    pub confidence: f32,
}

impl Reason {
    pub fn new(kind: ReasonKind, detail: impl Into<String>, confidence: f32) -> Self {
        Self {
            kind,
            detail: detail.into(),
            confidence: confidence.clamp(0.0, 1.0),
        }
    }
}

/// Calibrated scores produced by fusion.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Scores {
    /// Likelihood this is disposable utility junk (0..1).
    pub junk: f32,
    /// Likelihood this is a social "miss" (blink, look-away) (0..1).
    pub miss: f32,
    /// Aesthetic quality (0..1, higher = better).
    pub aesthetic: f32,
}

/// Face analysis features from Vision (Swift → Rust).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FaceFeatures {
    pub face_count: u32,
    pub avg_capture_quality: f32,
    pub blink_count: u32,
    pub looking_away_count: u32,
    pub mouth_open_count: u32,
    pub any_blink: bool,
    pub any_looking_away: bool,
    pub any_mouth_open: bool,
}

/// Text / document / barcode signals from Vision.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TextFeatures {
    pub has_dense_text: bool,
    pub has_barcode: bool,
    pub has_document: bool,
    pub text_block_count: u32,
    /// Heuristic: receipt / wifi / tracking keywords matched.
    pub utility_keyword_hits: u32,
}

/// Composition / saliency features.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CompositionFeatures {
    /// 0..1 how centered the salient subject is (1 = perfect center/rule-of-thirds).
    pub subject_placement: f32,
    pub subject_coverage: f32,
    pub cropped_subject: bool,
}

/// Embedding + aesthetic head outputs from Core ML.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EmbeddingFeatures {
    /// Dense embedding (e.g. 768-d SigLIP). Empty if not yet computed.
    pub embedding: Vec<f32>,
    pub aesthetic_raw: f32,
    /// Per-prompt cosine similarities for zero-shot junk classes.
    pub junk_similarities: Vec<(String, f32)>,
}

/// Optional VLM classification (Tier 3).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VlmResult {
    pub category: String,
    pub ephemeral: bool,
    pub reason: String,
    pub confidence: f32,
}

/// Full feature bag for one asset after analyzers run.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AssetFeatures {
    pub pixel: Option<crate::signals::PixelSignals>,
    pub face: Option<FaceFeatures>,
    pub text: Option<TextFeatures>,
    pub composition: Option<CompositionFeatures>,
    pub embedding: Option<EmbeddingFeatures>,
    pub vlm: Option<VlmResult>,
}

/// Persisted analysis record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetRecord {
    pub meta: AssetMeta,
    pub features: AssetFeatures,
    pub scores: Scores,
    pub reasons: Vec<Reason>,
    pub cluster_id: Option<String>,
    pub is_best_in_cluster: bool,
    pub tier_completed: u8,
    pub analyzed_at: Option<DateTime<Utc>>,
}

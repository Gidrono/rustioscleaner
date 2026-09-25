//! Versioned fusion weights (TOML-tunable without code changes).

use serde::{Deserialize, Serialize};

use crate::types::ReasonKind;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FusionWeights {
    pub version: u32,
    pub blur_junk: f32,
    pub dark_junk: f32,
    pub bright_junk: f32,
    pub pocket_junk: f32,
    pub screenshot_junk: f32,
    pub text_document_junk: f32,
    pub barcode_junk: f32,
    pub zero_shot_junk: f32,
    pub vlm_ephemeral_junk: f32,
    pub blink_miss: f32,
    pub looking_away_miss: f32,
    pub mouth_open_miss: f32,
    pub aesthetic_from_model: f32,
    pub aesthetic_from_sharpness: f32,
    pub aesthetic_from_composition: f32,
    pub aesthetic_from_face_quality: f32,
    /// Thresholds
    pub blur_soft: f32,
    pub blur_hard: f32,
    pub dark_threshold: f32,
    pub bright_threshold: f32,
    pub junk_queue_threshold: f32,
    pub miss_queue_threshold: f32,
    pub experimental_mouth: bool,
}

impl Default for FusionWeights {
    fn default() -> Self {
        Self {
            version: 1,
            blur_junk: 0.55,
            dark_junk: 0.45,
            bright_junk: 0.35,
            pocket_junk: 0.95,
            screenshot_junk: 0.40,
            text_document_junk: 0.70,
            barcode_junk: 0.75,
            zero_shot_junk: 0.65,
            vlm_ephemeral_junk: 0.90,
            blink_miss: 0.85,
            looking_away_miss: 0.70,
            mouth_open_miss: 0.40,
            aesthetic_from_model: 0.55,
            aesthetic_from_sharpness: 0.20,
            aesthetic_from_composition: 0.15,
            aesthetic_from_face_quality: 0.10,
            blur_soft: 80.0,
            blur_hard: 25.0,
            dark_threshold: 0.55,
            bright_threshold: 0.45,
            junk_queue_threshold: 0.55,
            miss_queue_threshold: 0.60,
            experimental_mouth: false,
        }
    }
}

impl FusionWeights {
    pub fn from_toml(s: &str) -> Result<Self, toml::de::Error> {
        toml::from_str(s)
    }

    pub fn to_toml(&self) -> Result<String, toml::ser::Error> {
        toml::to_string_pretty(self)
    }

    pub fn reason_weight(&self, kind: &ReasonKind) -> f32 {
        match kind {
            ReasonKind::Blur => self.blur_junk,
            ReasonKind::Underexposed => self.dark_junk,
            ReasonKind::Overexposed => self.bright_junk,
            ReasonKind::PocketShot => self.pocket_junk,
            ReasonKind::Screenshot => self.screenshot_junk,
            ReasonKind::ReceiptOrDocument => self.text_document_junk,
            ReasonKind::BarcodeOrLabel => self.barcode_junk,
            ReasonKind::UtilityJunk => self.zero_shot_junk,
            ReasonKind::VlmEphemeral => self.vlm_ephemeral_junk,
            ReasonKind::Blink => self.blink_miss,
            ReasonKind::LookingAway => self.looking_away_miss,
            ReasonKind::MouthOpen => self.mouth_open_miss,
            _ => 0.5,
        }
    }
}

/// Bundled default weights as TOML for contributors.
pub const DEFAULT_WEIGHTS_TOML: &str = include_str!("../weights/default.toml");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_roundtrips_toml() {
        let w = FusionWeights::default();
        let s = w.to_toml().unwrap();
        let w2 = FusionWeights::from_toml(&s).unwrap();
        assert_eq!(w.version, w2.version);
        assert!((w.blink_miss - w2.blink_miss).abs() < 1e-6);
    }
}

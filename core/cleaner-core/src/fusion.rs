//! Score fusion: combine analyzer signals into junk / miss / aesthetic + reasons.

use crate::types::{AssetFeatures, AssetMeta, Reason, ReasonKind, Scores};
use crate::weights::FusionWeights;

#[derive(Debug, Clone, serde::Serialize)]
pub struct FusionResult {
    pub scores: Scores,
    pub reasons: Vec<Reason>,
    pub should_queue: bool,
}

/// Fuse metadata + features into calibrated scores.
pub fn fuse_scores(
    meta: &AssetMeta,
    features: &AssetFeatures,
    weights: &FusionWeights,
) -> FusionResult {
    // Never flag favorites or already-hidden assets.
    if meta.is_favorite || meta.is_hidden {
        return FusionResult {
            scores: Scores {
                junk: 0.0,
                miss: 0.0,
                aesthetic: 1.0,
            },
            reasons: vec![],
            should_queue: false,
        };
    }

    let mut reasons = Vec::new();
    let mut junk = 0.0f32;
    let mut miss = 0.0f32;

    // --- Pixel / Tier 1 ---
    if let Some(px) = &features.pixel {
        if px.is_pocket_shot {
            junk = junk.max(weights.pocket_junk);
            reasons.push(Reason::new(
                ReasonKind::PocketShot,
                "Near-uniform / accidental capture",
                weights.pocket_junk,
            ));
        }
        if px.blur_variance < weights.blur_hard {
            let c = weights.blur_junk;
            junk = junk.max(c * 0.9);
            reasons.push(Reason::new(
                ReasonKind::Blur,
                format!("Very blurry (laplacian {:.1})", px.blur_variance),
                c,
            ));
        } else if px.blur_variance < weights.blur_soft {
            let c = weights.blur_junk * 0.6;
            junk = junk.max(c);
            reasons.push(Reason::new(
                ReasonKind::Blur,
                format!("Soft focus (laplacian {:.1})", px.blur_variance),
                c,
            ));
        }
        if px.dark_fraction > weights.dark_threshold {
            junk = junk.max(weights.dark_junk);
            reasons.push(Reason::new(
                ReasonKind::Underexposed,
                format!("{:.0}% near-black pixels", px.dark_fraction * 100.0),
                weights.dark_junk,
            ));
        }
        if px.bright_fraction > weights.bright_threshold {
            junk = junk.max(weights.bright_junk);
            reasons.push(Reason::new(
                ReasonKind::Overexposed,
                format!("{:.0}% clipped highlights", px.bright_fraction * 100.0),
                weights.bright_junk,
            ));
        }
    }

    if meta.is_screenshot {
        // Screenshots are soft junk — still useful sometimes.
        junk = junk.max(weights.screenshot_junk * 0.5);
        reasons.push(Reason::new(
            ReasonKind::Screenshot,
            "Device screenshot",
            weights.screenshot_junk * 0.5,
        ));
    }

    // --- Text / document ---
    if let Some(tx) = &features.text {
        if tx.has_document || tx.utility_keyword_hits > 0 {
            let c = weights.text_document_junk;
            junk = junk.max(c);
            reasons.push(Reason::new(
                ReasonKind::ReceiptOrDocument,
                "Document / receipt-like text",
                c,
            ));
        }
        if tx.has_barcode {
            junk = junk.max(weights.barcode_junk);
            reasons.push(Reason::new(
                ReasonKind::BarcodeOrLabel,
                "Barcode or QR detected",
                weights.barcode_junk,
            ));
        }
    }

    // --- Zero-shot junk from embedding ---
    if let Some(emb) = &features.embedding {
        if let Some((label, sim)) = emb
            .junk_similarities
            .iter()
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
        {
            if *sim > 0.28 {
                let c = (weights.zero_shot_junk * sim.clamp(0.0, 1.0)).min(0.95);
                junk = junk.max(c);
                reasons.push(Reason::new(
                    ReasonKind::UtilityJunk,
                    format!("Looks like: {label}"),
                    c,
                ));
            }
        }
    }

    // --- VLM ---
    if let Some(vlm) = &features.vlm {
        if vlm.ephemeral {
            let c = weights.vlm_ephemeral_junk * vlm.confidence.clamp(0.0, 1.0);
            junk = junk.max(c);
            reasons.push(Reason::new(
                ReasonKind::VlmEphemeral,
                format!("{} — {}", vlm.category, vlm.reason),
                c,
            ));
        }
    }

    // --- Faces / miss ---
    if let Some(face) = &features.face {
        if face.any_blink {
            miss = miss.max(weights.blink_miss);
            reasons.push(Reason::new(
                ReasonKind::Blink,
                format!("{} face(s) mid-blink", face.blink_count.max(1)),
                weights.blink_miss,
            ));
        }
        if face.any_looking_away {
            miss = miss.max(weights.looking_away_miss);
            reasons.push(Reason::new(
                ReasonKind::LookingAway,
                format!("{} face(s) looking away", face.looking_away_count.max(1)),
                weights.looking_away_miss,
            ));
        }
        if weights.experimental_mouth && face.any_mouth_open {
            miss = miss.max(weights.mouth_open_miss);
            reasons.push(Reason::new(
                ReasonKind::MouthOpen,
                "Mouth open / mid-chew (experimental)",
                weights.mouth_open_miss,
            ));
        }
    }

    // --- Aesthetic ---
    let aesthetic = compute_aesthetic(features, weights);

    let scores = Scores {
        junk: junk.clamp(0.0, 1.0),
        miss: miss.clamp(0.0, 1.0),
        aesthetic: aesthetic.clamp(0.0, 1.0),
    };

    // Optimize Storage: full-res is in iCloud Photos (not a separate backup).
    // Informational only — deleting still removes the iCloud original.
    if !meta.is_locally_available {
        reasons.push(Reason::new(
            ReasonKind::CloudOriginal,
            "Full-res in iCloud Photos (Optimize Storage)",
            0.55,
        ));
    }

    // User-declared secondary backup (Google Photos / other). Softens queue threshold.
    let backup_slack = 0.08f32;
    if let Some(label) = meta.secondary_backup_label.as_deref() {
        let label = label.trim();
        if !label.is_empty() {
            let has_substantive_reason = reasons
                .iter()
                .any(|r| r.kind != ReasonKind::CloudOriginal);
            let nearly_queued = scores.junk >= weights.junk_queue_threshold - backup_slack
                || scores.miss >= weights.miss_queue_threshold - backup_slack
                || has_substantive_reason;
            if nearly_queued {
                reasons.push(Reason::new(
                    ReasonKind::SecondaryBackup,
                    format!("You said you also back up to {label}"),
                    0.5,
                ));
            }
        }
    }

    let has_secondary = meta
        .secondary_backup_label
        .as_deref()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    let junk_thresh = if has_secondary {
        (weights.junk_queue_threshold - backup_slack).max(0.35)
    } else {
        weights.junk_queue_threshold
    };
    let miss_thresh = if has_secondary {
        (weights.miss_queue_threshold - backup_slack).max(0.40)
    } else {
        weights.miss_queue_threshold
    };

    let should_queue = scores.junk >= junk_thresh || scores.miss >= miss_thresh;

    FusionResult {
        scores,
        reasons,
        should_queue,
    }
}

fn compute_aesthetic(features: &AssetFeatures, weights: &FusionWeights) -> f32 {
    let mut score = 0.5f32;
    let mut wsum = 0.0f32;

    if let Some(emb) = &features.embedding {
        // aesthetic_raw expected in roughly 0..1 or 1..10; normalize softly.
        let a = if emb.aesthetic_raw > 1.5 {
            ((emb.aesthetic_raw - 1.0) / 9.0).clamp(0.0, 1.0)
        } else {
            emb.aesthetic_raw.clamp(0.0, 1.0)
        };
        score += a * weights.aesthetic_from_model;
        wsum += weights.aesthetic_from_model;
    }

    if let Some(px) = &features.pixel {
        // Map blur variance to 0..1 with soft saturation.
        let sharp = (px.blur_variance / 200.0).clamp(0.0, 1.0);
        // Penalize extreme exposure.
        let exposure_ok = 1.0 - (px.dark_fraction + px.bright_fraction).min(1.0) * 0.5;
        let s = sharp * 0.7 + exposure_ok * 0.3;
        score += s * weights.aesthetic_from_sharpness;
        wsum += weights.aesthetic_from_sharpness;
    }

    if let Some(comp) = &features.composition {
        let mut c = comp.subject_placement * 0.6 + comp.subject_coverage.clamp(0.0, 1.0) * 0.4;
        if comp.cropped_subject {
            c *= 0.7;
        }
        score += c * weights.aesthetic_from_composition;
        wsum += weights.aesthetic_from_composition;
    }

    if let Some(face) = &features.face {
        if face.face_count > 0 {
            score += face.avg_capture_quality.clamp(0.0, 1.0) * weights.aesthetic_from_face_quality;
            wsum += weights.aesthetic_from_face_quality;
        }
    }

    if wsum > 0.0 {
        // Re-center: we added weighted components onto 0.5 base; normalize.
        let weighted = (score - 0.5) / wsum.max(1e-6);
        // Mix base with weighted contribution
        (0.35 + weighted * 0.65).clamp(0.0, 1.0)
    } else {
        0.5
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::PixelSignals;
    use crate::types::{AssetId, AssetMeta};
    use chrono::Utc;

    fn meta() -> AssetMeta {
        AssetMeta {
            id: AssetId::new("a1"),
            created_at: Utc::now(),
            is_favorite: false,
            is_hidden: false,
            is_screenshot: false,
            is_burst: false,
            is_live: false,
            burst_id: None,
            latitude: None,
            longitude: None,
            pixel_width: 100,
            pixel_height: 100,
            byte_size: 0,
            is_locally_available: true,
            secondary_backup_label: None,
        }
    }

    #[test]
    fn cloud_original_is_informational() {
        let mut m = meta();
        m.is_locally_available = false;
        let r = fuse_scores(&m, &AssetFeatures::default(), &FusionWeights::default());
        assert!(!r.should_queue);
        assert!(r.reasons.iter().any(|x| x.kind == ReasonKind::CloudOriginal));
    }

    #[test]
    fn secondary_backup_softens_threshold() {
        use crate::types::FaceFeatures;
        let mut m = meta();
        m.secondary_backup_label = Some("Google Photos".into());
        // miss just below default miss_queue_threshold (0.60) but above 0.60 - 0.08
        let features = AssetFeatures {
            face: Some(FaceFeatures {
                face_count: 1,
                any_looking_away: true,
                looking_away_count: 1,
                avg_capture_quality: 0.5,
                ..Default::default()
            }),
            ..Default::default()
        };
        // looking_away_miss default 0.70 → should_queue with or without backup;
        // use a custom soft miss below default threshold.
        let mut weights = FusionWeights::default();
        weights.looking_away_miss = 0.55; // below default miss_queue_threshold 0.60
        let without = {
            let mut plain = meta();
            plain.secondary_backup_label = None;
            fuse_scores(&plain, &features, &weights)
        };
        let with = fuse_scores(&m, &features, &weights);
        assert!(!without.should_queue);
        assert!(with.should_queue);
        assert!(with
            .reasons
            .iter()
            .any(|x| x.kind == ReasonKind::SecondaryBackup));
    }

    #[test]
    fn favorite_never_queued() {
        let mut m = meta();
        m.is_favorite = true;
        let r = fuse_scores(&m, &AssetFeatures::default(), &FusionWeights::default());
        assert!(!r.should_queue);
        assert_eq!(r.scores.junk, 0.0);
    }

    #[test]
    fn pocket_shot_queues() {
        let features = AssetFeatures {
            pixel: Some(PixelSignals {
                is_pocket_shot: true,
                uniformity: 0.99,
                blur_variance: 1.0,
                ..Default::default()
            }),
            ..Default::default()
        };
        let r = fuse_scores(&meta(), &features, &FusionWeights::default());
        assert!(r.should_queue);
        assert!(r.scores.junk > 0.8);
        assert!(r.reasons.iter().any(|x| x.kind == ReasonKind::PocketShot));
    }

    #[test]
    fn blink_sets_miss() {
        use crate::types::FaceFeatures;
        let features = AssetFeatures {
            face: Some(FaceFeatures {
                face_count: 2,
                any_blink: true,
                blink_count: 1,
                avg_capture_quality: 0.5,
                ..Default::default()
            }),
            ..Default::default()
        };
        let r = fuse_scores(&meta(), &features, &FusionWeights::default());
        assert!(r.should_queue);
        assert!(r.scores.miss > 0.7);
    }
}

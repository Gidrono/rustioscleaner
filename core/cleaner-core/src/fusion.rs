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

    let should_queue =
        scores.junk >= weights.junk_queue_threshold || scores.miss >= weights.miss_queue_threshold;

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
        }
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

//! Best-shot ranking within a near-duplicate / burst cluster.

use serde::{Deserialize, Serialize};

use crate::types::{AssetId, AssetRecord, Reason, ReasonKind};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RankedCluster {
    pub cluster_id: String,
    pub best_id: AssetId,
    /// Members suggested for toss (everyone except best), sorted worst-first.
    pub toss_ids: Vec<AssetId>,
    pub reasons_by_id: Vec<(AssetId, Vec<Reason>)>,
}

/// Rank = aesthetic + face_quality + sharpness - miss_penalty.
pub fn rank_cluster(cluster_id: &str, members: &[&AssetRecord]) -> Option<RankedCluster> {
    if members.len() < 2 {
        return None;
    }

    let mut scored: Vec<(usize, f32)> = members
        .iter()
        .enumerate()
        .map(|(i, r)| (i, composite_rank(r)))
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let best_idx = scored[0].0;
    let best_id = members[best_idx].meta.id.clone();
    let best_score = scored[0].1;

    let mut toss_ids = Vec::new();
    let mut reasons_by_id = Vec::new();

    for &(idx, score) in scored.iter().skip(1) {
        let id = members[idx].meta.id.clone();
        let delta = best_score - score;
        let mut reasons = members[idx].reasons.clone();
        reasons.push(Reason::new(
            ReasonKind::LowerAesthetic,
            format!(
                "{} better shot(s) in this burst (Δ{:.2})",
                1, // at least the best
                delta
            ),
            (0.5 + delta * 0.4).clamp(0.0, 1.0),
        ));
        reasons.push(Reason::new(
            ReasonKind::NearDuplicate,
            format!("Near duplicate of {}", best_id.as_str()),
            0.8,
        ));
        toss_ids.push(id.clone());
        reasons_by_id.push((id, reasons));
    }

    // Worst first for review UX (clear losers first).
    toss_ids.reverse();
    reasons_by_id.reverse();

    Some(RankedCluster {
        cluster_id: cluster_id.to_string(),
        best_id,
        toss_ids,
        reasons_by_id,
    })
}

fn composite_rank(r: &AssetRecord) -> f32 {
    let aesthetic = r.scores.aesthetic;
    let face_q = r
        .features
        .face
        .as_ref()
        .map(|f| {
            if f.face_count > 0 {
                f.avg_capture_quality.clamp(0.0, 1.0)
            } else {
                0.5
            }
        })
        .unwrap_or(0.5);
    let sharpness = r
        .features
        .pixel
        .as_ref()
        .map(|p| (p.blur_variance / 200.0).clamp(0.0, 1.0))
        .unwrap_or(0.5);
    let miss_penalty = r.scores.miss;

    aesthetic * 0.45 + face_q * 0.20 + sharpness * 0.20 - miss_penalty * 0.35
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::PixelSignals;
    use crate::types::{AssetFeatures, AssetMeta, FaceFeatures, Scores};
    use chrono::Utc;

    fn make(id: &str, aesthetic: f32, blur: f32, miss: f32, face_q: f32) -> AssetRecord {
        AssetRecord {
            meta: AssetMeta {
                id: AssetId::new(id),
                created_at: Utc::now(),
                is_favorite: false,
                is_hidden: false,
                is_screenshot: false,
                is_burst: true,
                is_live: false,
                burst_id: Some("b1".into()),
                latitude: None,
                longitude: None,
                pixel_width: 100,
                pixel_height: 100,
            },
            features: AssetFeatures {
                pixel: Some(PixelSignals {
                    blur_variance: blur,
                    ..Default::default()
                }),
                face: Some(FaceFeatures {
                    face_count: 1,
                    avg_capture_quality: face_q,
                    ..Default::default()
                }),
                ..Default::default()
            },
            scores: Scores {
                junk: 0.0,
                miss,
                aesthetic,
            },
            reasons: vec![],
            cluster_id: Some("c1".into()),
            is_best_in_cluster: false,
            tier_completed: 2,
            analyzed_at: None,
        }
    }

    #[test]
    fn picks_highest_aesthetic_not_just_sharpest() {
        let sharp_ugly = make("sharp", 0.3, 300.0, 0.0, 0.4);
        let soft_pretty = make("pretty", 0.9, 90.0, 0.0, 0.9);
        let mid = make("mid", 0.5, 150.0, 0.0, 0.5);
        let refs: Vec<&AssetRecord> = vec![&sharp_ugly, &soft_pretty, &mid];
        let ranked = rank_cluster("c1", &refs).unwrap();
        assert_eq!(ranked.best_id.as_str(), "pretty");
        assert_eq!(ranked.toss_ids.len(), 2);
    }

    #[test]
    fn miss_penalized() {
        let good = make("good", 0.7, 100.0, 0.0, 0.8);
        let blink = make("blink", 0.75, 100.0, 0.9, 0.8);
        let ranked = rank_cluster("c1", &[&good, &blink]).unwrap();
        assert_eq!(ranked.best_id.as_str(), "good");
    }
}

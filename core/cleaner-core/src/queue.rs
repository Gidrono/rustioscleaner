//! Review queue: keep / toss / skip decisions and staged deletes.

use serde::{Deserialize, Serialize};

use crate::types::{AssetId, Reason, Scores};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Decision {
    Keep,
    Toss,
    Skip,
    Undo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewItem {
    pub asset_id: AssetId,
    pub scores: Scores,
    pub reasons: Vec<Reason>,
    pub cluster_id: Option<String>,
    pub is_best_in_cluster: bool,
    /// Sibling count in cluster (for "4 better shots" UI).
    pub cluster_size: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReviewQueue {
    pub pending: Vec<ReviewItem>,
    pub tossed: Vec<AssetId>,
    pub kept: Vec<AssetId>,
    pub skipped: Vec<AssetId>,
    history: Vec<(AssetId, Decision)>,
}

impl ReviewQueue {
    pub fn new(items: Vec<ReviewItem>) -> Self {
        Self {
            pending: items,
            ..Default::default()
        }
    }

    pub fn remaining(&self) -> usize {
        self.pending.len()
    }

    pub fn peek(&self) -> Option<&ReviewItem> {
        self.pending.first()
    }

    pub fn decide(&mut self, decision: Decision) -> Option<AssetId> {
        if matches!(decision, Decision::Undo) {
            return self.undo();
        }
        let item = self.pending.first()?.clone();
        let id = item.asset_id.clone();
        self.pending.remove(0);
        match decision {
            Decision::Keep => self.kept.push(id.clone()),
            Decision::Toss => self.tossed.push(id.clone()),
            Decision::Skip => self.skipped.push(id.clone()),
            Decision::Undo => unreachable!(),
        }
        self.history.push((id.clone(), decision));
        Some(id)
    }

    pub fn undo(&mut self) -> Option<AssetId> {
        let (id, decision) = self.history.pop()?;
        match decision {
            Decision::Keep => {
                self.kept.retain(|x| x != &id);
            }
            Decision::Toss => {
                self.tossed.retain(|x| x != &id);
            }
            Decision::Skip => {
                self.skipped.retain(|x| x != &id);
            }
            Decision::Undo => {}
        }
        // Re-insert at front; we don't have the full ReviewItem here — caller should
        // restore via store. We only track id for staging lists.
        Some(id)
    }

    /// Drain staged toss list for a batched PHAssetChangeRequest.deleteAssets.
    pub fn take_tossed(&mut self) -> Vec<AssetId> {
        std::mem::take(&mut self.tossed)
    }

    pub fn staged_toss_count(&self) -> usize {
        self.tossed.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Scores;

    fn item(id: &str) -> ReviewItem {
        ReviewItem {
            asset_id: AssetId::new(id),
            scores: Scores::default(),
            reasons: vec![],
            cluster_id: None,
            is_best_in_cluster: false,
            cluster_size: 1,
        }
    }

    #[test]
    fn swipe_keep_toss_undo() {
        let mut q = ReviewQueue::new(vec![item("a"), item("b")]);
        assert_eq!(q.decide(Decision::Toss).unwrap().as_str(), "a");
        assert_eq!(q.staged_toss_count(), 1);
        assert_eq!(q.decide(Decision::Keep).unwrap().as_str(), "b");
        assert!(q.peek().is_none());
        let undone = q.undo().unwrap();
        assert_eq!(undone.as_str(), "b");
        assert!(q.kept.is_empty());
    }
}

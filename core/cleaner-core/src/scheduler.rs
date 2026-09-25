//! Background scan scheduler: tiers, thermal throttling, checkpointing.

use serde::{Deserialize, Serialize};

use crate::types::AssetId;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkTier {
    /// Metadata only (already done at ingest).
    Meta = 0,
    /// Pixel signals in Rust.
    Pixel = 1,
    /// Vision + Core ML on Neural Engine.
    VisionMl = 2,
    /// VLM via MLX — charging only.
    Vlm = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ThermalLevel {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PowerState {
    Battery,
    Charging,
    Full,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulerState {
    pub last_asset_cursor: Option<String>,
    pub tier1_done: u64,
    pub tier2_done: u64,
    pub tier3_done: u64,
    pub paused: bool,
    pub pause_reason: Option<String>,
    pub batch_size: u32,
}

impl Default for SchedulerState {
    fn default() -> Self {
        Self {
            last_asset_cursor: None,
            tier1_done: 0,
            tier2_done: 0,
            tier3_done: 0,
            paused: false,
            pause_reason: None,
            batch_size: 32,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkBatch {
    pub tier: WorkTier,
    pub asset_ids: Vec<AssetId>,
    pub recommended_batch_size: u32,
}

impl SchedulerState {
    /// Decide whether work may proceed and at what batch size.
    pub fn observe_device(&mut self, thermal: ThermalLevel, power: PowerState, ram_gb: u32) {
        match thermal {
            ThermalLevel::Critical | ThermalLevel::Serious => {
                self.paused = true;
                self.pause_reason = Some(format!("thermal:{thermal:?}"));
                self.batch_size = 4;
                return;
            }
            ThermalLevel::Fair => {
                self.batch_size = self.batch_size.min(16);
            }
            ThermalLevel::Nominal => {
                self.batch_size = 32;
            }
        }

        // Resume if we were paused only for thermals and now OK.
        if self.paused
            && self
                .pause_reason
                .as_deref()
                .is_some_and(|r| r.starts_with("thermal:"))
        {
            self.paused = false;
            self.pause_reason = None;
        }

        // VLM requires charging + enough RAM; enforced when selecting tier.
        let _ = (power, ram_gb);
    }

    pub fn can_run_vlm(&self, power: PowerState, ram_gb: u32) -> bool {
        !self.paused && ram_gb >= 6 && matches!(power, PowerState::Charging | PowerState::Full)
    }

    pub fn next_batch(
        &self,
        pending_tier1: &[AssetId],
        pending_tier2: &[AssetId],
        pending_tier3: &[AssetId],
        power: PowerState,
        ram_gb: u32,
    ) -> Option<WorkBatch> {
        if self.paused {
            return None;
        }
        let n = self.batch_size as usize;
        if !pending_tier1.is_empty() {
            return Some(WorkBatch {
                tier: WorkTier::Pixel,
                asset_ids: pending_tier1.iter().take(n).cloned().collect(),
                recommended_batch_size: self.batch_size,
            });
        }
        if !pending_tier2.is_empty() {
            return Some(WorkBatch {
                tier: WorkTier::VisionMl,
                asset_ids: pending_tier2.iter().take(n).cloned().collect(),
                recommended_batch_size: self.batch_size,
            });
        }
        if !pending_tier3.is_empty() && self.can_run_vlm(power, ram_gb) {
            // VLM is slower — smaller batches.
            let vn = (self.batch_size / 4).max(1) as usize;
            return Some(WorkBatch {
                tier: WorkTier::Vlm,
                asset_ids: pending_tier3.iter().take(vn).cloned().collect(),
                recommended_batch_size: vn as u32,
            });
        }
        None
    }

    pub fn record_progress(&mut self, tier: WorkTier, count: u64, cursor: Option<String>) {
        match tier {
            WorkTier::Meta => {}
            WorkTier::Pixel => self.tier1_done += count,
            WorkTier::VisionMl => self.tier2_done += count,
            WorkTier::Vlm => self.tier3_done += count,
        }
        if cursor.is_some() {
            self.last_asset_cursor = cursor;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pauses_on_serious_thermal() {
        let mut s = SchedulerState::default();
        s.observe_device(ThermalLevel::Serious, PowerState::Charging, 8);
        assert!(s.paused);
        assert!(s
            .next_batch(&[AssetId::new("a")], &[], &[], PowerState::Charging, 8)
            .is_none());
    }

    #[test]
    fn vlm_requires_charging() {
        let s = SchedulerState::default();
        assert!(!s.can_run_vlm(PowerState::Battery, 8));
        assert!(s.can_run_vlm(PowerState::Charging, 8));
        assert!(!s.can_run_vlm(PowerState::Charging, 4));
    }

    #[test]
    fn prefers_tier1_then_tier2() {
        let s = SchedulerState::default();
        let b = s
            .next_batch(
                &[AssetId::new("a")],
                &[AssetId::new("b")],
                &[AssetId::new("c")],
                PowerState::Charging,
                8,
            )
            .unwrap();
        assert_eq!(b.tier, WorkTier::Pixel);
    }
}

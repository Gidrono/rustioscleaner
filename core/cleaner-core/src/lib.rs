//! Cleaner core: types, pixel signals, score fusion, clustering, ranking, queue & scheduler.

pub mod cluster;
pub mod fusion;
pub mod queue;
pub mod ranker;
pub mod scheduler;
pub mod signals;
pub mod types;
pub mod weights;

pub use cluster::{cluster_near_duplicates, ClusterConfig, PhotoCluster};
pub use fusion::{fuse_scores, FusionResult};
pub use queue::{Decision, ReviewItem, ReviewQueue};
pub use ranker::{rank_cluster, RankedCluster};
pub use scheduler::{SchedulerState, ThermalLevel, WorkBatch, WorkTier};
pub use signals::{analyze_rgba, PixelSignals};
pub use types::*;
pub use weights::FusionWeights;

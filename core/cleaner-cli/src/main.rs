//! Desktop harness: run fusion / clustering on feature JSON dumps.

use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use cleaner_core::cluster::{cluster_near_duplicates, ClusterConfig};
use cleaner_core::fusion::fuse_scores;
use cleaner_core::ranker::rank_cluster;
use cleaner_core::types::AssetRecord;
use cleaner_core::weights::FusionWeights;

#[derive(Parser)]
#[command(name = "cleaner-cli", about = "Evaluate fusion & clustering offline")]
struct Cli {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Fuse a single AssetRecord JSON file and print scores.
    Fuse {
        #[arg(value_name = "FILE")]
        path: PathBuf,
        #[arg(long)]
        weights: Option<PathBuf>,
    },
    /// Cluster a JSON array of AssetRecords.
    Cluster {
        #[arg(value_name = "FILE")]
        path: PathBuf,
    },
    /// Rank clusters from a JSON array of AssetRecords.
    Rank {
        #[arg(value_name = "FILE")]
        path: PathBuf,
    },
    /// Print default weights TOML.
    Weights,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let cli = Cli::parse();
    match cli.cmd {
        Commands::Fuse { path, weights } => {
            let raw = fs::read_to_string(&path).context("read record")?;
            let record: AssetRecord = serde_json::from_str(&raw)?;
            let w = load_weights(weights)?;
            let result = fuse_scores(&record.meta, &record.features, &w);
            println!("{}", serde_json::to_string_pretty(&result.scores)?);
            for r in result.reasons {
                println!("- [{}] {} ({:.2})", r.kind.label(), r.detail, r.confidence);
            }
            println!("should_queue={}", result.should_queue);
        }
        Commands::Cluster { path } => {
            let records: Vec<AssetRecord> = serde_json::from_str(&fs::read_to_string(path)?)?;
            let clusters = cluster_near_duplicates(&records, &ClusterConfig::default());
            println!("{}", serde_json::to_string_pretty(&clusters)?);
        }
        Commands::Rank { path } => {
            let records: Vec<AssetRecord> = serde_json::from_str(&fs::read_to_string(path)?)?;
            let clusters = cluster_near_duplicates(&records, &ClusterConfig::default());
            for c in clusters {
                let owned: Vec<&AssetRecord> = c
                    .member_ids
                    .iter()
                    .filter_map(|id| records.iter().find(|r| &r.meta.id == id))
                    .collect();
                if let Some(ranked) = rank_cluster(&c.id, &owned) {
                    println!("{}", serde_json::to_string_pretty(&ranked)?);
                }
            }
        }
        Commands::Weights => {
            print!("{}", cleaner_core::weights::DEFAULT_WEIGHTS_TOML);
        }
    }
    Ok(())
}

fn load_weights(path: Option<PathBuf>) -> Result<FusionWeights> {
    match path {
        Some(p) => Ok(FusionWeights::from_toml(&fs::read_to_string(p)?)?),
        None => Ok(FusionWeights::default()),
    }
}

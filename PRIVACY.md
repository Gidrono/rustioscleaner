# Privacy Policy — RustCleaner

**Last updated:** 2026-09-24

RustCleaner is a privacy-first, open-source iOS app. This document is the source of truth for what the app does with your data.

## Data collection

**We collect no personal data.** There are no analytics SDKs, no crash reporters that upload photos, no accounts, and no ads.

The App Privacy Manifest (`PrivacyInfo.xcprivacy`) declares **Data Not Collected**.

## What stays on your iPhone

| Data | Location | Purpose |
|---|---|---|
| Photo analysis scores & reasons | Local SQLite in Application Support | Drive the Keep/Toss queue |
| Keep / Toss / Skip decisions | Local SQLite | Personalize thresholds on-device |
| Scheduler checkpoints | Local SQLite | Resume scans after suspension |
| Optional VLM weights | Application Support / VLM | Tier-3 semantic classification |

Photos are read via Apple’s Photos framework and are **never** uploaded.

## Deletes

When you confirm a batch toss, the app calls `PHAssetChangeRequest.deleteAssets`. Photos move to **Recently Deleted** and remain recoverable for 30 days (Apple’s policy).

## Network

The app contains **one** optional network path:

1. You tap **Download open-source VLM weights** in Settings.
2. Weights are fetched from a pinned Hugging Face revision listed in `vlm_manifest.json`.
3. The file’s **SHA256** must match the manifest or the install is aborted.

No other telemetry or API calls are made.

## Permissions

- **Photo Library (read/write):** required to analyze and to move tossed items to Recently Deleted.
- **Background processing:** used only for charging-time scans (`requiresExternalPower = true`).

## Contact

Open an issue on the project repository. This is a community project; there is no corporate data processor.

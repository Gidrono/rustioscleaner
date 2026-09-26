import Analyzers
import BackgroundTasks
import Combine
import Foundation
import PhotoBridge
import SwiftUI
import UIKit
import VLM

/// Central app state: PhotoKit ingest, cascade analysis, review queue, deletes.
@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    @Published var authStatusDescription = "Not determined"
    @Published var assetCount: UInt64 = 0
    @Published var reviewRemaining: UInt32 = 0
    @Published var currentCard: ReviewCard?
    @Published var stagedTossCount = 0
    /// Photos deleted during the current review visit (after successful commits).
    @Published var sessionDeletedCount = 0
    /// Approximate bytes freed during the current review visit.
    @Published var sessionFreedBytes: Int64 = 0
    /// Latest successful delete batch; drives the cleaned-summary sheet.
    @Published var lastCleanResult: CleanResult?
    /// True while PhotoKit delete confirmation / commit is in flight.
    @Published var isCommittingDeletes = false
    @Published var isScanning = false
    @Published var scanProgress: String = ""
    /// Non-error status after a scan completes (shown as an info alert, not "Something went wrong").
    @Published var scanFinishedMessage: String?
    /// Root tab selection (0 Home, 1 Review, 2 Scan, 3 Settings).
    @Published var selectedTab = 0
    @Published var thermalLabel = "nominal"
    @Published var powerLabel = "battery"
    @Published var canRunVLM = false
    @Published var vlmInstalled = false
    @Published var lastError: String?
    @Published var showOnboarding = false
    @Published var cardImage: UIImage?
    /// True when the current card’s PhotoKit load finished without an image.
    @Published var cardImageLoadFailed = false

    /// True when the user granted Limited Photos access (needs picker to add new shots).
    var photosAccessIsLimited: Bool {
        photos.authorizationStatus == .limited
    }

    /// User-declared secondary backups (not API-verified). Softens queue thresholds.
    @Published var backsUpGooglePhotos: Bool {
        didSet { UserDefaults.standard.set(backsUpGooglePhotos, forKey: Self.googlePhotosKey) }
    }
    @Published var backsUpOther: Bool {
        didSet { UserDefaults.standard.set(backsUpOther, forKey: Self.otherBackupKey) }
    }

    /// What to look for / show in review. User picks these before starting a scan.
    @Published var scanCategories: ScanCategorySet {
        didSet {
            scanCategories.save()
            guard engine != nil else { return }
            applyCategoryFilterToEngine()
            rebuildQueue()
        }
    }

    private static let googlePhotosKey = "backup.googlePhotos"
    private static let otherBackupKey = "backup.other"
    private static let hasScannedKey = "scan.hasUserStarted"

    private var engine: CleanerEngine?
    private let photos = PhotoLibraryService.shared
    /// Shared bootstrap ingest so Start scan never races an empty DB.
    private var ingestTask: Task<Void, Never>?
    private var cardLoadGeneration: UInt64 = 0
    private var hasUserStartedScan: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasScannedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasScannedKey) }
    }

    struct ReasonChip: Identifiable, Hashable {
        var id: String { "\(kind)|\(detail)" }
        let kind: String
        let detail: String
        /// Short label shown in the chip (no raw asset UUIDs).
        let title: String
        let relatedAssetId: String?
    }

    struct ReviewCard: Identifiable {
        var id: String { assetId }
        let assetId: String
        let reasons: [ReasonChip]
        let junk: Float
        let miss: Float
        let aesthetic: Float
        let clusterSize: UInt32
    }

    /// Result of one successful delete commit (for the summary sheet).
    struct CleanResult: Identifiable {
        let id = UUID()
        let deletedCount: Int
        let freedBytes: Int64
        let sessionDeletedCount: Int
        let sessionFreedBytes: Int64
    }

    /// Pixel size for the review card image on the current screen.
    static var reviewDisplaySize: CGSize {
        let scale = UIScreen.main.scale
        let width = UIScreen.main.bounds.width * scale
        let height = 420 * scale
        return CGSize(width: width, height: height)
    }

    init() {
        backsUpGooglePhotos = UserDefaults.standard.bool(forKey: Self.googlePhotosKey)
        backsUpOther = UserDefaults.standard.bool(forKey: Self.otherBackupKey)
        scanCategories = ScanCategorySet.load()
    }

    /// Seeds review UI state without PhotoKit / Rust. Used by layout overflow tests.
    func seedReviewLayoutFixture(
        remaining: UInt32 = 172,
        stagedCount: Int = 0,
        junk: Float = 0,
        miss: Float = 0.7,
        aesthetic: Float = 0.73,
        reasonTitles: [String] = [
            "Similar photos (3)",
            "Looks like: a photo of a package tracking slip"
        ]
    ) {
        reviewRemaining = remaining
        stagedTossCount = stagedCount
        cardImage = UIImage(systemName: "photo")
        cardImageLoadFailed = false
        currentCard = ReviewCard(
            assetId: "layout-fixture",
            reasons: reasonTitles.enumerated().map { index, title in
                ReasonChip(
                    kind: "Fixture",
                    detail: title,
                    title: title,
                    relatedAssetId: index == 0 ? "related-fixture" : nil
                )
            },
            junk: junk,
            miss: miss,
            aesthetic: aesthetic,
            clusterSize: 3
        )
    }

    /// Label stamped onto asset meta for fusion (nil when no secondary backup declared).
    var secondaryBackupLabel: String? {
        var parts: [String] = []
        if backsUpGooglePhotos { parts.append("Google Photos") }
        if backsUpOther { parts.append("another backup") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " + ")
    }

    private func ffiMeta(from snap: PhotoLibraryService.AssetSnapshot) -> FfiAssetMeta {
        FfiAssetMeta(
            id: snap.localIdentifier,
            createdAtUnix: Int64(snap.createdAt.timeIntervalSince1970),
            isFavorite: snap.isFavorite,
            isHidden: snap.isHidden,
            isScreenshot: snap.isScreenshot,
            isBurst: snap.isBurst,
            isLive: snap.isLive,
            burstId: snap.burstIdentifier,
            latitude: snap.latitude,
            longitude: snap.longitude,
            pixelWidth: UInt32(snap.pixelWidth),
            pixelHeight: UInt32(snap.pixelHeight),
            byteSize: UInt64(max(0, snap.byteSize)),
            isLocallyAvailable: snap.isLocallyAvailable,
            secondaryBackupLabel: secondaryBackupLabel
        )
    }

    func bootstrap() {
        vlmInstalled = VLMModelManager.shared.isInstalled
        ensureEngine()
        refreshDevice()
        if hasUserStartedScan {
            BackgroundScanScheduler.schedule()
        }
        ingestTask = Task {
            let status = await photos.requestAuthorization()
            authStatusDescription = String(describing: status)
            if status == .authorized || status == .limited {
                showOnboarding = false
                await ingestLibrary(limit: nil)
            } else {
                showOnboarding = true
            }
        }
    }

    /// Re-request Photos access (from the permission onboarding card).
    func requestPhotoAccess() async {
        let status = await photos.requestAuthorization()
        authStatusDescription = String(describing: status)
        switch status {
        case .authorized:
            showOnboarding = false
            await refreshPhotoLibrary()
        case .limited:
            showOnboarding = false
            await presentLimitedLibraryPickerIfNeeded()
            await refreshPhotoLibrary()
        case .denied, .restricted:
            showOnboarding = true
            openSystemPhotoSettings()
            lastError = "Photo access is off. Enable Context Cleaner in Settings → Privacy → Photos, then return here."
        default:
            showOnboarding = true
            lastError = "Photo access is required to scan your library."
        }
    }

    /// Re-index the current library and drop deleted / unselected photo IDs from the work queue.
    func refreshPhotoLibrary() async {
        scanProgress = "Refreshing photo index…"
        let wasScanning = isScanning
        if !wasScanning { isScanning = true }
        defer {
            if !wasScanning { isScanning = false }
            if scanProgress == "Refreshing photo index…" { scanProgress = "" }
        }
        await ingestLibrary(limit: nil, pruneMissing: true)
    }

    /// Let the user add newly taken photos when using Limited Photos access.
    func updateLimitedPhotoSelection() async {
        let status = photos.authorizationStatus
        if status == .notDetermined {
            await requestPhotoAccess()
            return
        }
        if status == .denied || status == .restricted {
            openSystemPhotoSettings()
            return
        }
        if status == .limited {
            await presentLimitedLibraryPickerIfNeeded()
        }
        await refreshPhotoLibrary()
    }

    private func presentLimitedLibraryPickerIfNeeded() async {
        guard photos.authorizationStatus == .limited else { return }
        await photos.presentLimitedLibraryPicker()
    }

    private func openSystemPhotoSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func ensureIngested() async {
        if let ingestTask {
            await ingestTask.value
        }
        let status = photos.authorizationStatus
        guard status == .authorized || status == .limited else { return }
        // Always re-index: users delete/take photos between launches.
        await ingestLibrary(limit: nil, pruneMissing: true)
    }

    private func ensureEngine() {
        if engine != nil { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("cleaner.sqlite").path
        do {
            engine = try CleanerEngine(dbPath: db)
            applyCategoryFilterToEngine()
        } catch {
            lastError = "Engine: \(error.localizedDescription)"
        }
    }

    private func applyCategoryFilterToEngine() {
        engine?.setReviewCategoryLabels(labels: scanCategories.enabledReasonLabels())
    }

    func refreshDevice() {
        let thermal = mapThermal(DeviceRuntime.currentThermal())
        let power = mapPower(DeviceRuntime.currentPower())
        let ram = DeviceRuntime.ramGB()
        thermalLabel = DeviceRuntime.currentThermal().rawValue
        powerLabel = DeviceRuntime.currentPower().rawValue
        if let snap = try? engine?.observeDevice(thermal: thermal, power: power, ramGb: ram) {
            canRunVLM = snap.canRunVlm
        }
    }

    /// Index PhotoKit metadata only — does not run analysis. Analysis starts when the user taps Start scan.
    func ingestLibrary(limit: Int?, pruneMissing: Bool = false) async {
        let snapshots = photos.enumerateImageAssets(limit: limit)
        let liveIds = Set(snapshots.map(\.localIdentifier))
        for snap in snapshots {
            try? engine?.upsertMeta(meta: ffiMeta(from: snap))
        }
        if pruneMissing {
            await pruneUnreachablePendingAssets(liveIds: liveIds)
        }
        // Show how many photos PhotoKit currently exposes (not stale SQLite rows).
        assetCount = UInt64(liveIds.count)
        rebuildQueue()
    }

    /// Mark pending SQLite rows that are no longer in the live PhotoKit set so scans don't stall.
    private func pruneUnreachablePendingAssets(liveIds: Set<String>) async {
        guard engine != nil else { return }
        refreshDevice()
        let power = mapPower(DeviceRuntime.currentPower())
        var guardCount = 0
        while guardCount < 40 {
            guardCount += 1
            guard let batch = try? engine?.nextWorkBatch(power: power, ramGb: DeviceRuntime.ramGB()),
                  !batch.assetIds.isEmpty
            else { break }
            let missing = batch.assetIds.filter { !liveIds.contains($0) }
            if missing.isEmpty { break }
            for id in missing {
                await markAssetUnreachable(id: id)
            }
        }
    }

    /// User-initiated scan after picking categories.
    func startScan(maxAssets: Int = 500) async {
        guard scanCategories.hasAnyEnabled else {
            lastError = "Pick at least one category to scan for."
            return
        }
        isScanning = true
        scanProgress = "Indexing photos…"
        await ensureIngested()

        let status = photos.authorizationStatus
        guard status == .authorized || status == .limited else {
            isScanning = false
            scanProgress = ""
            showOnboarding = true
            lastError = "Photo access is required to scan your library."
            return
        }
        guard engine != nil else {
            isScanning = false
            scanProgress = ""
            lastError = lastError ?? "Couldn’t start the analysis engine."
            return
        }
        guard assetCount > 0 else {
            isScanning = false
            scanProgress = ""
            lastError = "No photos found in your library."
            return
        }

        hasUserStartedScan = true
        BackgroundScanScheduler.schedule()
        applyCategoryFilterToEngine()
        await runCascade(maxAssets: maxAssets, alreadyScanning: true, announceCompletion: true)
    }

    func runCascade(maxAssets: Int, alreadyScanning: Bool = false, announceCompletion: Bool = false) async {
        refreshDevice()
        if !alreadyScanning {
            isScanning = true
        }
        defer { isScanning = false }
        guard engine != nil else {
            lastError = lastError ?? "Couldn’t start the analysis engine."
            scanProgress = ""
            return
        }

        scanProgress = "Analyzing…"
        var processed = 0
        var skipped = 0
        var missingAsset = 0
        var imageLoadFailed = 0
        var gotBatch = false
        var failedIds = Set<String>()

        while processed + skipped < maxAssets {
            refreshDevice()
            let power = mapPower(DeviceRuntime.currentPower())
            let batch: FfiWorkBatch
            do {
                guard let engine,
                      let b = try engine.nextWorkBatch(power: power, ramGb: DeviceRuntime.ramGB()),
                      !b.assetIds.isEmpty
                else { break }
                batch = b
                gotBatch = true
            } catch {
                lastError = "Scan failed: \(error.localizedDescription)"
                break
            }

            var batchAnalyzed: UInt64 = 0
            var progressedThisBatch = false

            // Clear stale/limited-library IDs before spending time on image loads.
            let reachable = batch.assetIds.filter { photos.asset(for: $0) != nil }
            let missing = batch.assetIds.filter { photos.asset(for: $0) == nil }
            for id in missing where !failedIds.contains(id) {
                await markAssetUnreachable(id: id)
                failedIds.insert(id)
                missingAsset += 1
                skipped += 1
                progressedThisBatch = true
            }
            if reachable.isEmpty {
                if batch.assetIds.allSatisfy({ failedIds.contains($0) }) { break }
                continue
            }

            for id in reachable {
                if failedIds.contains(id) {
                    skipped += 1
                    continue
                }
                let result = await analyzeOne(id: id, tier: batch.tier)
                progressedThisBatch = true
                switch result {
                case .analyzed:
                    processed += 1
                    batchAnalyzed += 1
                case .missingAsset:
                    missingAsset += 1
                    skipped += 1
                    failedIds.insert(id)
                case .imageUnavailable:
                    imageLoadFailed += 1
                    skipped += 1
                    failedIds.insert(id)
                case .engineUnavailable:
                    skipped += 1
                    failedIds.insert(id)
                }
                let tierLabel = String(describing: batch.tier)
                if skipped > 0 {
                    scanProgress = "Analyzed \(processed) · skipped \(skipped) · \(tierLabel)"
                } else {
                    scanProgress = "Analyzed \(processed) · \(tierLabel)"
                }
                if processed + skipped >= maxAssets { break }
            }
            // Avoid spinning forever on the same unloadable ids.
            if !progressedThisBatch, batch.assetIds.allSatisfy({ failedIds.contains($0) }) {
                break
            }
            try? engine?.recordBatchProgress(
                tier: batch.tier,
                count: batchAnalyzed,
                cursor: batch.assetIds.last
            )
        }
        _ = try? engine?.reclusterRecent(limit: 2000)
        rebuildQueue()

        if !gotBatch {
            // Already indexed / analyzed — still acknowledge a user tap so it doesn't feel dead.
            scanProgress = ""
            if announceCompletion {
                scanFinishedMessage = Self.scanFinishedCopy(
                    processed: 0,
                    reviewRemaining: reviewRemaining,
                    assetCount: assetCount,
                    alreadyCaughtUp: true
                )
            }
        } else if processed == 0 && skipped > 0 {
            if missingAsset > 0 && imageLoadFailed == 0 {
                if photos.authorizationStatus == .limited {
                    // Show the “Choose more photos” card on Home.
                    showOnboarding = true
                    lastError = "Those photos aren’t in your allowed set. Tap Choose more photos, then Start scan again."
                } else {
                    await refreshPhotoLibrary()
                    lastError = "Your library changed (deleted or new photos). Index refreshed — tap Start scan again."
                }
            } else if imageLoadFailed > 0 {
                lastError = "Couldn’t decode \(imageLoadFailed) photo\(imageLoadFailed == 1 ? "" : "s") for analysis. If photos are in iCloud only, open Photos once to download them, then try again."
            } else {
                lastError = "Couldn’t load photo data for analysis. Check Photos access and try again."
            }
        } else if announceCompletion {
            scanProgress = ""
            scanFinishedMessage = Self.scanFinishedCopy(
                processed: processed,
                reviewRemaining: reviewRemaining,
                assetCount: assetCount,
                alreadyCaughtUp: false
            )
        }
    }

    private static func scanFinishedCopy(
        processed: Int,
        reviewRemaining: UInt32,
        assetCount: UInt64,
        alreadyCaughtUp: Bool
    ) -> String {
        if reviewRemaining > 0 {
            let n = reviewRemaining
            return "Scan finished — \(n) suggestion\(n == 1 ? "" : "s") ready for review."
        }
        if alreadyCaughtUp {
            return assetCount > 0
                ? "Scan finished. Nothing new to analyze — you’re caught up. Plug in for a deeper scan if you want more coverage."
                : "Scan finished. No photos to analyze."
        }
        if processed > 0 {
            return "Scan finished. No cleanup suggestions for your selected categories."
        }
        return "Scan finished."
    }

    /// Switch to the Review tab (Home CTA / post-scan alert).
    func openReview() {
        selectedTab = 1
    }

    func runForegroundChargingScan() async {
        refreshDevice()
        guard DeviceRuntime.currentPower() != .battery else {
            lastError = "Plug in your iPhone to run the deep scan (saves battery)."
            return
        }
        await startScan(maxAssets: 2000)
    }

    func runBackgroundScan(task: BGProcessingTask) async {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        await runCascade(maxAssets: 400)
        BackgroundScanScheduler.schedule()
        task.setTaskCompleted(success: true)
    }

    private enum AnalyzeOutcome {
        case analyzed
        case missingAsset
        case imageUnavailable
        case engineUnavailable
    }

    /// Attempts analysis; marks stale/unavailable assets so they leave the work queue.
    private func analyzeOne(id: String, tier: FfiWorkTier) async -> AnalyzeOutcome {
        guard let engine else { return .engineUnavailable }

        guard let asset = photos.asset(for: id) else {
            // Limited-library / deleted IDs stay in SQLite otherwise and block every scan.
            await markAssetUnreachable(id: id)
            return .missingAsset
        }

        guard let rgba = await photos.requestRGBAThumbnail(for: asset, maxPixel: 256) else {
            return .imageUnavailable
        }

        let snap = PhotoLibraryService.snapshot(from: asset)
        let meta = ffiMeta(from: snap)

        var pixel: FfiPixelSignals?
        var face: FfiFaceFeatures?
        var text: FfiTextFeatures?
        var composition: FfiCompositionFeatures?
        var embedding: FfiEmbeddingFeatures?
        var vlm: FfiVlmResult?
        var completed: UInt8 = 1

        let rgbaData = Data(rgba.rgba)
        if let signals = try? analyzeThumbnail(width: rgba.width, height: rgba.height, rgba: rgbaData) {
            pixel = signals
        }

        if tier == .visionMl || tier == .vlm {
            if let image = await photos.requestThumbnail(for: asset, maxPixel: 512),
               let cg = PhotoLibraryService.cgImage(from: image)
            {
                if let f = try? await VisionAnalyzers.analyzeFaces(cgImage: cg) {
                    face = FfiFaceFeatures(
                        faceCount: f.faceCount,
                        avgCaptureQuality: f.avgCaptureQuality,
                        blinkCount: f.blinkCount,
                        lookingAwayCount: f.lookingAwayCount,
                        mouthOpenCount: f.mouthOpenCount,
                        anyBlink: f.anyBlink,
                        anyLookingAway: f.anyLookingAway,
                        anyMouthOpen: f.anyMouthOpen
                    )
                }
                if let t = try? await VisionAnalyzers.analyzeText(cgImage: cg) {
                    text = FfiTextFeatures(
                        hasDenseText: t.hasDenseText,
                        hasBarcode: t.hasBarcode,
                        hasDocument: t.hasDocument,
                        textBlockCount: t.textBlockCount,
                        utilityKeywordHits: t.utilityKeywordHits
                    )
                }
                if let c = try? await VisionAnalyzers.analyzeComposition(cgImage: cg) {
                    composition = FfiCompositionFeatures(
                        subjectPlacement: c.subjectPlacement,
                        subjectCoverage: c.subjectCoverage,
                        croppedSubject: c.croppedSubject
                    )
                }
                if let e = try? EmbeddingAnalyzer.shared.analyze(cgImage: cg) {
                    embedding = FfiEmbeddingFeatures(
                        embedding: e.embedding,
                        aestheticRaw: e.aestheticRaw,
                        junkSimilarities: e.junkSimilarities.map {
                            FfiJunkSimilarity(label: $0.0, similarity: $0.1)
                        }
                    )
                }
                completed = 2
            }
        }

        if tier == .vlm, canRunVLM {
            if let image = await photos.requestThumbnail(for: asset, maxPixel: 384),
               let data = image.jpegData(compressionQuality: 0.85)
            {
                let runner = VLMModelManager.shared.makeRunner()
                if let cls = try? await runner.classify(imageJPEG: data) {
                    vlm = FfiVlmResult(
                        category: cls.category,
                        ephemeral: cls.ephemeral,
                        reason: cls.reason,
                        confidence: cls.confidence
                    )
                    completed = 3
                }
            }
        }

        _ = try? engine.saveFused(
            meta: meta,
            pixel: pixel,
            face: face,
            text: text,
            composition: composition,
            embedding: embedding,
            vlm: vlm,
            tierCompleted: completed
        )
        return .analyzed
    }

    /// Drop unreachable IDs out of the pending work queue (tier ≥ 2, hidden).
    private func markAssetUnreachable(id: String) async {
        guard let engine else { return }
        let meta = FfiAssetMeta(
            id: id,
            createdAtUnix: 0,
            isFavorite: false,
            isHidden: true,
            isScreenshot: false,
            isBurst: false,
            isLive: false,
            burstId: nil,
            latitude: nil,
            longitude: nil,
            pixelWidth: 0,
            pixelHeight: 0,
            byteSize: 0,
            isLocallyAvailable: false,
            secondaryBackupLabel: nil
        )
        _ = try? engine.saveFused(
            meta: meta,
            pixel: nil,
            face: nil,
            text: nil,
            composition: nil,
            embedding: nil,
            vlm: nil,
            tierCompleted: 2
        )
    }

    func rebuildQueue() {
        applyCategoryFilterToEngine()
        reviewRemaining = (try? engine?.rebuildReviewQueue()) ?? 0
        refreshCard()
        stagedTossCount = engine?.stagedTossIds().count ?? 0
        assetCount = (try? engine?.assetCount()) ?? assetCount
    }

    func toggleCategory(_ category: ScanCategory) {
        var next = scanCategories
        next.toggle(category)
        scanCategories = next
    }

    func refreshCard() {
        // Skip assets PhotoKit can no longer resolve (deleted / limited-library gaps)
        // instead of stranding the user on "Couldn't load photo".
        var drainedMissing = 0
        while let front = engine?.peekReview(), photos.asset(for: front.assetId) == nil {
            _ = try? engine?.decide(decision: .skip)
            drainedMissing += 1
            if drainedMissing >= 64 { break }
        }
        if drainedMissing > 0 {
            reviewRemaining = engine?.remainingReview() ?? 0
            stagedTossCount = engine?.stagedTossIds().count ?? stagedTossCount
        }

        guard let item = engine?.peekReview() else {
            currentCard = nil
            cardImage = nil
            cardImageLoadFailed = false
            cardLoadGeneration += 1
            return
        }
        let displaySize = Self.reviewDisplaySize
        currentCard = ReviewCard(
            assetId: item.assetId,
            reasons: Self.mapReasonChips(item.reasons, clusterSize: item.clusterSize),
            junk: item.scores.junk,
            miss: item.scores.miss,
            aesthetic: item.scores.aesthetic,
            clusterSize: item.clusterSize
        )
        photos.startCaching(identifiers: [item.assetId], size: displaySize)
        let assetId = item.assetId
        cardLoadGeneration += 1
        let generation = cardLoadGeneration
        // Clear so the card shows a spinner instead of the previous photo while loading.
        cardImage = nil
        cardImageLoadFailed = false
        Task {
            guard generation == self.cardLoadGeneration else { return }
            guard let asset = photos.asset(for: assetId) else {
                // Race: asset disappeared after peek — advance without flashing failure.
                guard generation == self.cardLoadGeneration else { return }
                _ = try? self.engine?.decide(decision: .skip)
                self.reviewRemaining = self.engine?.remainingReview() ?? 0
                self.refreshCard()
                return
            }
            let applyPreview: (UIImage) -> Void = { preview in
                Task { @MainActor in
                    guard generation == self.cardLoadGeneration, self.currentCard?.assetId == assetId else { return }
                    // Never let a late nil-result overwrite a frame that already arrived.
                    self.cardImage = preview
                    self.cardImageLoadFailed = false
                }
            }
            let image = await photos.requestDisplayImage(
                for: asset,
                targetSize: displaySize,
                onUpdate: applyPreview
            )
            guard generation == self.cardLoadGeneration, self.currentCard?.assetId == assetId else { return }
            if let image {
                self.cardImage = image
                self.cardImageLoadFailed = false
            } else if self.cardImage == nil {
                // Last-chance small thumb before showing the failure state.
                if let thumb = await photos.requestThumbnail(for: asset, maxPixel: 512) {
                    guard generation == self.cardLoadGeneration, self.currentCard?.assetId == assetId else { return }
                    self.cardImage = thumb
                    self.cardImageLoadFailed = false
                } else if self.cardImage == nil {
                    self.cardImageLoadFailed = true
                }
            }
        }
    }

    /// Load a high-quality image for a related (better / near-duplicate) asset.
    func loadRelatedImage(assetId: String, onUpdate: ((UIImage) -> Void)? = nil) async -> UIImage? {
        guard let asset = photos.asset(for: assetId) else { return nil }
        return await photos.requestDisplayImage(
            for: asset,
            targetSize: Self.reviewDisplaySize,
            onUpdate: onUpdate
        )
    }

    private static let clusterReasonKinds: Set<String> = [
        "Near duplicate",
        "Better shot exists",
    ]

    private static func mapReasonChips(_ reasons: [FfiReason], clusterSize: UInt32) -> [ReasonChip] {
        let bestId = reasons
            .first { $0.kind == "Near duplicate" }
            .flatMap { parseNearDuplicateAssetId(from: $0.detail) }

        var chips: [ReasonChip] = []

        // Collapse better-shot + near-duplicate into one plural, tappable line.
        if reasons.contains(where: { clusterReasonKinds.contains($0.kind) }), let bestId {
            let count = max(Int(clusterSize), 2)
            let title = "\(count) similar photos — tap for best"
            chips.append(
                ReasonChip(
                    kind: "Similar photos",
                    detail: title,
                    title: title,
                    relatedAssetId: bestId
                )
            )
        }

        for reason in reasons where !clusterReasonKinds.contains(reason.kind) {
            chips.append(
                ReasonChip(
                    kind: reason.kind,
                    detail: reason.detail,
                    title: reason.detail.isEmpty ? reason.kind : reason.detail,
                    relatedAssetId: nil
                )
            )
        }
        return chips
    }

    private static func parseNearDuplicateAssetId(from detail: String) -> String? {
        let prefix = "Near duplicate of "
        guard detail.hasPrefix(prefix) else { return nil }
        let id = String(detail.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    func decide(_ decision: FfiDecision) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        _ = try? engine?.decide(decision: decision)
        stagedTossCount = engine?.stagedTossIds().count ?? 0
        reviewRemaining = engine?.remainingReview() ?? 0
        refreshCard()
    }

    /// Reset per-visit cleaned totals when entering review.
    func resetSessionCleanStats() {
        sessionDeletedCount = 0
        sessionFreedBytes = 0
        lastCleanResult = nil
    }

    func dismissCleanResult() {
        lastCleanResult = nil
    }

    func commitDeletes() async {
        // Peek first so a failed/cancelled PhotoKit prompt keeps staging intact.
        let ids = engine?.stagedTossIds() ?? []
        guard !ids.isEmpty else { return }
        isCommittingDeletes = true
        defer { isCommittingDeletes = false }
        let bytes = photos.totalByteSize(identifiers: ids)
        do {
            try await photos.deleteAssets(identifiers: ids)
            _ = engine?.takeTossed()
            stagedTossCount = 0
            sessionDeletedCount += ids.count
            sessionFreedBytes += bytes
            lastCleanResult = CleanResult(
                deletedCount: ids.count,
                freedBytes: bytes,
                sessionDeletedCount: sessionDeletedCount,
                sessionFreedBytes: sessionFreedBytes
            )
        } catch {
            lastError = error.localizedDescription
            stagedTossCount = engine?.stagedTossIds().count ?? stagedTossCount
        }
    }

    private func mapThermal(_ t: DeviceRuntime.Thermal) -> FfiThermal {
        switch t {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }

    private func mapPower(_ p: DeviceRuntime.Power) -> FfiPower {
        switch p {
        case .battery: return .battery
        case .charging: return .charging
        case .full: return .full
        }
    }
}

// MARK: - Scan categories

enum ScanCategory: String, CaseIterable, Identifiable {
    case duplicates
    case utilityJunk
    case socialMisses
    case quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: return "Duplicates & better shots"
        case .utilityJunk: return "Utility junk"
        case .socialMisses: return "Social misses"
        case .quality: return "Blurry / exposure"
        }
    }

    var subtitle: String {
        switch self {
        case .duplicates: return "Near-duplicates and weaker shots in a burst"
        case .utilityJunk: return "Screenshots, receipts, pocket shots, labels"
        case .socialMisses: return "Blinks, looking away, mouth open"
        case .quality: return "Blurry, too dark, or blown out"
        }
    }

    var systemImage: String {
        switch self {
        case .duplicates: return "square.on.square"
        case .utilityJunk: return "trash"
        case .socialMisses: return "person.crop.circle.badge.exclamationmark"
        case .quality: return "camera.metering.unknown"
        }
    }

    /// Matches `ReasonKind::label()` in the Rust core.
    var reasonLabels: [String] {
        switch self {
        case .duplicates:
            return ["Near duplicate", "Better shot exists"]
        case .utilityJunk:
            return [
                "Pocket / accidental",
                "Screenshot",
                "Looks like a document",
                "Barcode / label",
                "Utility junk",
                "Ephemeral utility shot",
            ]
        case .socialMisses:
            return ["Blink detected", "Looking away", "Mouth open (experimental)"]
        case .quality:
            return ["Blurry", "Too dark", "Blown out"]
        }
    }
}

struct ScanCategorySet: Equatable {
    var duplicates: Bool
    var utilityJunk: Bool
    var socialMisses: Bool
    var quality: Bool

    static let `default` = ScanCategorySet(
        duplicates: true,
        utilityJunk: true,
        socialMisses: true,
        quality: true
    )

    private static let prefix = "scan.category."

    static func load() -> ScanCategorySet {
        let d = UserDefaults.standard
        func flag(_ key: String, fallback: Bool) -> Bool {
            if d.object(forKey: Self.prefix + key) == nil { return fallback }
            return d.bool(forKey: Self.prefix + key)
        }
        return ScanCategorySet(
            duplicates: flag(ScanCategory.duplicates.rawValue, fallback: true),
            utilityJunk: flag(ScanCategory.utilityJunk.rawValue, fallback: true),
            socialMisses: flag(ScanCategory.socialMisses.rawValue, fallback: true),
            quality: flag(ScanCategory.quality.rawValue, fallback: true)
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(duplicates, forKey: Self.prefix + ScanCategory.duplicates.rawValue)
        d.set(utilityJunk, forKey: Self.prefix + ScanCategory.utilityJunk.rawValue)
        d.set(socialMisses, forKey: Self.prefix + ScanCategory.socialMisses.rawValue)
        d.set(quality, forKey: Self.prefix + ScanCategory.quality.rawValue)
    }

    var hasAnyEnabled: Bool {
        duplicates || utilityJunk || socialMisses || quality
    }

    private var allEnabled: Bool {
        duplicates && utilityJunk && socialMisses && quality
    }

    func isEnabled(_ category: ScanCategory) -> Bool {
        switch category {
        case .duplicates: return duplicates
        case .utilityJunk: return utilityJunk
        case .socialMisses: return socialMisses
        case .quality: return quality
        }
    }

    mutating func toggle(_ category: ScanCategory) {
        switch category {
        case .duplicates: duplicates.toggle()
        case .utilityJunk: utilityJunk.toggle()
        case .socialMisses: socialMisses.toggle()
        case .quality: quality.toggle()
        }
    }

    /// Empty = no filter (all categories). Otherwise only matching reason labels.
    func enabledReasonLabels() -> [String] {
        guard hasAnyEnabled else { return ["__none__"] }
        if allEnabled { return [] }
        return ScanCategory.allCases
            .filter { isEnabled($0) }
            .flatMap(\.reasonLabels)
    }
}

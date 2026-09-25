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
    @Published var isScanning = false
    @Published var scanProgress: String = ""
    @Published var thermalLabel = "nominal"
    @Published var powerLabel = "battery"
    @Published var canRunVLM = false
    @Published var vlmInstalled = false
    @Published var lastError: String?
    @Published var showOnboarding = false
    @Published var cardImage: UIImage?

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
        Task {
            let status = await photos.requestAuthorization()
            authStatusDescription = String(describing: status)
            if status == .authorized || status == .limited {
                await ingestLibrary(limit: nil)
            } else {
                showOnboarding = true
            }
        }
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
    func ingestLibrary(limit: Int?) async {
        let snapshots = photos.enumerateImageAssets(limit: limit)
        for snap in snapshots {
            try? engine?.upsertMeta(meta: ffiMeta(from: snap))
        }
        assetCount = (try? engine?.assetCount()) ?? UInt64(snapshots.count)
        rebuildQueue()
    }

    /// User-initiated scan after picking categories.
    func startScan(maxAssets: Int = 500) async {
        guard scanCategories.hasAnyEnabled else {
            lastError = "Pick at least one category to scan for."
            return
        }
        hasUserStartedScan = true
        BackgroundScanScheduler.schedule()
        applyCategoryFilterToEngine()
        await runCascade(maxAssets: maxAssets)
    }

    func runCascade(maxAssets: Int) async {
        refreshDevice()
        isScanning = true
        defer { isScanning = false }
        guard engine != nil else { return }
        var processed = 0

        while processed < maxAssets {
            refreshDevice()
            let power = mapPower(DeviceRuntime.currentPower())
            let batch: FfiWorkBatch
            do {
                guard let engine,
                      let b = try engine.nextWorkBatch(power: power, ramGb: DeviceRuntime.ramGB()),
                      !b.assetIds.isEmpty
                else { break }
                batch = b
            } catch {
                break
            }

            for id in batch.assetIds {
                await analyzeOne(id: id, tier: batch.tier)
                processed += 1
                scanProgress = "Analyzed \(processed) · \(String(describing: batch.tier))"
                if processed >= maxAssets { break }
            }
            try? engine?.recordBatchProgress(
                tier: batch.tier,
                count: UInt64(batch.assetIds.count),
                cursor: batch.assetIds.last
            )
        }
        _ = try? engine?.reclusterRecent(limit: 2000)
        rebuildQueue()
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

    private func analyzeOne(id: String, tier: FfiWorkTier) async {
        guard let engine,
              let asset = photos.asset(for: id),
              let rgba = await photos.requestRGBAThumbnail(for: asset, maxPixel: 256)
        else { return }

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
               let cg = image.cgImage
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
        guard let item = engine?.peekReview() else {
            currentCard = nil
            cardImage = nil
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
        Task {
            guard let asset = photos.asset(for: assetId) else { return }
            let image = await photos.requestDisplayImage(for: asset, targetSize: displaySize)
            if currentCard?.assetId == assetId {
                cardImage = image
            }
        }
    }

    /// Load a high-quality image for a related (better / near-duplicate) asset.
    func loadRelatedImage(assetId: String) async -> UIImage? {
        guard let asset = photos.asset(for: assetId) else { return nil }
        return await photos.requestDisplayImage(for: asset, targetSize: Self.reviewDisplaySize)
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

    func commitDeletes() async {
        let ids = engine?.takeTossed() ?? []
        guard !ids.isEmpty else { return }
        do {
            try await photos.deleteAssets(identifiers: ids)
            stagedTossCount = 0
        } catch {
            lastError = error.localizedDescription
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

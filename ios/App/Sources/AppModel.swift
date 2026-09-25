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

    private var engine: CleanerEngine?
    private let photos = PhotoLibraryService.shared

    struct ReviewCard: Identifiable {
        var id: String { assetId }
        let assetId: String
        let reasons: [String]
        let junk: Float
        let miss: Float
        let aesthetic: Float
        let clusterSize: UInt32
    }

    func bootstrap() {
        vlmInstalled = VLMModelManager.shared.isInstalled
        ensureEngine()
        refreshDevice()
        BackgroundScanScheduler.schedule()
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
        } catch {
            lastError = "Engine: \(error.localizedDescription)"
        }
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

    func ingestLibrary(limit: Int?) async {
        isScanning = true
        scanProgress = "Indexing library…"
        defer { isScanning = false }

        let snapshots = photos.enumerateImageAssets(limit: limit)
        var i = 0
        for snap in snapshots {
            let meta = FfiAssetMeta(
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
                pixelHeight: UInt32(snap.pixelHeight)
            )
            try? engine?.upsertMeta(meta: meta)
            i += 1
            if i % 100 == 0 {
                scanProgress = "Indexed \(i)/\(snapshots.count)"
            }
        }
        assetCount = (try? engine?.assetCount()) ?? UInt64(snapshots.count)
        scanProgress = "Running fast scan…"
        await runCascade(maxAssets: min(snapshots.count, 500))
        rebuildQueue()
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
        await runCascade(maxAssets: 2000)
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
        let meta = FfiAssetMeta(
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
            pixelHeight: UInt32(snap.pixelHeight)
        )

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
        reviewRemaining = (try? engine?.rebuildReviewQueue()) ?? 0
        refreshCard()
        stagedTossCount = engine?.stagedTossIds().count ?? 0
        assetCount = (try? engine?.assetCount()) ?? assetCount
    }

    func refreshCard() {
        guard let item = engine?.peekReview() else {
            currentCard = nil
            cardImage = nil
            return
        }
        currentCard = ReviewCard(
            assetId: item.assetId,
            reasons: item.reasons.map { "\($0.kind): \($0.detail)" },
            junk: item.scores.junk,
            miss: item.scores.miss,
            aesthetic: item.scores.aesthetic,
            clusterSize: item.clusterSize
        )
        photos.startCaching(identifiers: [item.assetId], size: CGSize(width: 800, height: 800))
        Task {
            if let asset = photos.asset(for: item.assetId) {
                cardImage = await photos.requestThumbnail(for: asset, maxPixel: 900)
            }
        }
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

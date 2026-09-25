import Foundation

/// MLX Swift VLM wrapper for Tier-3 semantic junk classification.
///
/// Models (SmolVLM2 / Qwen2.5-VL 4-bit, Apache/MIT only) are downloaded opt-in
/// via `VLMModelManager`. Inference is gated to charging + ≥6GB RAM by the Rust scheduler.
///
/// This package deliberately does not hard-depend on `mlx-swift` so the app
/// builds in CI without Metal GPU. When MLX is linked (see Package.resolved in app),
/// set `VLM_MLX_ENABLED` and provide a concrete runner.
public protocol VLMRunner: Sendable {
    func classify(imageJPEG: Data) async throws -> VLMClassification
}

public struct VLMClassification: Sendable, Codable {
    public var category: String
    public var ephemeral: Bool
    public var reason: String
    public var confidence: Float

    public init(category: String, ephemeral: Bool, reason: String, confidence: Float) {
        self.category = category
        self.ephemeral = ephemeral
        self.reason = reason
        self.confidence = confidence
    }
}

/// Constrained prompt that asks for a single JSON object.
public enum VLMPrompt {
    public static let system = """
    You classify smartphone photos for a privacy-first cleaner.
    Reply with ONLY compact JSON: {"category":"...","ephemeral":true|false,"reason":"...","confidence":0.0-1.0}
    ephemeral=true for utility junk: parking pillars, wifi labels, whiteboards, tracking slips, meme screenshots, receipts, accidental pocket shots.
    ephemeral=false for personal memories, portraits, pets, landscapes, food worth keeping.
    """
}

/// Stub runner used until weights are downloaded / MLX is wired.
public struct StubVLMRunner: VLMRunner {
    public init() {}
    public func classify(imageJPEG: Data) async throws -> VLMClassification {
        // Conservative: never mark ephemeral without a real model.
        _ = imageJPEG
        return VLMClassification(
            category: "unknown",
            ephemeral: false,
            reason: "VLM model not installed",
            confidence: 0.0
        )
    }
}

/// Downloads & verifies VLM weights (only network path in the app).
public final class VLMModelManager: @unchecked Sendable {
    public static let shared = VLMModelManager()

    public struct Manifest: Codable, Sendable {
        public var repo: String
        public var revision: String
        public var filename: String
        public var sha256: String
        public var license: String
        public var minRamGB: UInt32
    }

    public private(set) var isInstalled: Bool = false
    public private(set) var manifest: Manifest?

    private let fileManager = FileManager.default

    public var modelsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VLM", isDirectory: true)
    }

    public init() {
        refreshInstalled()
        if let url = Bundle.main.url(forResource: "vlm_manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let m = try? JSONDecoder().decode(Manifest.self, from: data)
        {
            manifest = m
        }
    }

    public func refreshInstalled() {
        let marker = modelsDirectory.appendingPathComponent(".ready")
        isInstalled = fileManager.fileExists(atPath: marker.path)
    }

    /// Opt-in download with SHA256 verification. Call only after explicit user consent.
    public func downloadIfNeeded(
        from remoteURL: URL,
        expectedSHA256: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let dest = modelsDirectory.appendingPathComponent(remoteURL.lastPathComponent)

        let (temp, response) = try await URLSession.shared.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VLMError.downloadFailed
        }
        progress?(0.9)
        let data = try Data(contentsOf: temp)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expectedSHA256.lowercased() else {
            throw VLMError.checksumMismatch(expected: expectedSHA256, got: hex)
        }
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: temp, to: dest)
        fileManager.createFile(
            atPath: modelsDirectory.appendingPathComponent(".ready").path,
            contents: Data(hex.utf8)
        )
        isInstalled = true
        progress?(1.0)
    }

    public func makeRunner() -> any VLMRunner {
        if isInstalled {
            // Placeholder for MLX-backed runner; falls back to stub until linked.
            return StubVLMRunner()
        }
        return StubVLMRunner()
    }
}

public enum VLMError: Error, LocalizedError {
    case downloadFailed
    case checksumMismatch(expected: String, got: String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .downloadFailed: return "VLM download failed"
        case .checksumMismatch(let e, let g): return "Checksum mismatch (expected \(e), got \(g))"
        case .notInstalled: return "VLM model not installed"
        }
    }
}

// Minimal SHA256 without CryptoKit dependency on older sims — use CryptoKit when available.
import CryptoKit

enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: data))
    }
}

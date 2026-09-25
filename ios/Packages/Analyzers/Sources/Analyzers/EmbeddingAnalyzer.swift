import CoreML
import Foundation
import UIKit

/// Core ML SigLIP-class embedding + aesthetic head + zero-shot junk prompts.
///
/// Ship a palettized `.mlmodelc` named `SigLIPAesthetic` in the app bundle (see models/).
/// When the model is absent (dev / CI), falls back to a deterministic stub embedding
/// derived from image statistics so the rest of the pipeline stays testable.
public final class EmbeddingAnalyzer: @unchecked Sendable {
    public static let shared = EmbeddingAnalyzer()

    private var model: MLModel?

    public static let defaultJunkPrompts: [String] = [
        "a photo of a parking garage pillar",
        "a photo of a Wi-Fi router label",
        "a photo of a whiteboard with notes",
        "a photo of a package tracking slip",
        "a screenshot of a meme",
        "a photo of a receipt",
        "a photo of a QR code or barcode sticker",
        "a blurry accidental pocket photo",
    ]

    private var promptVectors: [(String, [Float])] = []

    public init() {
        loadModel()
        loadPromptVectors()
    }

    public struct Result: Sendable {
        public var embedding: [Float]
        public var aestheticRaw: Float
        public var junkSimilarities: [(String, Float)]
    }

    public func analyze(cgImage: CGImage) throws -> Result {
        if let model {
            return try runModel(model, cgImage: cgImage)
        }
        return stub(cgImage: cgImage)
    }

    private func loadModel() {
        guard let url = Bundle.main.url(forResource: "SigLIPAesthetic", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "SigLIPAesthetic", withExtension: "mlmodel")
        else { return }
        do {
            if url.pathExtension == "mlmodel" {
                let compiled = try MLModel.compileModel(at: url)
                model = try MLModel(contentsOf: compiled)
            } else {
                model = try MLModel(contentsOf: url)
            }
        } catch {
            print("EmbeddingAnalyzer: failed to load model: \(error)")
        }
    }

    private func loadPromptVectors() {
        if let url = Bundle.main.url(forResource: "junk_prompts", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([PromptVec].self, from: data)
        {
            promptVectors = decoded.map { ($0.label, $0.vector) }
            return
        }
        promptVectors = Self.defaultJunkPrompts.enumerated().map { idx, label in
            var v = [Float](repeating: 0, count: 64)
            v[idx % 64] = 1
            return (label, v)
        }
    }

    private struct PromptVec: Decodable {
        let label: String
        let vector: [Float]
    }

    private func runModel(_ model: MLModel, cgImage: CGImage) throws -> Result {
        let constraint = model.modelDescription.inputDescriptionsByName.values.first
        let imgConstraint = constraint?.imageConstraint
        let width = imgConstraint?.pixelsWide ?? 224
        let height = imgConstraint?.pixelsHigh ?? 224
        let inputName = constraint?.name ?? "image"
        let feature = try MLFeatureValue(
            cgImage: cgImage,
            pixelsWide: width,
            pixelsHigh: height,
            pixelFormatType: kCVPixelFormatType_32BGRA,
            options: nil
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: feature])
        let out = try model.prediction(from: provider)
        var embedding: [Float] = []
        var aesthetic: Float = 0.5
        for name in out.featureNames {
            guard let value = out.featureValue(for: name) else { continue }
            if let arr = value.multiArrayValue {
                let count = arr.count
                var buf = [Float](repeating: 0, count: count)
                for i in 0..<count { buf[i] = arr[i].floatValue }
                if name.lowercased().contains("aesthetic") || count == 1 {
                    aesthetic = buf.first ?? 0.5
                } else if embedding.isEmpty || buf.count > embedding.count {
                    embedding = buf
                }
            } else if value.type == .double {
                aesthetic = Float(value.doubleValue)
            }
        }
        if embedding.isEmpty {
            return stub(cgImage: cgImage)
        }
        return Result(embedding: embedding, aestheticRaw: aesthetic, junkSimilarities: similarities(to: embedding))
    }

    private func stub(cgImage: CGImage) -> Result {
        var emb = [Float](repeating: 0, count: 64)
        emb[0] = Float(cgImage.width % 251) / 251
        emb[1] = Float(cgImage.height % 251) / 251
        emb[2] = Float((cgImage.width * cgImage.height) % 997) / 997
        emb[3] = Float(min(cgImage.width, 32) + min(cgImage.height, 32)) / 64
        return Result(embedding: emb, aestheticRaw: 0.5, junkSimilarities: similarities(to: emb))
    }

    private func similarities(to embedding: [Float]) -> [(String, Float)] {
        promptVectors.map { label, vec in (label, cosine(embedding, vec)) }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom < 1e-9 ? 0 : dot / denom
    }
}

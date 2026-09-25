import CoreImage
import Foundation
import UIKit
import Vision

/// Tier-2 Vision analyzers: faces, text/barcodes/documents, saliency.
public enum VisionAnalyzers {

    // MARK: - Face / social miss

    public struct FaceAnalysis: Sendable {
        public var faceCount: UInt32 = 0
        public var avgCaptureQuality: Float = 0
        public var blinkCount: UInt32 = 0
        public var lookingAwayCount: UInt32 = 0
        public var mouthOpenCount: UInt32 = 0
        public var anyBlink: Bool = false
        public var anyLookingAway: Bool = false
        public var anyMouthOpen: Bool = false
    }

    /// Eye aspect ratio threshold — below this ≈ closed eye / blink.
    public static let blinkEAR: Float = 0.18
    /// Mouth aspect ratio above this ≈ open mouth (experimental).
    public static let mouthOpenMAR: Float = 0.55
    /// Absolute yaw (radians-ish from Vision roll/yaw) for looking away.
    public static let lookingAwayYaw: Float = 0.35

    public static func analyzeFaces(cgImage: CGImage) async throws -> FaceAnalysis {
        try await withCheckedThrowingContinuation { cont in
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let landmarks = VNDetectFaceLandmarksRequest()
            let quality = VNDetectFaceCaptureQualityRequest()
            do {
                try handler.perform([landmarks, quality])
                var result = FaceAnalysis()
                let faces = landmarks.results ?? []
                let quals = quality.results ?? []
                result.faceCount = UInt32(faces.count)
                if !quals.isEmpty {
                    let sum = quals.compactMap { $0.faceCaptureQuality }.reduce(0, +)
                    result.avgCaptureQuality = sum / Float(quals.count)
                }
                for face in faces {
                    if isBlink(face) {
                        result.blinkCount += 1
                        result.anyBlink = true
                    }
                    if isLookingAway(face) {
                        result.lookingAwayCount += 1
                        result.anyLookingAway = true
                    }
                    if isMouthOpen(face) {
                        result.mouthOpenCount += 1
                        result.anyMouthOpen = true
                    }
                }
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private static func isBlink(_ face: VNFaceObservation) -> Bool {
        guard let lm = face.landmarks else { return false }
        let left = ear(lm.leftEye)
        let right = ear(lm.rightEye)
        // If either eye is clearly closed, count as blink (group miss).
        return (left.map { $0 < blinkEAR } ?? false) || (right.map { $0 < blinkEAR } ?? false)
    }

    private static func isLookingAway(_ face: VNFaceObservation) -> Bool {
        // Vision provides yaw in face.yaw (NSNumber radians).
        let yaw = face.yaw?.floatValue ?? 0
        let pitch = face.pitch?.floatValue ?? 0
        return abs(yaw) > lookingAwayYaw || abs(pitch) > 0.45
    }

    private static func isMouthOpen(_ face: VNFaceObservation) -> Bool {
        guard let outer = face.landmarks?.outerLips else { return false }
        return mar(outer).map { $0 > mouthOpenMAR } ?? false
    }

    /// Eye aspect ratio from landmark region.
    private static func ear(_ region: VNFaceLandmarkRegion2D?) -> Float? {
        guard let pts = region?.normalizedPoints, pts.count >= 4 else { return nil }
        // Approximate: vertical span / horizontal span.
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 1e-5 else { return nil }
        return Float(height / width)
    }

    private static func mar(_ region: VNFaceLandmarkRegion2D) -> Float? {
        let pts = region.normalizedPoints
        guard pts.count >= 4 else { return nil }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 1e-5 else { return nil }
        return Float(height / width)
    }

    // MARK: - Text / barcode / document

    public struct TextAnalysis: Sendable {
        public var hasDenseText: Bool = false
        public var hasBarcode: Bool = false
        public var hasDocument: Bool = false
        public var textBlockCount: UInt32 = 0
        public var utilityKeywordHits: UInt32 = 0
    }

    private static let utilityKeywords: [String] = [
        "wifi", "wi-fi", "ssid", "password", "passwd", "tracking",
        "shipment", "order #", "invoice", "receipt", "total", "subtotal",
        "parking", "level", "garage", "http://", "https://", "barcode",
    ]

    public static func analyzeText(cgImage: CGImage) async throws -> TextAnalysis {
        try await withCheckedThrowingContinuation { cont in
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let textReq = VNRecognizeTextRequest()
            textReq.recognitionLevel = .fast
            textReq.usesLanguageCorrection = false
            let barcodeReq = VNDetectBarcodesRequest()
            let docReq = VNDetectDocumentSegmentationRequest()
            do {
                try handler.perform([textReq, barcodeReq, docReq])
                var result = TextAnalysis()
                let observations = textReq.results ?? []
                result.textBlockCount = UInt32(observations.count)
                result.hasDenseText = observations.count >= 4
                let joined = observations
                    .compactMap { $0.topCandidates(1).first?.string.lowercased() }
                    .joined(separator: " ")
                var hits: UInt32 = 0
                for kw in utilityKeywords where joined.contains(kw) {
                    hits += 1
                }
                result.utilityKeywordHits = hits
                result.hasBarcode = !(barcodeReq.results ?? []).isEmpty
                if let docs = docReq.results, let first = docs.first {
                    result.hasDocument = first.confidence > 0.5
                }
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Saliency / composition

    public struct CompositionAnalysis: Sendable {
        public var subjectPlacement: Float = 0.5
        public var subjectCoverage: Float = 0.3
        public var croppedSubject: Bool = false
    }

    public static func analyzeComposition(cgImage: CGImage) async throws -> CompositionAnalysis {
        try await withCheckedThrowingContinuation { cont in
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            do {
                try handler.perform([req])
                var result = CompositionAnalysis()
                if let obs = req.results?.first as? VNSaliencyImageObservation,
                   let objects = obs.salientObjects,
                   let main = objects.max(by: { $0.confidence < $1.confidence })
                {
                    let box = main.boundingBox // normalized, origin bottom-left
                    let cx = box.midX
                    let cy = box.midY
                    // Score closeness to rule-of-thirds points.
                    let thirds: [(CGFloat, CGFloat)] = [
                        (1.0 / 3, 1.0 / 3), (2.0 / 3, 1.0 / 3),
                        (1.0 / 3, 2.0 / 3), (2.0 / 3, 2.0 / 3),
                        (0.5, 0.5),
                    ]
                    let best = thirds.map { hypot($0.0 - cx, $0.1 - cy) }.min() ?? 1
                    result.subjectPlacement = Float(max(0, 1.0 - best * 2.0))
                    result.subjectCoverage = Float(min(1.0, box.width * box.height * 2.5))
                    // Cropped if box touches edge significantly.
                    let margin: CGFloat = 0.02
                    result.croppedSubject =
                        box.minX < margin || box.maxX > 1 - margin
                        || box.minY < margin || box.maxY > 1 - margin
                }
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

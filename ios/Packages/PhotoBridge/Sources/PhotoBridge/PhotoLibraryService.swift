import Foundation
import Photos
import PhotosUI
import UIKit
import CoreImage

/// Photo library access, enumeration, thumbnail loading, and batched deletes.
public final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    public static let shared = PhotoLibraryService()

    private let imageManager = PHCachingImageManager()
    private var changeHandler: ((PHChange) -> Void)?

    public override init() {
        super.init()
    }

    // MARK: - Authorization

    public func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    public var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Present Apple’s limited-library picker so the user can include newly taken photos.
    @MainActor
    public func presentLimitedLibraryPicker() async {
        guard authorizationStatus == .limited else { return }
        guard let host = Self.keyWindowRootViewController() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let state = OnceResume()
            if #available(iOS 15.0, *) {
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host) { _ in
                    state.resume {
                        cont.resume()
                    }
                }
            } else {
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host)
                // No completion on iOS 14 — resume shortly after presentation returns.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    state.resume {
                        cont.resume()
                    }
                }
            }
        }
    }

    @MainActor
    private static func keyWindowRootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Enumeration

    public struct AssetSnapshot: Sendable {
        public let localIdentifier: String
        public let createdAt: Date
        public let isFavorite: Bool
        public let isHidden: Bool
        public let isScreenshot: Bool
        public let isBurst: Bool
        public let isLive: Bool
        public let burstIdentifier: String?
        public let latitude: Double?
        public let longitude: Double?
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// Approximate on-disk bytes (photo + paired Live resources when present).
        public let byteSize: Int64
        /// False when Optimize iPhone Storage left only an iCloud stub on device.
        public let isLocallyAvailable: Bool
    }

    public func enumerateImageAssets(limit: Int? = nil) -> [AssetSnapshot] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        if let limit {
            options.fetchLimit = limit
        }
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var out: [AssetSnapshot] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            out.append(Self.snapshot(from: asset))
        }
        return out
    }

    public static func snapshot(from asset: PHAsset) -> AssetSnapshot {
        let loc = asset.location
        return AssetSnapshot(
            localIdentifier: asset.localIdentifier,
            createdAt: asset.creationDate ?? Date.distantPast,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isBurst: asset.representsBurst || asset.burstIdentifier != nil,
            isLive: asset.mediaSubtypes.contains(.photoLive),
            burstIdentifier: asset.burstIdentifier,
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            byteSize: approximateByteSize(of: asset),
            isLocallyAvailable: isLocallyAvailable(of: asset)
        )
    }

    /// True when primary photo (and Live paired video) resources are on-device.
    /// Uses KVC `locallyAvailable` (not in the public Photos SDK headers).
    public static func isLocallyAvailable(of asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryTypes: Set<PHAssetResourceType> = [
            .photo, .fullSizePhoto, .pairedVideo, .fullSizePairedVideo, .adjustmentBasePhoto,
        ]
        let primary = resources.filter { primaryTypes.contains($0.type) }
        let check = primary.isEmpty ? resources : primary
        guard !check.isEmpty else { return true }
        return check.allSatisfy { resource in
            (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
        }
    }

    /// Sum PhotoKit resource sizes; fall back to a compressed pixel estimate.
    public static func approximateByteSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for resource in resources {
            if let size = resource.value(forKey: "fileSize") as? Int64 {
                total += size
            } else if let size = resource.value(forKey: "fileSize") as? Int {
                total += Int64(size)
            } else if let size = resource.value(forKey: "fileSize") as? NSNumber {
                total += size.int64Value
            }
        }
        if total > 0 { return total }
        // Rough HEIC-ish estimate when PhotoKit omits fileSize.
        return Int64(asset.pixelWidth) * Int64(asset.pixelHeight) / 4
    }

    public func asset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: - Images

    /// Fast UI thumbnail — opportunistic first frame, never full-file decode first.
    public func requestThumbnail(
        for asset: PHAsset,
        maxPixel: CGFloat = 384
    ) async -> UIImage? {
        let size = CGSize(width: maxPixel, height: maxPixel)
        if let image = await requestImage(
            for: asset,
            targetSize: size,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            timeoutSeconds: 8,
            finishOnFirstFrame: true
        ) {
            return image
        }
        return await requestImage(
            for: asset,
            targetSize: size,
            deliveryMode: .fastFormat,
            resizeMode: .fast,
            timeoutSeconds: 5,
            finishOnFirstFrame: true
        )
    }

    /// Image for Keep or Toss review cards.
    ///
    /// Returns as soon as PhotoKit delivers any usable frame (usually cached, milliseconds
    /// for on-device photos). The underlying request stays alive so `onUpdate` can sharpen
    /// when a higher-quality frame arrives. Avoids full `requestImageData` (slow / heavy).
    public func requestDisplayImage(
        for asset: PHAsset,
        targetSize: CGSize,
        onUpdate: ((UIImage) -> Void)? = nil
    ) async -> UIImage? {
        // aspectFit so portrait/landscape stay uncropped; UI letterboxes with black.
        if let image = await requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            onUpdate: onUpdate,
            timeoutSeconds: 12,
            finishOnFirstFrame: true
        ) {
            return image
        }
        // Smaller / faster fallbacks before giving up.
        if let image = await requestImage(
            for: asset,
            targetSize: CGSize(width: 512, height: 512),
            contentMode: .aspectFit,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            onUpdate: onUpdate,
            timeoutSeconds: 8,
            finishOnFirstFrame: true
        ) {
            return image
        }
        return await requestImage(
            for: asset,
            targetSize: CGSize(width: 256, height: 256),
            contentMode: .aspectFit,
            deliveryMode: .fastFormat,
            resizeMode: .fast,
            onUpdate: onUpdate,
            timeoutSeconds: 5,
            finishOnFirstFrame: true
        )
    }

    /// Full image bytes via PhotoKit’s data API (analysis path — not for review UI).
    public func requestImageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .none
            opts.version = .current

            let state = DataRequestState(continuation: cont)
            let manager = PHImageManager.default()
            let requestID = manager.requestImageDataAndOrientation(
                for: asset,
                options: opts
            ) { data, _, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                if let data, !data.isEmpty {
                    state.finish(data)
                    return
                }
                if cancelled {
                    state.finish(nil)
                    return
                }
                // Early cloud errors are often non-terminal; wait for a later callback.
                if error != nil, !inCloud {
                    state.finish(nil)
                }
            }
            state.setRequestID(requestID)

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25) {
                guard let id = state.takeTimeoutCancelID() else { return }
                if id != PHInvalidImageRequestID {
                    manager.cancelImageRequest(id)
                }
                state.finish(nil)
            }
        }
    }

    /// PhotoKit may call the handler multiple times (degraded → final).
    ///
    /// - `finishOnFirstFrame`: resume as soon as any image arrives (review UI). The request
    ///   is left running so later `onUpdate` callbacks can still upgrade quality.
    /// - Otherwise finish on final / cancel / definitive error / timeout.
    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode,
        onUpdate: ((UIImage) -> Void)? = nil,
        timeoutSeconds: TimeInterval = 15,
        finishOnFirstFrame: Bool = false
    ) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = deliveryMode
            opts.resizeMode = resizeMode
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            opts.version = .current

            let state = ImageRequestState(continuation: cont)
            // Default manager for one-shot loads — caching manager can stall/miss.
            let manager = PHImageManager.default()

            let requestID = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: opts
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                if let image {
                    state.noteImage(image)
                    onUpdate?(image)
                    if finishOnFirstFrame {
                        // Resume await immediately; do not cancel — upgrades still arrive.
                        state.finishWithLatest()
                        return
                    }
                }

                if cancelled {
                    state.finishWithLatest()
                    return
                }

                // Don't treat early iCloud/network errors as terminal when no frame yet.
                if error != nil, state.currentImage() == nil {
                    if !inCloud {
                        state.finishWithLatest()
                    }
                    return
                }

                if error != nil || !degraded {
                    state.finishWithLatest()
                }
            }
            state.setRequestID(requestID)

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                // Only cancel when we never resumed — if we already returned a preview,
                // leave the request alive so quality upgrades can still reach onUpdate.
                guard let id = state.takeTimeoutCancelID() else { return }
                if id != PHInvalidImageRequestID {
                    manager.cancelImageRequest(id)
                }
                state.finishWithLatest()
            }
        }
    }

    public func requestRGBAThumbnail(
        for asset: PHAsset,
        maxPixel: Int = 256
    ) async -> (width: UInt32, height: UInt32, rgba: [UInt8])? {
        if let data = await requestImageData(for: asset),
           let image = UIImage(data: data),
           let rgba = Self.rgbaPixels(from: image, maxPixel: maxPixel)
        {
            return rgba
        }
        guard let image = await requestImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            timeoutSeconds: 12,
            finishOnFirstFrame: true
        ),
        let rgba = Self.rgbaPixels(from: image, maxPixel: maxPixel)
        else { return nil }
        return rgba
    }

    /// Downscale and convert to RGBA8 for the Rust pixel analyzer.
    public static func rgbaPixels(
        from image: UIImage,
        maxPixel: Int
    ) -> (width: UInt32, height: UInt32, rgba: [UInt8])? {
        guard let cg = cgImage(from: image) else { return nil }
        let srcW = cg.width
        let srcH = cg.height
        guard srcW > 0, srcH > 0 else { return nil }
        let longest = max(srcW, srcH)
        let scale = longest > maxPixel ? (CGFloat(maxPixel) / CGFloat(longest)) : 1
        let w = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let h = max(1, Int((CGFloat(srcH) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (UInt32(w), UInt32(h), rgba)
    }

    /// PhotoKit UIImages are sometimes CIImage-backed with a nil `cgImage`.
    public static func cgImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        if let ci = image.ciImage {
            let context = CIContext(options: nil)
            if let cg = context.createCGImage(ci, from: ci.extent) {
                return cg
            }
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    public func startCaching(identifiers: [String], size: CGSize) {
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        guard !list.isEmpty else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        opts.version = .current
        imageManager.startCachingImages(
            for: list,
            targetSize: size,
            contentMode: .aspectFit,
            options: opts
        )
    }

    // MARK: - Delete (Recently Deleted)

    /// Sum approximate on-disk sizes for the given local identifiers (before delete).
    public func totalByteSize(identifiers: [String]) -> Int64 {
        guard !identifiers.isEmpty else { return 0 }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var total: Int64 = 0
        assets.enumerateObjects { asset, _, _ in
            total += Self.approximateByteSize(of: asset)
        }
        return total
    }

    public func deleteAssets(identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }
    }

    // MARK: - Change observer

    public func startObserving(handler: @escaping (PHChange) -> Void) {
        changeHandler = handler
        PHPhotoLibrary.shared().register(self)
    }

    public func stopObserving() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        changeHandler = nil
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        changeHandler?(changeInstance)
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ body: () -> Void) {
        lock.lock()
        let already = resumed
        if !already { resumed = true }
        lock.unlock()
        guard !already else { return }
        body()
    }
}

// MARK: - Request state boxes

/// Thread-safe box for a single PhotoKit image request continuation.
private final class ImageRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var latest: UIImage?
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private let continuation: CheckedContinuation<UIImage?, Never>

    init(continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        lock.unlock()
    }

    func noteImage(_ image: UIImage) {
        lock.lock()
        latest = image
        lock.unlock()
    }

    func currentImage() -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func takeTimeoutCancelID() -> PHImageRequestID? {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return nil }
        return requestID
    }

    func finishWithLatest() {
        lock.lock()
        let already = resumed
        let result = latest
        if !already { resumed = true }
        lock.unlock()
        guard !already else { return }
        continuation.resume(returning: result)
    }
}

private final class DataRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private let continuation: CheckedContinuation<Data?, Never>

    init(continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        lock.unlock()
    }

    func takeTimeoutCancelID() -> PHImageRequestID? {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return nil }
        return requestID
    }

    func finish(_ data: Data?) {
        lock.lock()
        let already = resumed
        if !already { resumed = true }
        lock.unlock()
        guard !already else { return }
        continuation.resume(returning: data)
    }
}

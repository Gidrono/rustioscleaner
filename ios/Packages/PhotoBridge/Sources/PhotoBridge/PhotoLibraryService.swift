import Foundation
import Photos
import UIKit

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

    public func requestThumbnail(
        for asset: PHAsset,
        maxPixel: CGFloat = 384
    ) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            let target = CGSize(width: maxPixel, height: maxPixel)
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: opts
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed else { return }
                if cancelled || error != nil {
                    resumed = true
                    cont.resume(returning: nil)
                    return
                }
                if !degraded {
                    resumed = true
                    cont.resume(returning: image)
                }
            }
        }
    }

    /// High-quality image for on-screen review (not analysis thumbnails).
    public func requestDisplayImage(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .exact
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed else { return }
                if cancelled || error != nil {
                    resumed = true
                    cont.resume(returning: nil)
                    return
                }
                if !degraded {
                    resumed = true
                    cont.resume(returning: image)
                }
            }
        }
    }

    public func requestRGBAThumbnail(
        for asset: PHAsset,
        maxPixel: Int = 256
    ) async -> (width: UInt32, height: UInt32, rgba: [UInt8])? {
        guard let image = await requestThumbnail(for: asset, maxPixel: CGFloat(maxPixel)),
              let cg = image.cgImage
        else { return nil }

        let w = cg.width
        let h = cg.height
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
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (UInt32(w), UInt32(h), rgba)
    }

    public func startCaching(identifiers: [String], size: CGSize) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        imageManager.startCachingImages(
            for: list,
            targetSize: size,
            contentMode: .aspectFill,
            options: nil
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

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
            pixelHeight: asset.pixelHeight
        )
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
            imageManager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: opts
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded {
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

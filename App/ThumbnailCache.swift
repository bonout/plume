import CoreGraphics
import Foundation
import ImageIO
import PlumeKit

/// Server-rendered thumbnails, kept in memory and on disk, keyed by file id
/// and etag (a changed file gets a new thumbnail).
@MainActor
final class ThumbnailCache {
    private let memory = NSCache<NSString, CGImageBox>()
    private let folder = AppGroup.cachesURL.appending(path: "Thumbnails", directoryHint: .isDirectory)
    static let pixelSize = 128

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init() {
        memory.countLimit = 600
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cached(_ item: RemoteItem) -> CGImage? {
        memory.object(forKey: key(item) as NSString)?.image
    }

    func image(for item: RemoteItem, client: NextcloudClient) async -> CGImage? {
        guard item.hasPreview else { return nil }
        let key = key(item)
        if let box = memory.object(forKey: key as NSString) { return box.image }
        let file = folder.appending(path: key + ".jpg")
        let data: Data
        if let cached = try? Data(contentsOf: file) {
            data = cached
        } else {
            guard let fetched = try? await client.preview(of: item, size: Self.pixelSize) else { return nil }
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        }
        guard let image = Self.decode(data) else { return nil }
        memory.setObject(CGImageBox(image), forKey: key as NSString)
        return image
    }

    private func key(_ item: RemoteItem) -> String {
        item.fileID + "-" + item.etag.filter { $0.isLetter || $0.isNumber }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

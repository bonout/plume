import CoreGraphics
import Foundation
import ImageIO
import PlumeKit

/// Server-rendered thumbnails, kept in memory and on disk, keyed by file id
/// and etag (a changed file gets a new thumbnail).
@MainActor
final class ThumbnailCache {
    private let memory = NSCache<NSString, CGImageBox>()
    private nonisolated static let folder = AppGroup.cachesURL.appending(path: "Thumbnails", directoryHint: .isDirectory)
    static let pixelSize = 128

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init() {
        memory.countLimit = 600
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    func cached(_ item: RemoteItem) -> CGImage? {
        memory.object(forKey: Self.key(item) as NSString)?.image
    }

    func image(for item: RemoteItem, client: NextcloudClient) async -> CGImage? {
        guard item.hasPreview else { return nil }
        let key = Self.key(item)
        if let box = memory.object(forKey: key as NSString) { return box.image }
        let file = Self.diskURL(for: item)
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

    /// Where the item's thumbnail is kept on disk (Spotlight reads it too).
    nonisolated static func diskURL(for item: RemoteItem) -> URL {
        folder.appending(path: key(item) + ".jpg")
    }

    private nonisolated static func key(_ item: RemoteItem) -> String {
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

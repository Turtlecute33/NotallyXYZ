import AppKit
import ImageIO
import NotallyCore
import SwiftUI

/// Decrypted images live only in memory, downscaled, in a bounded cache.
@MainActor
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 96 << 20
        return c
    }()

    static func image(_ localName: String, maxPixels: Int, store: NoteStore) -> NSImage? {
        let key = "\(localName)@\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = store.attachmentData(localName),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }
}

/// An attachment image. `fill` crops into the frame the caller gives (never larger than it);
/// otherwise the whole image is shown at its own aspect ratio.
struct Thumbnail: View {
    let localName: String
    var maxPixels = 640
    var fill = true
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Group {
            if fill {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                    .clipped()
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder.frame(minWidth: 200, minHeight: 150)
            }
        }
        .task(id: "\(localName)-\(model.engine?.lastSync?.timeIntervalSince1970 ?? 0)") {
            guard image == nil, let store = model.store else { return }
            image = ImageCache.image(localName, maxPixels: maxPixels, store: store)
            missing = image == nil
        }
    }

    private var placeholder: some View {
        Image(systemName: missing ? "icloud.and.arrow.down" : "photo")
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}

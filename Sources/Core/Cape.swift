import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A cursor theme, read from and written to Mousecape's `.cape` plist format so
/// existing community capes keep working.
public struct Cape {
    public var name: String
    public var author: String
    public var identifier: String
    public var version: Double
    /// identifier -> art
    public var cursors: [String: CursorArt]

    public init(name: String, author: String = NSFullUserName(),
                identifier: String = "com.mousecaperevamp.\(UUID().uuidString)",
                version: Double = 1.0, cursors: [String: CursorArt] = [:]) {
        self.name = name
        self.author = author
        self.identifier = identifier
        self.version = version
        self.cursors = cursors
    }

    // MARK: - Reading

    public static func load(from url: URL) throws -> Cape {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            throw ImportError.unreadable(url)
        }
        var cape = Cape(name: dict["CapeName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                        author: dict["Author"] as? String ?? "",
                        identifier: dict["Identifier"] as? String ?? UUID().uuidString,
                        version: dict["CapeVersion"] as? Double ?? 1.0)

        for (identifier, raw) in (dict["Cursors"] as? [String: [String: Any]] ?? [:]) {
            let frameCount = (raw["FrameCount"] as? NSNumber)?.intValue ?? 1
            let duration = (raw["FrameDuration"] as? NSNumber)?.doubleValue ?? 0
            let pointsWide = (raw["PointsWide"] as? NSNumber)?.doubleValue ?? 0
            let hotX = (raw["HotSpotX"] as? NSNumber)?.doubleValue ?? 0
            let hotY = (raw["HotSpotY"] as? NSNumber)?.doubleValue ?? 0
            let reps = (raw["Representations"] as? [Data] ?? []).compactMap(decodeImage)
            guard let best = reps.max(by: { $0.width < $1.width }), frameCount > 0 else { continue }

            let frames = splitFrames(best, count: frameCount)
            guard !frames.isEmpty else { continue }

            // Cape hot spots are in points; CursorArt keeps them in source pixels.
            let scale = pointsWide > 0 ? Double(best.width) / pointsWide : 1
            cape.cursors[identifier] = CursorArt(
                frames: frames,
                frameDuration: duration,
                hotSpot: CGPoint(x: hotX * scale, y: hotY * scale),
                hotSpotIsExplicit: true)
        }
        return cape
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Splits a vertically stacked representation back into frames.
    private static func splitFrames(_ image: CGImage, count: Int) -> [CGImage] {
        guard count > 0 else { return [] }
        let fh = image.height / count
        guard fh > 0 else { return [] }
        return (0..<count).compactMap {
            image.cropping(to: CGRect(x: 0, y: $0 * fh, width: image.width, height: fh))
        }
    }

    // MARK: - Writing

    public func write(to url: URL) throws {
        var cursors: [String: Any] = [:]
        for (identifier, art) in self.cursors {
            // Render at the aspect-preserving size, exactly as applying does.
            // Using the slot's stock size here is what baked a squashed 28x40
            // Busy cursor into saved profiles.
            let size = art.fittedPointSize(base: CursorArt.baseSize)
            let scales = art.suggestedScales(pointSize: size)
            let reps = art.representations(pointSize: size, scales: scales).compactMap(pngData)
            guard !reps.isEmpty else { continue }
            let hot = CursorCatalog.slot(for: identifier)
                .map { art.resolvedHotSpot(for: $0, pointSize: size) }
                ?? art.hotSpot(forPointSize: size)
            cursors[identifier] = [
                "FrameCount": art.frames.count,
                "FrameDuration": art.frameDuration,
                "HotSpotX": hot.x,
                "HotSpotY": hot.y,
                "PointsWide": size.width,
                "PointsHigh": size.height,
                "Representations": reps,
            ]
        }
        let plist: [String: Any] = [
            "Author": author,
            "CapeName": name,
            "CapeVersion": version,
            "Cloud": false,
            "HiDPI": true,
            "Identifier": identifier,
            "MinimumVersion": 2.0,
            "Version": 2.0,
            "Cursors": cursors,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .binary, options: 0)
        try data.write(to: url)
    }

    private func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

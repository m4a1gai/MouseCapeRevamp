import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImportError: LocalizedError {
    case unreadable(URL)
    case noFrames(URL)
    case notAnANIFile(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let u):     return "Could not read \(u.lastPathComponent)."
        case .noFrames(let u):       return "No frames found in \(u.lastPathComponent)."
        case .notAnANIFile(let u):   return "\(u.lastPathComponent) is not a RIFF/ACON .ani file."
        }
    }
}

public enum CursorImporter {

    /// Frame delays below this look like a stuck animation once the window
    /// server plays them, and GIF tools routinely emit 0.01s placeholders.
    public static let minimumFrameDuration: Double = 0.03

    /// Imports whatever the URL points at: a folder of frames, an .ani, an
    /// animated GIF, or a single still image.
    public static func importArt(at url: URL) throws -> CursorArt {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { return try importFrameFolder(at: url) }
        if url.pathExtension.lowercased() == "ani" { return try importANI(at: url) }
        return try importImageFile(at: url)
    }

    // MARK: - Animated GIF / still image

    public static func importImageFile(at url: URL) throws -> CursorArt {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImportError.unreadable(url)
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ImportError.noFrames(url) }

        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            delays.append(gifDelay(src, i))
        }
        guard !frames.isEmpty else { throw ImportError.noFrames(url) }

        let avg = delays.filter { $0 > 0 }.average ?? 0
        return CursorArt(frames: frames,
                         frameDuration: frames.count > 1 ? max(avg, minimumFrameDuration) : 0,
                         hotSpot: .zero, hotSpotIsExplicit: false)
    }

    private static func gifDelay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0 }
        if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0 { return d }
        if let d = gif[kCGImagePropertyGIFDelayTime] as? Double, d > 0 { return d }
        return 0
    }

    // MARK: - Folder of numbered frames

    /// Reads a directory of frame images, ordered by the first number in each
    /// file name. Picks up the `delay-0.01s` suffix that GIF splitters emit.
    public static func importFrameFolder(at url: URL) throws -> CursorArt {
        let files = (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles])) ?? []
        let imageFiles = files
            .filter { ["gif", "png", "tiff", "tif", "jpg", "jpeg", "bmp"]
                        .contains($0.pathExtension.lowercased()) }
            .sorted { leadingNumber($0) < leadingNumber($1) }
        guard !imageFiles.isEmpty else { throw ImportError.noFrames(url) }

        var frames: [CGImage] = []
        for file in imageFiles {
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            frames.append(img)
        }
        guard !frames.isEmpty else { throw ImportError.noFrames(url) }

        let parsed = imageFiles.compactMap { delaySuffix($0) }.average ?? 0
        return CursorArt(frames: frames,
                         frameDuration: frames.count > 1 ? max(parsed, minimumFrameDuration) : 0,
                         hotSpot: .zero, hotSpotIsExplicit: false)
    }

    private static func leadingNumber(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        var digits = ""
        for ch in name where ch.isNumber || !digits.isEmpty {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits) ?? 0
    }

    /// Pulls 0.01 out of `frame_03_delay-0.01s.gif`.
    private static func delaySuffix(_ url: URL) -> Double? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = name.range(of: "delay-") else { return nil }
        let tail = name[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(tail)
    }

    // MARK: - Windows .ani

    /// Parses a RIFF/ACON animated cursor: `anih` for geometry, `rate` for
    /// per-frame timing, and a `LIST fram` of embedded .cur images.
    public static func importANI(at url: URL) throws -> CursorArt {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable(url) }
        guard data.count > 12,
              data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("ACON".utf8) else { throw ImportError.notAnANIFile(url) }

        var displayRate = 6          // jiffies (1/60 s)
        var rates: [UInt32] = []
        var sequence: [UInt32] = []
        var icons: [Data] = []

        forEachChunk(in: data, from: 12, to: data.count) { id, body, size in
            switch id {
            case "anih":
                if size >= 36, let r = data.u32(body + 28) { displayRate = Int(r) }
            case "rate":
                rates = (0..<(size / 4)).compactMap { data.u32(body + $0 * 4) }
            case "seq ":
                sequence = (0..<(size / 4)).compactMap { data.u32(body + $0 * 4) }
            case "LIST":
                guard size >= 4, data.string(body, 4) == "fram" else { return }
                forEachChunk(in: data, from: body + 4, to: body + size) { id2, body2, size2 in
                    if id2 == "icon" { icons.append(data.subdata(in: body2..<min(body2 + size2, data.count))) }
                }
            default: break
            }
        }
        guard !icons.isEmpty else { throw ImportError.noFrames(url) }

        // `seq` reorders / repeats the stored images into the real play order.
        let order: [Int] = sequence.isEmpty ? Array(icons.indices)
                                            : sequence.map { Int($0) }.filter { icons.indices.contains($0) }

        var frames: [CGImage] = []
        var hotSpot = CGPoint.zero
        for (step, iconIndex) in order.enumerated() {
            guard let decoded = CursorFileDecoder.decode(icons[iconIndex]) else { continue }
            if step == 0 { hotSpot = decoded.hotSpot }
            frames.append(decoded.image)
        }
        guard !frames.isEmpty else { throw ImportError.noFrames(url) }

        let jiffies = rates.isEmpty ? Double(displayRate)
                                    : Double(rates.reduce(0, +)) / Double(rates.count)
        let duration = frames.count > 1 ? max(jiffies / 60.0, minimumFrameDuration) : 0
        return CursorArt(frames: frames, frameDuration: duration,
                         hotSpot: hotSpot, hotSpotIsExplicit: true)
    }

    private static func forEachChunk(in data: Data, from: Int, to: Int,
                                     _ body: (String, Int, Int) -> Void) {
        var offset = from
        while offset + 8 <= to {
            guard let id = data.string(offset, 4), let size = data.u32(offset + 4) else { return }
            let start = offset + 8
            let size32 = Int(size)
            guard start + size32 <= to else { return }
            body(id, start, size32)
            offset = start + size32 + (size32 & 1)   // chunks are word aligned
        }
    }
}

private extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

private extension Data {
    func u16(_ o: Int) -> UInt16? {
        guard o + 2 <= count else { return nil }
        return UInt16(self[o]) | UInt16(self[o + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32? {
        guard o + 4 <= count else { return nil }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8
            | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func i32(_ o: Int) -> Int32? { u32(o).map { Int32(bitPattern: $0) } }
    func string(_ o: Int, _ n: Int) -> String? {
        guard o + n <= count else { return nil }
        return String(bytes: self[o..<(o + n)], encoding: .ascii)
    }
}

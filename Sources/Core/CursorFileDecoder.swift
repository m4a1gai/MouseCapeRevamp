import CoreGraphics
import Foundation
import ImageIO

/// Decodes a Windows .cur / .ico image, including the ones embedded in .ani
/// files. Handles PNG-compressed entries and classic DIB entries at 32, 24, 8,
/// 4 and 1 bits per pixel, applying the 1-bit AND mask where there is no alpha.
public enum CursorFileDecoder {

    public struct Decoded {
        public let image: CGImage
        /// Hot spot in pixels, origin top-left.
        public let hotSpot: CGPoint
    }

    public static func decode(_ data: Data) -> Decoded? {
        guard let type = data.u16(2), let count = data.u16(4), count > 0 else { return nil }
        let isCursor = (type == 2)

        // Pick the largest entry on offer.
        var best: (offset: Int, size: Int, hotSpot: CGPoint, area: Int)?
        for i in 0..<Int(count) {
            let e = 6 + i * 16
            guard let bytes = data.u32(e + 8), let offset = data.u32(e + 12),
                  e + 16 <= data.count else { continue }
            let w = Int(data[e]) == 0 ? 256 : Int(data[e])
            let h = Int(data[e + 1]) == 0 ? 256 : Int(data[e + 1])
            let hs = isCursor
                ? CGPoint(x: CGFloat(data.u16(e + 4) ?? 0), y: CGFloat(data.u16(e + 6) ?? 0))
                : .zero
            if best == nil || w * h > best!.area {
                best = (Int(offset), Int(bytes), hs, w * h)
            }
        }
        guard let entry = best, entry.offset + entry.size <= data.count else { return nil }
        let payload = data.subdata(in: entry.offset..<(entry.offset + entry.size))

        if payload.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {   // PNG
            guard let src = CGImageSourceCreateWithData(payload as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return Decoded(image: img, hotSpot: entry.hotSpot)
        }
        guard let img = decodeDIB(payload) else { return nil }
        return Decoded(image: img, hotSpot: entry.hotSpot)
    }

    private static func decodeDIB(_ d: Data) -> CGImage? {
        guard let headerSize = d.u32(0), headerSize >= 40,
              let width = d.i32(4), let doubleHeight = d.i32(8),
              let bitCount = d.u16(14), let compression = d.u32(16),
              compression == 0 else { return nil }      // BI_RGB only

        let w = Int(width)
        let h = Int(doubleHeight) / 2                   // XOR image + AND mask
        guard w > 0, h > 0, w <= 1024, h <= 1024 else { return nil }

        var palette: [(UInt8, UInt8, UInt8)] = []
        var cursor = Int(headerSize)
        if bitCount <= 8 {
            let declared = Int(d.u32(32) ?? 0)
            let entries = declared > 0 ? declared : (1 << Int(bitCount))
            for i in 0..<entries {
                let o = cursor + i * 4
                guard o + 3 < d.count else { break }
                palette.append((d[o + 2], d[o + 1], d[o]))   // stored BGRA
            }
            cursor += entries * 4
        }

        let xorRow = ((w * Int(bitCount) + 31) / 32) * 4
        let andRow = ((w + 31) / 32) * 4
        let xorStart = cursor
        let andStart = xorStart + xorRow * h
        guard andStart <= d.count else { return nil }
        let hasMask = andStart + andRow * h <= d.count

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var sawAlpha = false

        for y in 0..<h {
            let srcY = h - 1 - y                         // DIB rows are bottom-up
            let rowBase = xorStart + srcY * xorRow
            for x in 0..<w {
                var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255
                switch bitCount {
                case 32:
                    let o = rowBase + x * 4
                    guard o + 3 < d.count else { break }
                    b = d[o]; g = d[o + 1]; r = d[o + 2]; a = d[o + 3]
                    if a != 0 { sawAlpha = true }
                case 24:
                    let o = rowBase + x * 3
                    guard o + 2 < d.count else { break }
                    b = d[o]; g = d[o + 1]; r = d[o + 2]
                case 8:
                    let o = rowBase + x
                    guard o < d.count, Int(d[o]) < palette.count else { break }
                    (r, g, b) = palette[Int(d[o])]
                case 4:
                    let o = rowBase + x / 2
                    guard o < d.count else { break }
                    let idx = Int(x % 2 == 0 ? d[o] >> 4 : d[o] & 0x0F)
                    guard idx < palette.count else { break }
                    (r, g, b) = palette[idx]
                case 1:
                    let o = rowBase + x / 8
                    guard o < d.count else { break }
                    let idx = Int((d[o] >> (7 - UInt8(x % 8))) & 1)
                    guard idx < palette.count else { break }
                    (r, g, b) = palette[idx]
                default:
                    return nil
                }
                let p = (y * w + x) * 4
                rgba[p] = r; rgba[p + 1] = g; rgba[p + 2] = b; rgba[p + 3] = a
            }
        }

        // Sub-32bpp art, and 32bpp art with an empty alpha channel, carry
        // transparency in the 1-bit AND mask instead (1 = transparent).
        if hasMask && (bitCount < 32 || !sawAlpha) {
            for y in 0..<h {
                let srcY = h - 1 - y
                let rowBase = andStart + srcY * andRow
                for x in 0..<w {
                    let o = rowBase + x / 8
                    guard o < d.count else { continue }
                    let bit = (d[o] >> (7 - UInt8(x % 8))) & 1
                    rgba[(y * w + x) * 4 + 3] = bit == 1 ? 0 : 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
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
}

import CoreGraphics
import Foundation
import ImageIO

/// Decoded art for one cursor: N equally sized frames plus timing and hot spot.
public struct CursorArt {
    /// Every frame, all the same pixel size, in playback order.
    public var frames: [CGImage]
    /// Seconds per frame. 0 for a still cursor.
    public var frameDuration: Double
    /// Hot spot in SOURCE PIXEL coordinates, origin top-left.
    public var hotSpot: CGPoint
    /// True when the source format carried a real hot spot (.ani / .cur do,
    /// GIFs and frame folders do not). When false the slot's own hot spot is
    /// used instead, which is what makes resize and crosshair cursors line up.
    public var hotSpotIsExplicit: Bool

    public var pixelSize: CGSize {
        guard let f = frames.first else { return .zero }
        return CGSize(width: f.width, height: f.height)
    }

    public init(frames: [CGImage], frameDuration: Double,
                hotSpot: CGPoint, hotSpotIsExplicit: Bool = false) {
        self.frames = frames
        self.frameDuration = frameDuration
        self.hotSpot = hotSpot
        self.hotSpotIsExplicit = hotSpotIsExplicit
    }

    /// The default size a cursor is rendered at, in points, before the user's
    /// scale is applied. Roughly matches the stock macOS cursors.
    public static let baseSize: CGFloat = 32

    /// Point size that preserves the source aspect ratio.
    ///
    /// Forcing art into a slot's stock size is what stretches a square 96x96
    /// drawing into, say, the 28x40 of the Busy cursor. Fit the longest edge to
    /// `base` instead and let the other edge follow the source proportions.
    public func fittedPointSize(base: CGFloat) -> CGSize {
        let px = pixelSize
        guard px.width > 0, px.height > 0 else { return CGSize(width: base, height: base) }
        return px.width >= px.height
            ? CGSize(width: base, height: (base * px.height / px.width).rounded())
            : CGSize(width: (base * px.width / px.height).rounded(), height: base)
    }

    /// Hot spot converted into the point coordinate space of `pointSize`.
    public func hotSpot(forPointSize pointSize: CGSize) -> CGPoint {
        let px = pixelSize
        guard px.width > 0, px.height > 0 else { return .zero }
        return CGPoint(x: hotSpot.x / px.width  * pointSize.width,
                       y: hotSpot.y / px.height * pointSize.height)
    }

    /// Evenly subsamples down to `limit` frames, preserving total duration.
    public func limited(to limit: Int) -> CursorArt {
        guard frames.count > limit, limit > 0 else { return self }
        let total = frameDuration * Double(frames.count)
        var picked: [CGImage] = []
        picked.reserveCapacity(limit)
        for i in 0..<limit {
            picked.append(frames[i * frames.count / limit])
        }
        return CursorArt(frames: picked,
                         frameDuration: total / Double(limit),
                         hotSpot: hotSpot,
                         hotSpotIsExplicit: hotSpotIsExplicit)
    }

    /// Builds one representation per scale factor.
    ///
    /// Each representation stacks every frame vertically with frame 0 on top,
    /// which is the layout `CGSRegisterCursorWithImages` expects.
    public func representations(pointSize: CGSize, scales: [CGFloat]) -> [CGImage] {
        scales.compactMap { scale in
            stacked(frameWidth: Int((pointSize.width  * scale).rounded()),
                    frameHeight: Int((pointSize.height * scale).rounded()))
        }
    }

    private func stacked(frameWidth fw: Int, frameHeight fh: Int) -> CGImage? {
        guard fw > 0, fh > 0, !frames.isEmpty else { return nil }
        let totalHeight = fh * frames.count
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: fw, height: totalHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // CGContext is bottom-left origin, so frame 0 goes in the TOP band.
        for (i, frame) in frames.enumerated() {
            let y = totalHeight - (i + 1) * fh
            ctx.draw(frame, in: CGRect(x: 0, y: y, width: fw, height: fh))
        }
        return ctx.makeImage()
    }

    /// Where the hot spot lands for a slot at a given point size.
    ///
    /// Shared by the apply path and the .cape writer so a theme cannot end up
    /// with one hot spot on screen and a different one on disk.
    public func resolvedHotSpot(for slot: CursorSlot, pointSize: CGSize) -> CGPoint {
        if hotSpotIsExplicit { return hotSpot(forPointSize: pointSize) }
        // GIFs and frame folders carry no hot spot, so follow where macOS puts
        // it for this cursor role - that is what centres resize and crosshair.
        return CGPoint(x: slot.defaultHotSpot.x / slot.defaultSize.width  * pointSize.width,
                       y: slot.defaultHotSpot.y / slot.defaultSize.height * pointSize.height)
    }

    /// Picks representation scales that never upscale past the source art.
    /// Always includes 1x and 2x; adds the native scale when the source has the
    /// detail to back it, which keeps the cursor crisp when the accessibility
    /// pointer-size slider is turned up.
    public func suggestedScales(pointSize: CGSize) -> [CGFloat] {
        var scales: [CGFloat] = [1, 2]
        guard pointSize.width > 0 else { return scales }
        let native = (pixelSize.width / pointSize.width).rounded(.down)
        if native >= 3 { scales.append(min(native, 10)) }
        return scales
    }
}

import CoreGraphics
import Foundation

public enum CursorEngineError: LocalizedError {
    case slotIsProtected(String)
    case noFrames
    case couldNotBuildRepresentations
    case registrationFailed(String, CGError)
    /// The call reported success but the window server kept the old art.
    case registrationSilentlyIgnored(String)

    public var errorDescription: String? {
        switch self {
        case .slotIsProtected(let id):
            return "\(id) is a system-defined cursor; macOS no longer allows replacing it."
        case .noFrames:
            return "The source has no usable frames."
        case .couldNotBuildRepresentations:
            return "Could not render the cursor representations."
        case .registrationFailed(let id, let err):
            return "Registering \(id) failed with CGError \(err.rawValue)."
        case .registrationSilentlyIgnored(let id):
            return "The window server accepted \(id) but kept the original art."
        }
    }
}

/// Talks to the window server's cursor registry.
public struct CursorEngine {

    /// The window server rejects anything above this. The stock Wait cursor
    /// ships 30 frames, so the old Mousecape limit of 24 was too conservative.
    public static let maxFrameCount = 24

    private let connection: CGSConnectionID

    public init() {
        self.connection = CGSMainConnectionID()
    }

    public var seed: Int32 { CGSCurrentCursorSeed() }

    // MARK: - Reading

    public func isRegistered(_ identifier: String) -> Bool {
        var size: Int = 0
        let err = identifier.withCString { ptr -> CGError in
            CGSGetRegisteredCursorDataSize(connection, UnsafeMutablePointer(mutating: ptr), &size)
        }
        return err == .success && size > 0
    }

    /// Current registered art for a slot, stock or themed.
    public func registeredArt(for identifier: String) -> (size: CGSize, hotSpot: CGPoint,
                                                          frameCount: Int, duration: Double,
                                                          reps: [CGImage])? {
        var size = CGSize.zero
        var hotSpot = CGPoint.zero
        var frameCount: UInt = 0
        var duration: CGFloat = 0
        var array: Unmanaged<CFArray>?

        let err = identifier.withCString { ptr -> CGError in
            CGSCopyRegisteredCursorImages(connection, UnsafeMutablePointer(mutating: ptr),
                                          &size, &hotSpot, &frameCount, &duration, &array)
        }
        guard err == .success, let images = array?.takeRetainedValue() as? [CGImage] else {
            return nil
        }
        return (size, hotSpot, Int(frameCount), Double(duration), images)
    }

    // MARK: - Writing

    /// Registers `art` for `slot` and then verifies the server really took it.
    ///
    /// Verification matters: since macOS 26 the window server returns
    /// kCGErrorSuccess for the protected system cursors and then throws the
    /// data away, so the return code on its own means nothing.
    @discardableResult
    public func apply(_ art: CursorArt, to slot: CursorSlot, pointSize: CGSize? = nil) throws -> Int {
        guard !slot.isProtected else { throw CursorEngineError.slotIsProtected(slot.identifier) }
        guard !art.frames.isEmpty else { throw CursorEngineError.noFrames }

        let art = art.limited(to: Self.maxFrameCount)
        // Preserve the source aspect ratio instead of squashing it into the
        // slot's stock dimensions.
        let size = pointSize ?? art.fittedPointSize(base: CursorArt.baseSize)
        let scales = art.suggestedScales(pointSize: size)
        let reps = art.representations(pointSize: size, scales: scales)
        guard !reps.isEmpty else { throw CursorEngineError.couldNotBuildRepresentations }

        let hotSpot = art.resolvedHotSpot(for: slot, pointSize: size)
        var outSeed: Int32 = 0

        let err = slot.identifier.withCString { ptr -> CGError in
            CGSRegisterCursorWithImages(connection,
                                        UnsafeMutablePointer(mutating: ptr),
                                        true,   // setGlobally
                                        true,   // instantly
                                        size,
                                        hotSpot,
                                        UInt(art.frames.count),
                                        CGFloat(art.frameDuration),
                                        reps as CFArray,
                                        &outSeed)
        }
        guard err == .success else {
            throw CursorEngineError.registrationFailed(slot.identifier, err)
        }
        guard verify(slot.identifier, expectedFrames: art.frames.count, expectedSize: size) else {
            throw CursorEngineError.registrationSilentlyIgnored(slot.identifier)
        }
        return art.frames.count
    }

    private func verify(_ identifier: String, expectedFrames: Int, expectedSize: CGSize) -> Bool {
        guard let back = registeredArt(for: identifier) else { return false }
        return back.frameCount == expectedFrames
            && abs(back.size.width  - expectedSize.width)  < 0.5
            && abs(back.size.height - expectedSize.height) < 0.5
    }

    /// Points this process's cursor at a registered slot, for previewing.
    public func preview(_ identifier: String) {
        var seed: Int32 = 0
        _ = identifier.withCString {
            CGSSetRegisteredCursor(connection, UnsafeMutablePointer(mutating: $0), &seed)
        }
    }

    // MARK: - Restoring

    /// Drops every override and restores the stock cursors.
    @discardableResult
    public func restoreAll() -> Bool {
        CoreCursorUnregisterAll(connection) == .success
    }

    /// Drops a single override.
    @discardableResult
    public func restore(_ identifier: String) -> Bool {
        identifier.withCString { ptr in
            CGSRemoveRegisteredCursor(connection, UnsafeMutablePointer(mutating: ptr), false) == .success
        }
    }
}

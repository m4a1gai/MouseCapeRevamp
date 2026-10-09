import CoreGraphics
import Foundation

/// Keeps a copy of the stock system cursors so they can be put back.
///
/// This matters because the CoreGraphics cursors cannot be un-registered:
/// `CGSRemoveRegisteredCursor` fails with kCGErrorFailure on them and
/// `CoreCursorUnregisterAll` leaves them alone. Once something writes to
/// ArrowS, the only way back is to re-register the original art, so the
/// original has to be saved before the first write ever happens.
public final class StockBackup {

    public static let shared = StockBackup()

    private let url: URL
    private var cape: Cape

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("MouseCapeRevamp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("Stock.cape")
        cape = (try? Cape.load(from: url)) ?? Cape(name: "macOS stock cursors")
    }

    /// Only the CoreGraphics cursors need this. The `com.apple.cursor.N` slots
    /// are cleared properly by CoreCursorUnregisterAll, so they look after
    /// themselves.
    public static func needsBackup(_ slot: CursorSlot) -> Bool {
        slot.identifier.hasPrefix("com.apple.coregraphics.")
    }

    public var savedIdentifiers: Set<String> { Set(cape.cursors.keys) }

    public func hasBackup(for identifier: String) -> Bool {
        cape.cursors[CursorCatalog.resolve(identifier)] != nil
    }

    /// Saves a slot's current art the first time it is about to be replaced.
    ///
    /// Deliberately a no-op once something is stored, so re-applying a theme
    /// cannot overwrite the stock copy with themed art.
    public func captureIfNeeded(_ slot: CursorSlot, engine: CursorEngine) {
        guard Self.needsBackup(slot), cape.cursors[slot.identifier] == nil else { return }
        guard let art = engine.currentArt(for: slot.identifier) else { return }
        cape.cursors[slot.identifier] = art.limited(to: CursorEngine.maxFrameCount)
        try? cape.write(to: url)
    }

    /// Re-registers every saved stock cursor. Returns how many were restored.
    @discardableResult
    public func restore(engine: CursorEngine) -> Int {
        var restored = 0
        for (identifier, art) in cape.cursors {
            guard let slot = CursorCatalog.slot(for: identifier) else { continue }
            // Stock art is already at its natural size, so register it as-is
            // rather than refitting it to the user's chosen cursor size.
            let size = CGSize(width: slot.defaultSize.width, height: slot.defaultSize.height)
            if (try? engine.apply(art, to: slot, pointSize: size, backingUp: false)) != nil {
                restored += 1
            }
        }
        return restored
    }

    /// Throws the saved copy away so the next apply captures fresh art. For the
    /// case where the backup was taken while a theme was already active.
    public func forget() {
        cape.cursors.removeAll()
        try? FileManager.default.removeItem(at: url)
    }
}

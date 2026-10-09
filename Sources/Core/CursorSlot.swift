import CoreGraphics
import Foundation

/// One themeable cursor slot in the window server's registry.
///
/// Default sizes and hot spots below were read off a live macOS 26 system with
/// `CoreCursorCopyImages`, so they match what the stock cursors actually use
/// rather than the values Mousecape hard-coded back in 2014.
public struct CursorSlot: Sendable, Hashable {
    public let identifier: String
    public let name: String
    public let defaultSize: CGSize
    public let defaultHotSpot: CGPoint

    /// Only the two legacy aliases reject writes. Everything else, including
    /// the ArrowS / IBeamS variants they forward to, is writable.
    public var isProtected: Bool { CursorCatalog.legacyAliases[identifier] != nil }

    init(_ identifier: String, _ name: String,
         _ w: CGFloat, _ h: CGFloat, _ hx: CGFloat, _ hy: CGFloat) {
        self.identifier = identifier
        self.name = name
        self.defaultSize = CGSize(width: w, height: h)
        self.defaultHotSpot = CGPoint(x: hx, y: hy)
    }
}

public enum CursorCatalog {

    /// Slots that can actually be themed on macOS 26.
    public static let writable: [CursorSlot] = [
        CursorSlot("com.apple.cursor.2",  "Drag Link",         16, 21, 11,  3),
        CursorSlot("com.apple.cursor.3",  "Forbidden",         28, 40,  5,  5),
        CursorSlot("com.apple.cursor.4",  "Busy",              28, 40,  5,  5),
        CursorSlot("com.apple.cursor.5",  "Drag Copy",         28, 40,  5,  5),
        CursorSlot("com.apple.cursor.7",  "Crosshair",         32, 32, 15, 15),
        CursorSlot("com.apple.cursor.8",  "Crosshair 2",       32, 32, 15, 15),
        CursorSlot("com.apple.cursor.9",  "Camera 2",          28, 25, 14, 11),
        CursorSlot("com.apple.cursor.10", "Camera",            28, 25, 14, 11),
        CursorSlot("com.apple.cursor.11", "Closed Hand",       32, 32, 16, 17),
        CursorSlot("com.apple.cursor.12", "Open Hand",         32, 32, 16, 17),
        CursorSlot("com.apple.cursor.13", "Pointing Hand",     32, 32, 13,  8),
        CursorSlot("com.apple.cursor.14", "Counting Up",       24, 24, 12, 12),
        CursorSlot("com.apple.cursor.15", "Counting Down",     24, 24, 12, 12),
        CursorSlot("com.apple.cursor.16", "Counting Up/Down",  24, 24, 12, 12),
        CursorSlot("com.apple.cursor.17", "Resize W",          24, 24, 12, 12),
        CursorSlot("com.apple.cursor.18", "Resize E",          24, 24, 12, 12),
        CursorSlot("com.apple.cursor.19", "Resize W-E",        30, 24, 15, 12),
        CursorSlot("com.apple.cursor.20", "Cell XOR",          24, 24, 11, 11),
        CursorSlot("com.apple.cursor.21", "Resize N",          24, 24, 12, 13),
        CursorSlot("com.apple.cursor.22", "Resize S",          24, 24, 12, 11),
        CursorSlot("com.apple.cursor.23", "Resize N-S",        24, 28, 12, 14),
        CursorSlot("com.apple.cursor.24", "Context Menu",      28, 40,  5,  5),
        CursorSlot("com.apple.cursor.25", "Poof",              28, 40,  5,  5),
        CursorSlot("com.apple.cursor.26", "I-Beam Horizontal", 22, 21, 11, 10),
        CursorSlot("com.apple.cursor.27", "Window E",          24, 18, 12,  9),
        CursorSlot("com.apple.cursor.28", "Window E-W",        24, 18, 12,  9),
        CursorSlot("com.apple.cursor.29", "Window NE",         22, 22, 11, 11),
        CursorSlot("com.apple.cursor.30", "Window NE-SW",      22, 22, 11, 11),
        CursorSlot("com.apple.cursor.31", "Window N",          18, 28,  9, 14),
        CursorSlot("com.apple.cursor.32", "Window N-S",        18, 28,  9, 14),
        CursorSlot("com.apple.cursor.33", "Window NW",         22, 22, 11, 11),
        CursorSlot("com.apple.cursor.34", "Window NW-SE",      22, 22, 11, 11),
        CursorSlot("com.apple.cursor.35", "Window SE",         22, 22, 11, 11),
        CursorSlot("com.apple.cursor.36", "Window S",          18, 28,  9, 14),
        CursorSlot("com.apple.cursor.37", "Window SW",         22, 22, 11, 11),
        CursorSlot("com.apple.cursor.38", "Window W",          24, 18, 12,  9),
        CursorSlot("com.apple.cursor.39", "Resize Square",     24, 24, 12, 12),
        CursorSlot("com.apple.cursor.40", "Help",              18, 18,  9,  9),
        CursorSlot("com.apple.cursor.41", "Cell",              18, 18,  9,  9),
        CursorSlot("com.apple.cursor.42", "Zoom In",           28, 26, 12, 11),
        CursorSlot("com.apple.cursor.43", "Zoom Out",          28, 26, 12, 11),

        // The CoreGraphics system cursors. Writes to the legacy "Arrow" and
        // "IBeam" names are silently discarded on macOS 26, but the ArrowS and
        // IBeamS variants (system cursor ids 100 and 101, which only turn up if
        // you scan CGSCursorNameForSystemCursor past 45) accept them and drive
        // the same on-screen cursor.
        CursorSlot("com.apple.coregraphics.ArrowS",   "Arrow",            28, 40,  5,  5),
        CursorSlot("com.apple.coregraphics.IBeamS",   "I-Beam",           23, 22, 12, 11),
        CursorSlot("com.apple.coregraphics.Wait",     "Wait (beachball)", 24, 24, 12, 11),
        CursorSlot("com.apple.coregraphics.ArrowCtx", "Arrow Context",     8,  8,  1,  1),
        CursorSlot("com.apple.coregraphics.IBeamXOR", "I-Beam XOR",        8,  8,  1,  1),
        CursorSlot("com.apple.coregraphics.Alias",    "Alias",             8,  8,  1,  1),
        CursorSlot("com.apple.coregraphics.Copy",     "Copy",              8,  8,  1,  1),
        CursorSlot("com.apple.coregraphics.Move",     "Move",             11, 16,  1,  1),
        CursorSlot("com.apple.coregraphics.Empty",    "Empty",             4,  4,  1,  1),
    ]

    /// Old identifiers the window server will not accept, mapped to the variant
    /// that works. Capes in the wild are written against the old names, so
    /// everything resolves through here before being applied.
    public static let legacyAliases: [String: String] = [
        "com.apple.coregraphics.Arrow": "com.apple.coregraphics.ArrowS",
        "com.apple.coregraphics.IBeam": "com.apple.coregraphics.IBeamS",
    ]

    /// Resolves a legacy identifier to the one that can actually be written.
    public static func resolve(_ identifier: String) -> String {
        legacyAliases[identifier] ?? identifier
    }

    /// Kept so capes mentioning them still parse. Both forward to a writable
    /// variant via `legacyAliases`.
    public static let locked: [CursorSlot] = [
        CursorSlot("com.apple.coregraphics.Arrow", "Arrow (legacy name)", 28, 40, 5, 5),
        CursorSlot("com.apple.coregraphics.IBeam", "I-Beam (legacy name)", 23, 22, 12, 11),
    ]

    public static let all: [CursorSlot] = writable + locked

    /// Looks up a slot, following legacy aliases so a cape written against
    /// "com.apple.coregraphics.Arrow" lands on the writable ArrowS slot.
    public static func slot(for identifier: String) -> CursorSlot? {
        let resolved = resolve(identifier)
        return writable.first { $0.identifier == resolved }
            ?? all.first { $0.identifier == identifier }
    }

    /// AppKit cursors that map onto each slot, for explaining where a cursor
    /// shows up. Verified by tracing `SLSSetRegisteredCursor` from AppKit.
    public static let appKitUsage: [String: String] = [
        "com.apple.cursor.2":  "NSCursor.dragLink",
        "com.apple.cursor.3":  "NSCursor.operationNotAllowed",
        "com.apple.cursor.5":  "NSCursor.dragCopy",
        "com.apple.cursor.11": "NSCursor.closedHand",
        "com.apple.cursor.12": "NSCursor.openHand",
        "com.apple.cursor.13": "NSCursor.pointingHand",
        "com.apple.cursor.17": "NSCursor.resizeLeft",
        "com.apple.cursor.18": "NSCursor.resizeRight",
        "com.apple.cursor.19": "NSCursor.resizeLeftRight",
        "com.apple.cursor.20": "NSCursor.crosshair",
        "com.apple.cursor.21": "NSCursor.resizeUp",
        "com.apple.cursor.22": "NSCursor.resizeDown",
        "com.apple.cursor.23": "NSCursor.resizeUpDown",
        "com.apple.cursor.24": "NSCursor.contextualMenu",
        "com.apple.cursor.25": "NSCursor.disappearingItem",
        "com.apple.cursor.26": "NSCursor.IBeamForVerticalLayout",
        "com.apple.coregraphics.ArrowS": "NSCursor.arrow",
        "com.apple.coregraphics.IBeamS": "NSCursor.IBeam",
    ]
}

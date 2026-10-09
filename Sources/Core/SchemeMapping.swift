import Foundation

/// Maps human / Windows cursor-scheme names onto macOS cursor identifiers.
///
/// Windows packs and most downloadable cursor sets are named after the Windows
/// scheme roles, so this is what lets a folder of .ani files import in one go.
public enum SchemeMapping {

    /// Lowercased source name -> macOS identifier.
    private static let table: [String: String] = [
        // Windows scheme roles
        "link":                   "com.apple.cursor.13",
        "link select":            "com.apple.cursor.13",
        "hand":                   "com.apple.cursor.13",
        "busy":                   "com.apple.cursor.4",
        "wait":                   "com.apple.cursor.4",
        "work":                   "com.apple.cursor.4",
        "working in background":  "com.apple.cursor.4",
        "unavailable":            "com.apple.cursor.3",
        "no":                     "com.apple.cursor.3",
        "precision select":       "com.apple.cursor.7",
        "precision":              "com.apple.cursor.7",
        "crosshair":              "com.apple.cursor.7",
        "help select":            "com.apple.cursor.40",
        "help":                   "com.apple.cursor.40",
        "move":                   "com.apple.cursor.11",
        "vertical resize":        "com.apple.cursor.23",
        "horizontal resize":      "com.apple.cursor.19",
        "diagonal resize 1":      "com.apple.cursor.30",
        "diagonal resize 2":      "com.apple.cursor.34",
        "alternate":              "com.apple.cursor.24",
        "alternate select":       "com.apple.cursor.24",
        "location select":        "com.apple.cursor.41",
        "person select":          "com.apple.cursor.42",
        "handwriting":            "com.apple.cursor.20",
        // macOS-flavoured names
        "pointing":               "com.apple.cursor.13",
        "pointing hand":          "com.apple.cursor.13",
        "open hand":              "com.apple.cursor.12",
        "closed hand":            "com.apple.cursor.11",
        "forbidden":              "com.apple.cursor.3",
        "context menu":           "com.apple.cursor.24",
        "poof":                   "com.apple.cursor.25",
        "zoom in":                "com.apple.cursor.42",
        "zoom out":               "com.apple.cursor.43",
        "cell":                   "com.apple.cursor.41",
        "drag copy":              "com.apple.cursor.5",
        "drag link":              "com.apple.cursor.2",
        "resize n-s":             "com.apple.cursor.23",
        "resize w-e":             "com.apple.cursor.19",
        // Simplified Chinese, as shipped by most Chinese cursor packs
        "链接选择":             "com.apple.cursor.13",
        "链接":                 "com.apple.cursor.13",
        "忙":                     "com.apple.cursor.4",
        "后台":                 "com.apple.cursor.4",
        "不可用":               "com.apple.cursor.3",
        "精准选择":             "com.apple.cursor.7",
        "精确选择":             "com.apple.cursor.7",
        "帮助":                 "com.apple.cursor.40",
        "移动":                 "com.apple.cursor.11",
        "个人":                 "com.apple.cursor.42",
        "位置":                 "com.apple.cursor.41",
        "候选":                 "com.apple.cursor.24",
        "手写":                 "com.apple.cursor.20",
        "垂直调整":             "com.apple.cursor.23",
        "垂直调整大小":         "com.apple.cursor.23",
        "水平调整":             "com.apple.cursor.19",
        "水平调整大小":         "com.apple.cursor.19",
        "对角线调整大小1":      "com.apple.cursor.30",
        "对角线调整大小2":      "com.apple.cursor.34",
    ]

    /// Names that refer to cursors macOS will not let us replace.
    private static let lockedNames: Set<String> = [
        "normal select", "normal", "arrow", "standard", "default", "pointer",
        "text select", "text", "ibeam", "i-beam", "i beam", "i beam (text select)",
        "beachball", "spinning wait",
        "正常选择", "文本选择", "箭头", "指针",
    ]

    public enum Match {
        case identifier(String)
        case locked(String)
        case unknown
    }

    public static func match(_ rawName: String) -> Match {
        let key = normalize(rawName)

        // Exact, then with any trailing variant number dropped ("帮助1", "Busy 2"),
        // then the longest known name the input starts with, which catches
        // things like "正常选择-重制" and "I Beam (Text Select)".
        for candidate in [key, stripTrailingDigits(key)] {
            if let hit = lookup(candidate) { return hit }
        }
        let names = table.keys.map { ($0, true) } + lockedNames.map { ($0, false) }
        let prefixes = names
            .filter { key.hasPrefix($0.0) }
            .sorted { $0.0.count > $1.0.count }
        if let best = prefixes.first {
            return best.1 ? .identifier(table[best.0]!) : .locked(best.0)
        }
        return .unknown
    }

    private static func lookup(_ key: String) -> Match? {
        if let id = table[key] { return .identifier(id) }
        if lockedNames.contains(key) { return .locked(key) }
        if let slot = CursorCatalog.writable.first(where: { normalize($0.name) == key }) {
            return .identifier(slot.identifier)
        }
        if let slot = CursorCatalog.locked.first(where: { normalize($0.name) == key }) {
            return .locked(slot.name)
        }
        return nil
    }

    private static func stripTrailingDigits(_ s: String) -> String {
        var out = s
        while let last = out.last, last.isNumber { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Names that describe a cursor another name describes better. When two
    /// sources land on the same slot, the lower priority number wins, so a pack
    /// containing both 忙 (busy) and 后台 (working in background) gives the
    /// Busy slot to 忙 no matter which order the directory is scanned in.
    private static let secondaryNames: Set<String> = [
        "后台", "work", "working in background", "alternate", "链接",
    ]

    /// 0 = best. Used to resolve two sources claiming one cursor.
    public static func priority(_ rawName: String) -> Int {
        let key = normalize(rawName)
        if secondaryNames.contains(key) { return 2 }
        if table[key] != nil || lockedNames.contains(key) { return 0 }
        if table[stripTrailingDigits(key)] != nil { return 1 }
        return 3
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
         .replacingOccurrences(of: "_", with: " ")
         .replacingOccurrences(of: "-", with: " ")
         .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

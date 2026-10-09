import Foundation

/// Named cursor themes kept on disk so they can be switched between.
///
/// Each profile is a `.cape` in Application Support, which means profiles are
/// the same format as the themes people download and share.
public final class ProfileStore {

    public struct Profile: Identifiable, Hashable {
        public let id: String          // file name without extension
        public let name: String
        public let url: URL?           // nil for the built-in stock profile
        /// The stock macOS cursors. Selecting it just clears every override.
        public var isSystemDefault: Bool { url == nil }

        public static let systemDefault = Profile(id: "__system__",
                                                  name: "macOS 默认指针",
                                                  url: nil)
    }

    public static let shared = ProfileStore()

    public let directory: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MouseCapeRevamp/Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The stock profile always comes first so there is a way back.
    public func profiles() -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let saved = files
            .filter { $0.pathExtension.lowercased() == "cape" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Profile(id: $0.deletingPathExtension().lastPathComponent,
                           name: (try? Cape.load(from: $0).name) ?? $0.deletingPathExtension().lastPathComponent,
                           url: $0) }
        return [.systemDefault] + saved
    }

    @discardableResult
    public func save(_ cape: Cape, as name: String) throws -> Profile {
        let safe = name.replacingOccurrences(of: "/", with: "-")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = safe.isEmpty ? UUID().uuidString : safe
        let url = directory.appendingPathComponent("\(fileName).cape")
        var cape = cape
        cape.name = safe.isEmpty ? cape.name : safe
        try cape.write(to: url)
        return Profile(id: fileName, name: cape.name, url: url)
    }

    public func delete(_ profile: Profile) {
        guard let url = profile.url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Shared settings

    /// The CLI has no bundle identifier, so UserDefaults.standard is a
    /// different domain for it than for the app. Both read and write this
    /// suite instead, otherwise the two disagree about which profile is live.
    public static let defaults = UserDefaults(suiteName: "com.mousecaperevamp") ?? .standard

    private static let activeKey = "ActiveProfileID"
    private static let baseSizeKey = "CursorBaseSize"

    public var activeProfileID: String? {
        get { Self.defaults.string(forKey: Self.activeKey) }
        set { Self.defaults.set(newValue, forKey: Self.activeKey) }
    }

    /// Longest-edge render size in points, shared by the app and the CLI.
    public var baseSize: Double {
        get {
            let v = Self.defaults.double(forKey: Self.baseSizeKey)
            return v > 0 ? v : Double(CursorArt.baseSize)
        }
        set { Self.defaults.set(newValue, forKey: Self.baseSizeKey) }
    }
}

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

    // MARK: - Remembering the active profile

    private static let activeKey = "ActiveProfileID"

    public var activeProfileID: String? {
        get { UserDefaults.standard.string(forKey: Self.activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.activeKey) }
    }
}

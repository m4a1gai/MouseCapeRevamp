import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One source file lined up against the cursor slot it will replace.
struct PendingCursor: Identifiable {
    enum Status {
        case ready
        case locked(String)
        case unmatched
        case failed(String)
        case claimed(String)
    }
    let id = UUID()
    let sourceName: String
    let slot: CursorSlot?
    let art: CursorArt?
    var status: Status

    var isApplicable: Bool {
        if case .ready = status { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// Shared so the app delegate's file-open handler and the view agree.
    static let shared = AppModel()

    @Published var pending: [PendingCursor] = []
    @Published var themeName: String = ""
    @Published var activeCount: Int = 0
    @Published var message: String = ""
    @Published var pointSizeScale: Double = 1.0

    @Published var profiles: [ProfileStore.Profile] = []
    @Published var selection: ProfileStore.Profile.ID?
    /// True when `pending` came from an import and has not been saved yet.
    @Published var isUnsavedImport = false

    private let engine = CursorEngine()
    private let store = ProfileStore.shared

    init() {
        refreshProfiles()
        refreshActive()
        // Show the remembered profile's contents, but only if its cursors are
        // actually still registered - otherwise the sidebar would claim a theme
        // is active when the system is back to stock.
        if activeCount > 0, let id = store.activeProfileID,
           let profile = profiles.first(where: { $0.id == id }), let url = profile.url {
            selection = id
            loadCape(url)
        } else {
            selection = ProfileStore.Profile.systemDefault.id
        }
    }

    func refreshActive() {
        activeCount = CursorCatalog.writable.filter { engine.isRegistered($0.identifier) }.count
    }

    func refreshProfiles() { profiles = store.profiles() }

    func profile(for id: ProfileStore.Profile.ID?) -> ProfileStore.Profile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Profiles

    /// Shows a profile's contents and applies it.
    func selectProfile(_ profile: ProfileStore.Profile) {
        selection = profile.id
        store.activeProfileID = profile.id
        isUnsavedImport = false

        if profile.isSystemDefault {
            pending = []
            themeName = profile.name
            restoreAll()
            return
        }
        guard let url = profile.url else { return }
        // Clear whatever the last profile registered, or its cursors linger
        // alongside the new one.
        _ = engine.restoreAll()
        loadCape(url)
        applyAll()
    }

    func saveImportAsProfile(named name: String) {
        var cape = Cape(name: name)
        for item in pending where item.isApplicable {
            if let slot = item.slot, let art = item.art { cape.cursors[slot.identifier] = art }
        }
        guard !cape.cursors.isEmpty else { message = "没有可保存的光标。"; return }
        do {
            let profile = try store.save(cape, as: name)
            refreshProfiles()
            selection = profile.id
            store.activeProfileID = profile.id
            isUnsavedImport = false
            themeName = profile.name
            message = "已保存配置“\(profile.name)”。"
        } catch {
            message = error.localizedDescription
        }
    }

    func deleteProfile(_ profile: ProfileStore.Profile) {
        store.delete(profile)
        refreshProfiles()
        if selection == profile.id {
            selection = ProfileStore.Profile.systemDefault.id
            pending = []
        }
    }

    // MARK: - Importing

    func load(url: URL) {
        if url.pathExtension.lowercased() == "cape" { loadCape(url) } else { loadFolderOrFile(url) }
        isUnsavedImport = true
        selection = nil
        refreshActive()
    }

    private func loadCape(_ url: URL) {
        do {
            let cape = try Cape.load(from: url)
            themeName = cape.name
            pending = cape.cursors
                .sorted { $0.key < $1.key }
                .map { identifier, art in
                    guard let slot = CursorCatalog.slot(for: identifier) else {
                        return PendingCursor(sourceName: identifier, slot: nil, art: art, status: .unmatched)
                    }
                    return PendingCursor(sourceName: slot.name, slot: slot, art: art,
                                         status: slot.isProtected ? .locked(slot.name) : .ready)
                }
            message = "已载入“\(cape.name)”。"
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadFolderOrFile(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        var entries: [URL]
        if isDir.boolValue {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            // A folder of numbered frames is itself one cursor, not a theme.
            let looksLikeFrames = children.allSatisfy {
                ["gif", "png", "tiff", "jpg", "jpeg"].contains($0.pathExtension.lowercased())
            } && children.count > 2
                && children.contains { $0.lastPathComponent.lowercased().contains("frame") }
            entries = looksLikeFrames ? [url] : children
            themeName = url.lastPathComponent
        } else {
            entries = [url]
            themeName = url.deletingPathExtension().lastPathComponent
        }

        entries = entries.sorted {
            let a = $0.deletingPathExtension().lastPathComponent
            let b = $1.deletingPathExtension().lastPathComponent
            let pa = SchemeMapping.priority(a), pb = SchemeMapping.priority(b)
            return pa == pb ? a < b : pa < pb
        }

        var claimed: [String: String] = [:]
        var result: [PendingCursor] = []

        for entry in entries {
            let base = entry.deletingPathExtension().lastPathComponent
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &dir)
            let ext = entry.pathExtension.lowercased()
            guard dir.boolValue || ["ani", "gif", "png", "cur", "tiff"].contains(ext) else { continue }

            switch SchemeMapping.match(base) {
            case .locked(let what):
                result.append(PendingCursor(sourceName: base, slot: nil, art: nil, status: .locked(what)))
            case .unknown:
                result.append(PendingCursor(sourceName: base, slot: nil, art: nil, status: .unmatched))
            case .identifier(let id):
                guard let slot = CursorCatalog.slot(for: id) else { continue }
                if let owner = claimed[id] {
                    result.append(PendingCursor(sourceName: base, slot: slot, art: nil, status: .claimed(owner)))
                    continue
                }
                do {
                    let art = try CursorImporter.importArt(at: entry)
                    claimed[id] = base
                    result.append(PendingCursor(sourceName: base, slot: slot, art: art, status: .ready))
                } catch {
                    result.append(PendingCursor(sourceName: base, slot: slot, art: nil,
                                                status: .failed(error.localizedDescription)))
                }
            }
        }
        pending = result
        let ready = result.filter(\.isApplicable).count
        message = "\(ready) 个光标可应用。"
    }

    // MARK: - Applying

    func applyAll() {
        var ok = 0, bad = 0
        for item in pending where item.isApplicable {
            guard let slot = item.slot, let art = item.art else { continue }
            let size = art.fittedPointSize(base: CursorArt.baseSize * pointSizeScale)
            do { try engine.apply(art, to: slot, pointSize: size); ok += 1 }
            catch { bad += 1 }
        }
        refreshActive()
        message = bad == 0 ? "已应用 \(ok) 个光标。" : "已应用 \(ok) 个，\(bad) 个失败。"
    }

    func restoreAll() {
        _ = engine.restoreAll()
        refreshActive()
        message = "已还原系统默认光标。"
    }

    func exportCape(to url: URL) {
        var cape = Cape(name: themeName.isEmpty ? "Untitled" : themeName)
        for item in pending where item.isApplicable {
            if let slot = item.slot, let art = item.art { cape.cursors[slot.identifier] = art }
        }
        do { try cape.write(to: url); message = "已导出 \(cape.cursors.count) 个光标。" }
        catch { message = error.localizedDescription }
    }

    // MARK: - Test pane

    /// Slots that currently have themed art registered.
    func liveSlots() -> [CursorSlot] {
        CursorCatalog.writable.filter { engine.isRegistered($0.identifier) }
    }

    /// The NSCursor to show for a slot in the test pane.
    ///
    /// Where AppKit exposes the cursor we return its real accessor, so the pane
    /// shows the genuine system cursor resolving through the themed
    /// registration. The rest have no AppKit API and are rebuilt from the art
    /// the window server currently holds.
    func nsCursor(for slot: CursorSlot) -> NSCursor {
        switch slot.identifier {
        case "com.apple.cursor.2":  return .dragLink
        case "com.apple.cursor.3":  return .operationNotAllowed
        case "com.apple.cursor.5":  return .dragCopy
        case "com.apple.cursor.11": return .closedHand
        case "com.apple.cursor.12": return .openHand
        case "com.apple.cursor.13": return .pointingHand
        case "com.apple.cursor.17": return .resizeLeft
        case "com.apple.cursor.18": return .resizeRight
        case "com.apple.cursor.19": return .resizeLeftRight
        case "com.apple.cursor.20": return .crosshair
        case "com.apple.cursor.21": return .resizeUp
        case "com.apple.cursor.22": return .resizeDown
        case "com.apple.cursor.23": return .resizeUpDown
        case "com.apple.cursor.24": return .contextualMenu
        case "com.apple.cursor.25": return .disappearingItem
        case "com.apple.cursor.26": return .iBeamCursorForVerticalLayout
        default: return cursorFromRegisteredArt(slot)
        }
    }

    private func cursorFromRegisteredArt(_ slot: CursorSlot) -> NSCursor {
        guard let info = engine.registeredArt(for: slot.identifier),
              let rep = info.reps.first, info.frameCount > 0,
              let first = rep.cropping(to: CGRect(x: 0, y: 0,
                                                  width: rep.width,
                                                  height: rep.height / info.frameCount))
        else { return .arrow }
        let image = NSImage(cgImage: first,
                            size: NSSize(width: info.size.width, height: info.size.height))
        return NSCursor(image: image, hotSpot: NSPoint(x: info.hotSpot.x, y: info.hotSpot.y))
    }

    /// First frame of whatever is registered, for the test tiles.
    func liveThumbnail(for slot: CursorSlot) -> CGImage? {
        guard let art = engine.registeredArt(for: slot.identifier),
              let rep = art.reps.first, art.frameCount > 0 else { return nil }
        let fh = rep.height / art.frameCount
        return rep.cropping(to: CGRect(x: 0, y: 0, width: rep.width, height: fh))
    }
}

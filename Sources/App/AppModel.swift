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

    private let engine = CursorEngine()

    init() { refreshActive() }

    func refreshActive() {
        activeCount = CursorCatalog.writable.filter { engine.isRegistered($0.identifier) }.count
    }

    /// Currently registered art, used to preview what is live on the system.
    func liveArt(for slot: CursorSlot) -> CGImage? {
        guard let art = engine.registeredArt(for: slot.identifier),
              let rep = art.reps.first, art.frameCount > 0 else { return nil }
        let fh = rep.height / art.frameCount
        return rep.cropping(to: CGRect(x: 0, y: 0, width: rep.width, height: fh))
    }

    // MARK: - Importing

    func load(url: URL) {
        if url.pathExtension.lowercased() == "cape" { loadCape(url) } else { loadFolderOrFile(url) }
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
            message = "Loaded cape “\(cape.name)”."
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
        message = "\(ready) cursor\(ready == 1 ? "" : "s") ready to apply."
    }

    // MARK: - Applying

    func applyAll() {
        var ok = 0, bad = 0
        for item in pending where item.isApplicable {
            guard let slot = item.slot, let art = item.art else { continue }
            let size = CGSize(width: slot.defaultSize.width * pointSizeScale,
                              height: slot.defaultSize.height * pointSizeScale)
            do { try engine.apply(art, to: slot, pointSize: size); ok += 1 }
            catch { bad += 1 }
        }
        refreshActive()
        message = bad == 0 ? "Applied \(ok) cursor\(ok == 1 ? "" : "s")."
                           : "Applied \(ok), \(bad) failed."
    }

    func restoreAll() {
        _ = engine.restoreAll()
        refreshActive()
        message = "Restored the system cursors."
    }

    func exportCape(to url: URL) {
        var cape = Cape(name: themeName.isEmpty ? "Untitled" : themeName)
        for item in pending where item.isApplicable {
            if let slot = item.slot, let art = item.art { cape.cursors[slot.identifier] = art }
        }
        do { try cape.write(to: url); message = "Exported \(cape.cursors.count) cursors." }
        catch { message = error.localizedDescription }
    }
}

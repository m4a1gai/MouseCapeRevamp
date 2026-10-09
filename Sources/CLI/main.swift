import AppKit
import Foundation

let engine = CursorEngine()
var args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    mousecape — cursor theming for macOS 26

    USAGE
      mousecape list                       Show every cursor slot and its state
      mousecape apply <path> [--size N]    Apply a folder, .ani, .gif or .cape
      mousecape apply <src> --to <id>      Apply one source to one identifier
      mousecape export <dir> <out.cape>    Package a folder into a .cape
      mousecape restore                    Restore all system cursors
      mousecape resnapshot                 Re-snapshot the stock cursors
      mousecape profiles                   List saved profiles
      mousecape save <dir> <name>          Save a folder as a named profile
      mousecape use <name> [--size N]       Switch to a saved profile
      mousecape status                     Show what is currently overridden

    <path> may be a .cape file, or a directory holding .ani files, animated
    GIFs, or subfolders of numbered frames. Names are matched against the
    Windows cursor-scheme roles and the macOS cursor names.
    """)
    exit(1)
}

func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

guard let command = args.first else { usage() }
args.removeFirst()

switch command {

case "list":
    print("WRITABLE (\(CursorCatalog.writable.count) slots)")
    for slot in CursorCatalog.writable {
        let mark = ProfileStore.shared.themedIdentifiers.contains(slot.identifier) ? "●" : "○"
        let use = CursorCatalog.appKitUsage[slot.identifier].map { "  — \($0)" } ?? ""
        print(String(format: "  %@ %-22s %-22s %.0fx%.0f%@", mark,
                     (slot.name as NSString).utf8String!,
                     (slot.identifier as NSString).utf8String!,
                     slot.defaultSize.width, slot.defaultSize.height, use))
    }
    print("\nLOCKED BY macOS (cannot be replaced)")
    for slot in CursorCatalog.locked {
        print("  ✕ \(slot.name)  (\(slot.identifier))")
    }

case "status":
    let overridden = engine.themedSlots()
    if overridden.isEmpty {
        print("No cursor overrides active — all stock.")
    } else {
        print("\(overridden.count) cursor(s) overridden:")
        for slot in overridden {
            if let art = engine.registeredArt(for: slot.identifier) {
                print(String(format: "  %-22s %.0fx%.0f  %d frame(s)  %.3fs",
                             (slot.name as NSString).utf8String!,
                             art.size.width, art.size.height, art.frameCount, art.duration))
            }
        }
    }
    print("cursor seed: \(engine.seed)")

case "restore":
    print(engine.restoreAll() ? "Restored all system cursors." : "Restore failed.")

case "apply":
    guard let pathArg = args.first else { usage() }
    let explicitID = value(for: "--to")
    let sizeOverride = value(for: "--size").flatMap { Double($0) }
    let url = URL(fileURLWithPath: (pathArg as NSString).expandingTildeInPath)

    var applied = 0, skipped = 0, failed = 0
    var claimed: [String: String] = [:]   // identifier -> source that claimed it

    func applyArt(_ art: CursorArt, to identifier: String, label: String) {
        if let owner = claimed[identifier] {
            print("  – \(label): “\(owner)” already claimed that cursor, skipped")
            skipped += 1; return
        }
        guard let slot = CursorCatalog.slot(for: identifier) else {
            print("  ? \(label): unknown identifier \(identifier)"); failed += 1; return
        }
        guard !slot.isProtected else {
            print("  ✕ \(label) → \(slot.name): locked by macOS, skipped"); skipped += 1; return
        }
        let size = art.fittedPointSize(base: CGFloat(sizeOverride ?? ProfileStore.shared.baseSize))
        do {
            let n = try engine.apply(art, to: slot, pointSize: size)
            print("  ✓ \(label) → \(slot.name)  (\(n) frame\(n == 1 ? "" : "s"))")
            claimed[identifier] = label
            applied += 1
        } catch {
            print("  ✗ \(label) → \(slot.name): \(error.localizedDescription)")
            failed += 1
        }
    }

    if url.pathExtension.lowercased() == "cape" {
        let cape = try Cape.load(from: url)
        print("Applying cape “\(cape.name)” by \(cape.author)")
        for (identifier, art) in cape.cursors.sorted(by: { $0.key < $1.key }) {
            applyArt(art, to: identifier, label: identifier)
        }
    } else if let id = explicitID {
        applyArt(try CursorImporter.importArt(at: url), to: id, label: url.lastPathComponent)
    } else {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else {
            print("Need --to <identifier> when applying a single file."); exit(1)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        print("Scanning \(url.lastPathComponent)…")
        // Best match first so a strong name claims a slot before a weaker one.
        let ordered = entries.sorted {
            let a = $0.deletingPathExtension().lastPathComponent
            let b = $1.deletingPathExtension().lastPathComponent
            let pa = SchemeMapping.priority(a), pb = SchemeMapping.priority(b)
            return pa == pb ? a < b : pa < pb
        }
        for entry in ordered {
            let base = entry.deletingPathExtension().lastPathComponent
            let ext = entry.pathExtension.lowercased()
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &dir)
            guard dir.boolValue || ["ani", "gif", "png", "cur"].contains(ext) else { continue }

            switch SchemeMapping.match(base) {
            case .identifier(let id):
                do { applyArt(try CursorImporter.importArt(at: entry), to: id, label: base) }
                catch { print("  ✗ \(base): \(error.localizedDescription)"); failed += 1 }
            case .locked(let what):
                print("  ✕ \(base) → \(what): locked by macOS, skipped"); skipped += 1
            case .unknown:
                print("  – \(base): no matching macOS cursor, skipped"); skipped += 1
            }
        }
    }
    print("\n\(applied) applied, \(skipped) skipped, \(failed) failed.")
    if applied > 0 { print("Run `mousecape restore` to undo.") }

case "resnapshot":
    // Use after a logout/restart, when the system cursors are known pristine.
    StockBackup.shared.forget()
    engine.restoreAll()
    var saved = 0
    for slot in CursorCatalog.writable where StockBackup.needsBackup(slot) {
        StockBackup.shared.captureIfNeeded(slot, engine: engine)
        if StockBackup.shared.hasBackup(for: slot.identifier) { saved += 1 }
    }
    print("已重新抓取 \(saved) 个系统原始光标作为还原基准。")

case "profiles":
    for p in ProfileStore.shared.profiles() {
        let mark = p.id == ProfileStore.shared.activeProfileID ? "●" : " "
        print("  \(mark) \(p.name)\(p.isSystemDefault ? "  (内置)" : "")")
    }

case "save":
    guard args.count >= 2 else { usage() }
    let src = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
    let name = args[1]
    var cape = Cape(name: name)
    let items = (try? FileManager.default.contentsOfDirectory(
        at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    for entry in items.sorted(by: {
        let a = $0.deletingPathExtension().lastPathComponent
        let b = $1.deletingPathExtension().lastPathComponent
        let pa = SchemeMapping.priority(a), pb = SchemeMapping.priority(b)
        return pa == pb ? a < b : pa < pb
    }) {
        let base = entry.deletingPathExtension().lastPathComponent
        guard case .identifier(let id) = SchemeMapping.match(base),
              cape.cursors[id] == nil,
              let art = try? CursorImporter.importArt(at: entry) else { continue }
        cape.cursors[id] = art
    }
    let saved = try ProfileStore.shared.save(cape, as: name)
    print("已保存配置“\(saved.name)”，含 \(cape.cursors.count) 个光标。")

case "use":
    let useSize = value(for: "--size").flatMap { Double($0) }
    guard let name = args.first else { usage() }
    if let useSize { ProfileStore.shared.baseSize = useSize }
    let all = ProfileStore.shared.profiles()
    guard let p = all.first(where: { $0.name == name || $0.id == name }) else {
        print("找不到配置“\(name)”。可用：")
        all.forEach { print("  \($0.name)") }
        exit(1)
    }
    if p.isSystemDefault {
        print(engine.restoreAll() ? "已还原系统默认指针。" : "还原失败。")
    } else if let url = p.url {
        _ = engine.restoreAll()   // don't leave the previous profile mixed in
        let cape = try Cape.load(from: url)
        var n = 0
        for (identifier, art) in cape.cursors {
            guard let slot = CursorCatalog.slot(for: identifier), !slot.isProtected else { continue }
            let size = art.fittedPointSize(base: CGFloat(ProfileStore.shared.baseSize))
            if (try? engine.apply(art, to: slot, pointSize: size)) != nil { n += 1 }
        }
        print("已切换到“\(p.name)”，应用 \(n) 个光标。")
    }
    ProfileStore.shared.activeProfileID = p.id

case "export":
    guard args.count >= 2 else { usage() }
    let src = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
    let out = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    var cape = Cape(name: src.lastPathComponent)
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    for entry in entries {
        let base = entry.deletingPathExtension().lastPathComponent
        guard case .identifier(let id) = SchemeMapping.match(base) else { continue }
        if let art = try? CursorImporter.importArt(at: entry) { cape.cursors[id] = art }
    }
    try cape.write(to: out)
    print("Wrote \(cape.cursors.count) cursor(s) to \(out.path)")

default:
    usage()
}

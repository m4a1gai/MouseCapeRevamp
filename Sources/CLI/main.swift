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
        let mark = engine.isRegistered(slot.identifier) ? "●" : "○"
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
    let overridden = CursorCatalog.writable.filter { engine.isRegistered($0.identifier) }
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
        let size = sizeOverride.map { CGSize(width: $0, height: $0 * slot.defaultSize.height / slot.defaultSize.width) }
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

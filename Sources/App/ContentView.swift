import SwiftUI
import UniformTypeIdentifiers

/// Plays a cursor's frames at its real frame duration.
struct CursorPreview: View {
    let art: CursorArt?
    var side: CGFloat = 34

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let frame = currentFrame(at: context.date) {
                    Image(decorative: frame, scale: 1)
                        .interpolation(.high)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    Image(systemName: "questionmark")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
        }
    }

    private func currentFrame(at date: Date) -> CGImage? {
        guard let art, !art.frames.isEmpty else { return nil }
        guard art.frames.count > 1, art.frameDuration > 0 else { return art.frames.first }
        let step = Int(date.timeIntervalSinceReferenceDate / art.frameDuration)
        return art.frames[((step % art.frames.count) + art.frames.count) % art.frames.count]
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel.shared
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.pending.isEmpty { dropZone } else { cursorList }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 520)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.load(url: url) }
            }
            return true
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.themeName.isEmpty ? "MouseCape Revamp" : model.themeName)
                    .font(.headline)
                Text(model.activeCount == 0
                     ? "All cursors are stock"
                     : "\(model.activeCount) cursor\(model.activeCount == 1 ? "" : "s") themed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { choose() }
            Button("Restore All") { model.restoreAll() }
                .disabled(model.activeCount == 0)
        }
        .padding(14)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a cursor folder, an .ani file, or a .cape here")
                .font(.title3)
            Text("""
                 Folders of .ani files, animated GIFs, or numbered frame images \
                 all work. Names are matched against the Windows cursor roles \
                 and their Chinese equivalents.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
            lockedNotice
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var cursorList: some View {
        List(model.pending) { item in
            HStack(spacing: 12) {
                CursorPreview(art: item.art)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.sourceName).font(.body)
                    Text(subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(item.status)
            }
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text(model.message).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !model.pending.isEmpty {
                Button("Export .cape…") { exportCape() }
                Button("Apply") { model.applyAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.pending.contains(where: \.isApplicable))
            }
        }
        .padding(12)
    }

    private var lockedNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("""
                 macOS 26 no longer lets any app replace the **arrow** or **text \
                 (I-beam)** cursor — the window server silently discards them. \
                 Every other cursor still works.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460)
        .padding(.bottom, 16)
    }

    // MARK: - Helpers

    private func subtitle(for item: PendingCursor) -> String {
        switch item.status {
        case .locked:
            return "Locked by macOS — cannot be replaced"
        case .claimed(let owner):
            return "Already covered by “\(owner)”"
        case .failed(let why):
            return why
        case .unmatched:
            return "No matching macOS cursor"
        case .ready:
            break
        }
        guard let slot = item.slot else { return "No matching macOS cursor" }
        var parts = ["→ \(slot.name)"]
        if let art = item.art, art.frames.count > 1 {
            let capped = min(art.frames.count, CursorEngine.maxFrameCount)
            parts.append(capped < art.frames.count
                         ? "\(capped) of \(art.frames.count) frames"
                         : "\(capped) frames")
        }
        if let use = CursorCatalog.appKitUsage[slot.identifier] { parts.append(use) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func statusBadge(_ status: PendingCursor.Status) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .locked:
            Label("locked", systemImage: "lock.fill")
                .labelStyle(.iconOnly).foregroundStyle(.orange)
                .help("macOS does not allow replacing this cursor")
        case .claimed(let owner):
            Text("dup").font(.caption2).foregroundStyle(.secondary)
                .help("Already claimed by \(owner)")
        case .unmatched:
            Text("—").foregroundStyle(.tertiary)
        case .failed(let why):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).help(why)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a cursor folder, an .ani file, or a .cape"
        if panel.runModal() == .OK, let url = panel.url { model.load(url: url) }
    }

    private func exportCape() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.themeName.isEmpty ? "Theme" : model.themeName).cape"
        if panel.runModal() == .OK, let url = panel.url { model.exportCape(to: url) }
    }
}

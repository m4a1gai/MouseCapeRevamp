import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Animated preview

/// Plays a cursor's frames at its real frame duration.
struct CursorPreview: View {
    let art: CursorArt?
    var side: CGFloat = 34
    /// When set, the frame is drawn at exactly this point size rather than
    /// fitted into a tile, so the swatch matches what lands on screen.
    var explicitSize: CGSize? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
            if let explicitSize {
                ZStack {
                    if let frame = currentFrame(at: context.date) {
                        Image(decorative: frame, scale: 1)
                            .interpolation(.high)
                            .resizable()
                            .frame(width: explicitSize.width, height: explicitSize.height)
                    }
                }
            } else {
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
                        Image(systemName: "questionmark").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: side, height: side)
            }
        }
    }

    private func currentFrame(at date: Date) -> CGImage? {
        guard let art, !art.frames.isEmpty else { return nil }
        guard art.frames.count > 1, art.frameDuration > 0 else { return art.frames.first }
        let step = Int(date.timeIntervalSinceReferenceDate / art.frameDuration)
        return art.frames[((step % art.frames.count) + art.frames.count) % art.frames.count]
    }
}

// MARK: - Hover target that shows a real system cursor

/// An area that shows one themed cursor while the pointer is inside it.
///
/// Both a tracking area and cursor rects are installed: SwiftUI's hosting view
/// manages the pointer aggressively, and neither mechanism alone reliably wins.
struct CursorHoverArea: NSViewRepresentable {
    let cursor: NSCursor

    final class HoverView: NSView {
        var cursor: NSCursor = .arrow {
            didSet { window?.invalidateCursorRects(for: self) }
        }
        private var area: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .cursorUpdate],
                owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }
        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }
        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
    }

    func makeNSView(context: Context) -> NSView {
        let v = HoverView()
        v.cursor = cursor
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HoverView)?.cursor = cursor
    }
}

// MARK: - Main window

struct ContentView: View {
    @StateObject private var model = AppModel.shared
    @State private var isTargeted = false
    @State private var tab = Tab.contents
    @State private var askingName = false
    @State private var newName = ""

    enum Tab: String, CaseIterable { case contents = "主题内容", test = "测试指针" }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                sizeBar
                Divider()
                Group {
                    if tab == .test { TestPane(model: model) }
                    else if model.pending.isEmpty { dropZone }
                    else { cursorList }
                }
                Divider()
                footer
            }
            .navigationTitle(model.themeName.isEmpty ? "MouseCape Revamp" : model.themeName)
            .navigationSubtitle(model.activeCount == 0
                                ? "当前为系统默认指针"
                                : "已生效 \(model.activeCount) 个指针")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { choose() } label: {
                        Label("导入指针…", systemImage: "plus")
                    }
                    .help("导入指针文件夹、.ani 或 .cape")
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                if model.isUnsavedImport {
                    ToolbarItem(placement: .primaryAction) {
                        Button("保存为配置…") {
                            newName = model.themeName
                            askingName = true
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("还原默认") { model.restoreAll() }
                        .disabled(model.activeCount == 0)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.load(url: url); tab = .contents }
            }
            return true
        }
        .alert("保存为配置", isPresented: $askingName) {
            TextField("配置名称", text: $newName)
            Button("保存") { model.saveImportAsProfile(named: newName) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("保存后可以在左侧随时切换回这套指针。")
        }
    }

    // MARK: Sidebar

    private var selectionBinding: Binding<ProfileStore.Profile.ID?> {
        Binding(get: { model.selection },
                set: { id in
                    if let id, let profile = model.profile(for: id) { model.selectProfile(profile) }
                    else { model.selection = id }
                })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // NavigationSplitView does not inset this column below the title
            // bar here, so reserve that strip explicitly or the first row sits
            // under the traffic lights.
            Color.clear.frame(height: 28)

            List(selection: selectionBinding) {
                Section("配置") {
                    ForEach(model.profiles) { profile in
                        HStack(spacing: 8) {
                            Image(systemName: profile.isSystemDefault
                                  ? "arrow.uturn.backward.circle" : "cursorarrow.rays")
                                .foregroundStyle(profile.isSystemDefault
                                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            Text(profile.name).lineLimit(1)
                        }
                        .tag(profile.id)
                        .contextMenu {
                            if !profile.isSystemDefault {
                                Button("删除", role: .destructive) { model.deleteProfile(profile) }
                            }
                        }
                    }
                    if model.isUnsavedImport {
                        HStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down").foregroundStyle(.orange)
                            Text(model.themeName.isEmpty ? "未保存的导入" : model.themeName)
                                .lineLimit(1).italic()
                        }
                        .tag(Optional<ProfileStore.Profile.ID>.none)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
    }

    // MARK: Detail pieces

    /// Size slider plus a preview drawn at the true on-screen size, with the
    /// stock arrow beside it so there is something to judge the scale against.
    private var sizeBar: some View {
        HStack(spacing: 12) {
            Text("大小").font(.callout)
            Slider(value: $model.baseSize, in: AppModel.sizeRange, step: 1)
                .frame(width: 170)
            Text("\(Int(model.baseSize)) pt")
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(.secondary)

            Divider().frame(height: 26)

            previewSwatch(title: "实际大小") {
                if let art = model.previewArt {
                    let size = art.fittedPointSize(base: CGFloat(model.baseSize))
                    CursorPreview(art: art, explicitSize: size)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }

            previewSwatch(title: "系统箭头") {
                Image(nsImage: NSCursor.arrow.image)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func previewSwatch<C: View>(title: String,
                                        @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 3) {
            ZStack { content() }
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("把指针文件夹、.ani 文件或 .cape 拖到这里").font(.title3)
            Text("支持 .ani 动态光标、动图 GIF、编号帧序列文件夹，以及原版 .cape 主题。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
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
                    Text(subtitle(for: item)).font(.caption).foregroundStyle(.secondary)
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
                Button("导出 .cape…") { exportCape() }
                Button("应用") { model.applyAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.pending.contains(where: \.isApplicable))
            }
        }
        .padding(12)
    }

    private var lockedNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("macOS 26 不再允许任何 App 替换**箭头**和**文本光标**，系统会静默丢弃。其余指针都能正常替换。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460).padding(.bottom, 16)
    }

    // MARK: Helpers

    private func subtitle(for item: PendingCursor) -> String {
        switch item.status {
        case .locked:            return "被 macOS 锁定，无法替换"
        case .claimed(let who):  return "已由“\(who)”覆盖"
        case .failed(let why):   return why
        case .unmatched:         return "没有对应的 macOS 指针"
        case .ready:             break
        }
        guard let slot = item.slot else { return "没有对应的 macOS 指针" }
        var parts = ["→ \(slot.name)"]
        if let art = item.art, art.frames.count > 1 {
            let capped = min(art.frames.count, CursorEngine.maxFrameCount)
            parts.append(capped < art.frames.count ? "\(capped)/\(art.frames.count) 帧" : "\(capped) 帧")
        }
        if let use = CursorCatalog.appKitUsage[slot.identifier] { parts.append(use) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func statusBadge(_ status: PendingCursor.Status) -> some View {
        switch status {
        case .ready:   Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .locked:  Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .claimed: Text("重复").font(.caption2).foregroundStyle(.secondary)
        case .unmatched: Text("—").foregroundStyle(.tertiary)
        case .failed(let why):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(why)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择指针文件夹、.ani 文件或 .cape"
        if panel.runModal() == .OK, let url = panel.url { model.load(url: url); tab = .contents }
    }

    private func exportCape() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.themeName.isEmpty ? "Theme" : model.themeName).cape"
        if panel.runModal() == .OK, let url = panel.url { model.exportCape(to: url) }
    }
}

// MARK: - Test pane

/// Hover targets for every cursor that is currently themed, so it is obvious
/// which ones took and what they look like in use.
struct TestPane: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        let slots = model.liveSlots()
        ScrollView {
            if slots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.slash")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text("还没有生效的指针").font(.title3)
                    Text("先在左侧选择一个配置，或导入并应用一套指针。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                Text("把鼠标移到下面任意方块上，就能看到对应的指针。右侧说明了它在系统里什么时候出现。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(slots, id: \.identifier) { slot in
                        tile(for: slot)
                    }
                }
                .padding(14)
            }
        }
    }

    private func tile(for slot: CursorSlot) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumb = model.liveThumbnail(for: slot) {
                    Image(decorative: thumb, scale: 1)
                        .interpolation(.high).resizable()
                        .aspectRatio(contentMode: .fit).padding(8)
                }
                CursorHoverArea(cursor: model.nsCursor(for: slot))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 74)
            Text(slot.name).font(.caption).lineLimit(1)
            Text(whereYouSeeIt(slot)).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(height: 26, alignment: .top)
        }
    }

    /// Plain-language note about where each cursor turns up in daily use.
    private func whereYouSeeIt(_ slot: CursorSlot) -> String {
        switch slot.identifier {
        case "com.apple.cursor.13": return "悬停链接、按钮"
        case "com.apple.cursor.11": return "拖动中（抓取）"
        case "com.apple.cursor.12": return "可拖动区域"
        case "com.apple.cursor.4":  return "App 忙碌中"
        case "com.apple.cursor.3":  return "拖到无效位置"
        case "com.apple.cursor.2":  return "按 ⌥⌘ 拖出替身"
        case "com.apple.cursor.5":  return "按 ⌥ 拖动复制"
        case "com.apple.cursor.24": return "拖动时按 ⌃"
        case "com.apple.cursor.25": return "拖出后消失"
        case "com.apple.cursor.20": return "截图框选、编辑器"
        case "com.apple.cursor.7", "com.apple.cursor.8": return "十字定位"
        case "com.apple.cursor.19", "com.apple.cursor.17", "com.apple.cursor.18":
            return "左右拖拽分隔线"
        case "com.apple.cursor.23", "com.apple.cursor.21", "com.apple.cursor.22":
            return "上下拖拽分隔线"
        case "com.apple.cursor.26": return "竖排文字"
        case "com.apple.cursor.40": return "帮助"
        case "com.apple.cursor.41": return "表格单元格"
        case "com.apple.cursor.42", "com.apple.cursor.43": return "放大 / 缩小"
        default:
            return slot.identifier.hasPrefix("com.apple.cursor.2")
                || slot.identifier.hasPrefix("com.apple.cursor.3")
                ? "窗口边缘调整" : "调整大小"
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// Plays a cursor's frames at its real frame duration.
struct CursorPreview: View {
    let art: CursorArt?
    var side: CGFloat = 44
    /// When set, the frame is drawn at exactly this point size rather than
    /// fitted into a tile, so the swatch matches what lands on screen.
    var explicitSize: CGSize? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
            if let explicitSize {
                if let frame = currentFrame(at: context.date) {
                    Image(decorative: frame, scale: 1)
                        .interpolation(.high).resizable()
                        .frame(width: explicitSize.width, height: explicitSize.height)
                }
            } else {
                ZStack {
                    if let frame = currentFrame(at: context.date) {
                        Image(decorative: frame, scale: 1)
                            .interpolation(.high).resizable()
                            .aspectRatio(contentMode: .fit)
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
        let v = HoverView(); v.cursor = cursor; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HoverView)?.cursor = cursor
    }
}

/// The rounded tile that both grids are built from.
struct TileBackground<C: View>: View {
    var height: CGFloat = 92
    @ViewBuilder var content: () -> C
    var body: some View {
        ZStack { content() }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.07)))
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

    private let cursorColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]
    private let profileColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                headerCard
                sizeBar
                Divider()
                Group {
                    if tab == .test { TestPane(model: model) }
                    else if model.pending.isEmpty { dropZone }
                    else { cursorGrid }
                }
                Divider()
                footer
            }
            .navigationTitle(model.themeName.isEmpty ? "MouseCape Revamp" : model.themeName)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { choose() } label: { Label("导入指针…", systemImage: "plus") }
                        .help("导入指针文件夹、.ani 或 .cape")
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                if model.isUnsavedImport {
                    ToolbarItem(placement: .primaryAction) {
                        Button("保存为配置…") { newName = model.themeName; askingName = true }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("还原默认") { model.restoreAll() }
                        .disabled(model.activeCount == 0)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            // NavigationSplitView does not inset this column below the title
            // bar here, so reserve that strip explicitly.
            Color.clear.frame(height: 30)
            ScrollView {
                LazyVGrid(columns: profileColumns, spacing: 8) {
                    ForEach(model.profiles) { profile in
                        profileTile(profile)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 300)
    }

    private func profileTile(_ profile: ProfileStore.Profile) -> some View {
        let selected = model.selection == profile.id
        return VStack(spacing: 5) {
            TileBackground(height: 58) {
                if profile.isSystemDefault {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 22)).foregroundStyle(.secondary)
                } else if let thumb = model.thumbnails[profile.id] {
                    Image(decorative: thumb, scale: 1)
                        .interpolation(.high).resizable()
                        .aspectRatio(contentMode: .fit).padding(8)
                } else {
                    Image(systemName: "cursorarrow").foregroundStyle(.tertiary)
                }
            }
            Text(profile.name)
                .font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { model.selectProfile(profile) }
        .contextMenu {
            if !profile.isSystemDefault {
                Button("删除", role: .destructive) { model.deleteProfile(profile) }
            }
        }
    }

    // MARK: Detail

    private var headerCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.themeName.isEmpty ? "未选择主题" : model.themeName)
                        .font(.title3.weight(.semibold))
                    if model.activeCount > 0 && !model.isUnsavedImport {
                        Text("已应用")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.3)))
                    }
                }
                Text(model.themeAuthor.isEmpty
                     ? (model.activeCount == 0 ? "当前为系统默认指针"
                                               : "已生效 \(model.activeCount) 个指针")
                     : "作者：\(model.themeAuthor)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    /// Size slider plus a preview drawn at the true on-screen size, with the
    /// stock arrow beside it so there is something to judge the scale against.
    private var sizeBar: some View {
        HStack(spacing: 12) {
            Text("大小").font(.callout)
            Slider(value: $model.baseSize, in: AppModel.sizeRange, step: 1)
                .frame(width: 160)
            Text("\(Int(model.baseSize)) pt")
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
            Divider().frame(height: 26)
            swatch("实际大小") {
                if let art = model.previewArt {
                    CursorPreview(art: art,
                                  explicitSize: art.fittedPointSize(base: CGFloat(model.baseSize)))
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            swatch("系统箭头") { Image(nsImage: NSCursor.arrow.image) }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func swatch<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 3) {
            ZStack { content() }
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var cursorGrid: some View {
        ScrollView {
            LazyVGrid(columns: cursorColumns, spacing: 10) {
                ForEach(model.pending) { item in
                    VStack(spacing: 5) {
                        TileBackground {
                            ZStack {
                                CursorPreview(art: item.art)
                                if case .ready = item.status {} else {
                                    VStack {
                                        HStack {
                                            Spacer()
                                            statusBadge(item.status).padding(5)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                        }
                        Text(label(for: item)).font(.caption).lineLimit(1)
                        Text(sublabel(for: item))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(tooltip(for: item))
                }
            }
            .padding(14)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.pending.isEmpty ? model.message
                 : "\(model.pending.filter(\.isApplicable).count) 个指针  ·  \(model.message)")
                .font(.callout).foregroundStyle(.secondary)
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

    // MARK: Helpers

    private func label(for item: PendingCursor) -> String {
        guard let slot = item.slot else { return item.sourceName }
        return CursorCatalog.displayName(slot)
    }

    private func sublabel(for item: PendingCursor) -> String {
        switch item.status {
        case .locked:            return "系统不允许替换"
        case .claimed(let who):  return "已由「\(who)」覆盖"
        case .failed:            return "读取失败"
        case .unmatched:         return "无对应指针"
        case .ready:
            guard let art = item.art, art.frames.count > 1 else { return item.sourceName }
            let capped = min(art.frames.count, CursorEngine.maxFrameCount)
            return "\(capped) 帧"
        }
    }

    private func tooltip(for item: PendingCursor) -> String {
        var parts = [item.sourceName]
        if let slot = item.slot {
            parts.append(slot.identifier)
            if let use = CursorCatalog.appKitUsage[slot.identifier] { parts.append(use) }
        }
        if case .failed(let why) = item.status { parts.append(why) }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private func statusBadge(_ status: PendingCursor.Status) -> some View {
        switch status {
        case .ready:     EmptyView()
        case .locked:    Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .claimed:   Image(systemName: "square.on.square").foregroundStyle(.secondary)
        case .unmatched: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
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
    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 10)]

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
                Text("把鼠标移到方块上，就能看到对应的真实指针。下面一行说明它在系统里什么时候出现。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(slots, id: \.identifier) { slot in
                        VStack(spacing: 5) {
                            TileBackground {
                                ZStack {
                                    if let thumb = model.liveThumbnail(for: slot) {
                                        Image(decorative: thumb, scale: 1)
                                            .interpolation(.high).resizable()
                                            .aspectRatio(contentMode: .fit).padding(10)
                                    }
                                    CursorHoverArea(cursor: model.nsCursor(for: slot))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            Text(CursorCatalog.displayName(slot)).font(.caption).lineLimit(1)
                            Text(whereYouSeeIt(slot))
                                .font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).lineLimit(2)
                                .frame(height: 26, alignment: .top)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    /// Plain-language note about where each cursor turns up in daily use.
    private func whereYouSeeIt(_ slot: CursorSlot) -> String {
        switch slot.identifier {
        case "com.apple.coregraphics.ArrowS": return "绝大多数界面"
        case "com.apple.coregraphics.IBeamS": return "输入框、选文字"
        case "com.apple.coregraphics.Wait":   return "系统无响应"
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
        default: return "窗口边缘调整"
        }
    }
}

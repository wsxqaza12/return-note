import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BoardView: View {
    @ObservedObject var model: BoardModel
    @ViewState private var sheet: BoardSheet?
    @FocusState private var searchFocused: Bool
    private let accent = Color(nsColor: .controlAccentColor)
    private static let dragType = UTType(exportedAs: "io.github.wsxqaza12.return-note.note-id")

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋標題、下一步或原文", text: $model.query)
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("SearchField")
                    Button { model.toggleSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("關閉搜尋")
                }.padding(10)
                Divider()
            }
            if model.snapshot == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("無法讀取便條").font(.headline)
                    Text(model.notice).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("重新讀取", action: model.reload)
                    Button("開啟資料夾") { NSWorkspace.shared.open(model.core.folder) }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    if model.settings?.sidebar_collapsed != true { sidebar; Divider() }
                    notes
                }.frame(maxHeight: .infinity)
                Divider()
                composer
            }
            if model.snapshot != nil && (!model.notice.isEmpty || !model.hotkeyAvailable) {
                Text(model.notice.isEmpty ? "⌥⌘N 已被占用；可從選單列叫回便條。" : model.notice)
                    .font(.caption).foregroundStyle(model.failure ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
                    .accessibilityIdentifier("BoardNotice")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $sheet) { item in
            switch item {
            case .edit(let note): EditSheet(model: model, note: note)
            case .original(let note): OriginalSheet(note: note)
            case .tags: TagSheet(model: model)
            case .settings: SettingsSheet(model: model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BoardModel.focusSearch)) { _ in searchFocused = true }
        .onExitCommand { if model.showSearch { model.toggleSearch() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            icon("sidebar.left", "顯示或隱藏標籤側欄") {
                model.perform("preferences", ["sidebar_collapsed": model.settings?.sidebar_collapsed != true])
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("回來").font(.system(size: 16 * model.zoom, weight: .semibold))
                Text("回來先做什麼？").font(.system(size: 10 * model.zoom)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.badge > 0 { Label("\(model.badge)", systemImage: "bell.badge.fill").foregroundStyle(.orange).font(.caption) }
            icon("magnifyingglass", "搜尋便條（⌘F）", action: model.toggleSearch)
            icon("text.line.first.and.arrowtriangle.forward", "依標籤排序") {
                model.perform("sort", ["visible": model.visible.map(\.id)], notice: "已依標籤排序")
            }.disabled(model.visible.count < 2)
            icon(model.settings?.topmost == true ? "pin.fill" : "pin", model.settings?.topmost == true ? "取消置頂" : "視窗置頂") {
                model.perform("preferences", ["topmost": model.settings?.topmost != true])
            }
            Menu {
                Button(model.completed ? "回到未完成" : "已完成的便條") { model.completed.toggle(); model.category = nil }
                Menu("字體與便條大小") {
                    ForEach([70, 85, 100, 115, 125], id: \.self) { size in
                        Button {
                            model.perform("preferences", ["zoom_percent": size])
                        } label: {
                            if size == model.settings?.zoom_percent { Label("\(size)%", systemImage: "checkmark") }
                            else { Text("\(size)%") }
                        }
                    }
                }
                Button("管理標籤") { sheet = .tags }
                Button("設定") { sheet = .settings }
                Divider()
                Button("匯出便條…") { if let w = NSApp.keyWindow { model.exportSheet(w) } }
                Button("開啟資料夾") { NSWorkspace.shared.open(model.core.folder) }
                Divider()
                Button("結束程式") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 20, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多選項").accessibilityLabel("更多選項")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .disabled(model.snapshot == nil)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.completed ? "已完成" : "標籤").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 3)
                tab("全部", key: nil, color: .secondary)
                ForEach(model.tags) { tag in tab(tag.label, key: tag.key, color: color(tag.key)) }
                Divider().padding(.vertical, 4)
                Button { model.completed.toggle(); model.category = nil } label: {
                    Label(model.completed ? "未完成" : "已完成", systemImage: model.completed ? "list.bullet" : "checkmark.circle")
                        .font(.system(size: 11 * model.zoom)).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }.padding(8)
        }.frame(width: 120 * model.zoom).background(Color(nsColor: .underPageBackgroundColor).opacity(0.65))
    }

    private func tab(_ name: String, key: String?, color: Color) -> some View {
        let count = model.notes.filter { ($0.status == .done) == model.completed && (key == nil || $0.category == key) }.count
        return Button { model.category = key } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }.font(.system(size: 11 * model.zoom, weight: model.category == key ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 5).contentShape(Rectangle())
                .background(model.category == key ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(name)
    }

    private var notes: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 7) {
                    if model.visible.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: model.completed ? "checkmark.circle" : "note.text").font(.system(size: 26)).foregroundStyle(.secondary)
                            Text(model.query.isEmpty ? (model.completed ? "還沒有已完成的便條" : "這裡還沒有便條") : "找不到符合的便條")
                                .font(.system(size: 14 * model.zoom, weight: .medium))
                            if !model.completed && model.query.isEmpty {
                                Text("切走前，留一句回來要做的事。")
                                    .font(.system(size: 11 * model.zoom)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).frame(minHeight: max(0, geo.size.height - 22))
                    } else {
                        ForEach(model.visible) { note in
                            row(note).onDrop(of: [Self.dragType], isTargeted: nil) { drop($0, before: note.id) }
                        }
                        Color.clear.frame(height: 14).contentShape(Rectangle())
                            .onDrop(of: [Self.dragType], isTargeted: nil) { drop($0, before: nil) }
                    }
                }.padding(9)
            }
        }
    }

    private func row(_ note: Note) -> some View {
        let tagColor = color(note.category)
        return HStack(alignment: .top, spacing: 7) {
            icon(note.status == .done ? "checkmark.circle.fill" : "circle", note.status == .done ? "恢復待辦" : "完成便條") {
                status(note, note.status == .done ? .inbox : .done)
            }.foregroundStyle(note.status == .done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.system(size: 13 * model.zoom, weight: .semibold))
                    .strikethrough(note.status == .done).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .accessibilityIdentifier("NoteTitle-\(note.id)")
                    .onTapGesture(count: 2) { sheet = .edit(note) }
                if !note.resume.isEmpty { Text("回來：\(note.resume)").lineLimit(3).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack(spacing: 5) {
                    Menu {
                        ForEach(model.tags) { tag in Button(tag.label) { setTag(note, tag.key) } }
                    } label: {
                        Text(model.tagName(note.category)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(tagColor).background(tagColor.opacity(0.12), in: Capsule())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true).help("更改標籤")
                    if note.status != .inbox && note.status != .done { Text(note.status.title).foregroundStyle(.secondary) }
                    if note.reminder_due || note.remind_at != nil {
                        Image(systemName: note.reminder_due ? "bell.badge.fill" : "bell").foregroundStyle(Color.orange)
                            .help(note.reminder_due ? "可以回去看一下了" : "已設定回看提醒")
                    }
                    if note.spent_seconds != nil || note.timer_started != nil { Text(note.elapsed(at: model.clock)).monospacedDigit().foregroundStyle(.secondary) }
                }.lineLimit(1)
            }.font(.system(size: 11 * model.zoom))
            if note.status != .done {
                icon(note.timer_started == nil ? "clock" : "pause.circle.fill", note.timer_started == nil ? "開始計時" : "暫停計時") {
                    model.perform("timer", ["id": note.id]); model.tick()
                }
            }
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.system(size: 10 * model.zoom))
                .frame(width: 17, height: 23).contentShape(Rectangle()).help("拖曳排序")
                .onDrag {
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { done in
                        done(Data(String(note.id).utf8), nil); return nil
                    }
                    return provider
                }
        }.padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.65)))
            .contextMenu {
                Button("編輯便條…") { sheet = .edit(note) }
                Button("看原文") { sheet = .original(note) }
                Menu("狀態") {
                    ForEach(NoteStatus.allCases, id: \.self) { value in Button(value.title) { status(note, value) } }
                }
                Button(note.remind_at == nil && !note.reminder_due ? "10 分鐘後回看" : "清除回看提醒") {
                    model.perform("reminder", ["id": note.id, "enabled": note.remind_at == nil && !note.reminder_due])
                }.disabled(note.status == .done)
                if let settings = model.settings, settings.cloudEnabled && note.status != .done {
                    Button("用 \(settings.provider.title) 重新分類") { model.classify(note.id) }
                }
                Divider()
                Button("上移") { model.nudge(note.id, down: false) }.disabled(model.visible.first?.id == note.id)
                Button("下移") { model.nudge(note.id, down: true) }.disabled(model.visible.last?.id == note.id)
            }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("回來先做什麼…").font(.system(size: 13 * model.zoom)).foregroundStyle(.secondary)
                            .padding(.leading, 7).padding(.top, 6).allowsHitTesting(false)
                    }
                    CaptureEditor(text: $model.draft, fontSize: 13 * model.zoom, submit: model.capture)
                }.frame(height: max(48, 43 * model.zoom)).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
                Button("加入", action: model.capture).buttonStyle(.borderedProminent)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("AddNote")
            }
            Text("Enter 加入  ·  ⇧Enter 換行  ·  ⌥⌘N 叫回便條")
                .font(.system(size: 9 * model.zoom)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func icon(_ system: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).frame(width: 23, height: 23).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
    private func color(_ key: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .brown]
        guard key != "其他", let index = model.tags.firstIndex(where: { $0.key == key }) else { return .secondary }
        return colors[index % colors.count]
    }
    private func status(_ note: Note, _ next: NoteStatus) { model.perform("status", ["id": note.id, "status": next.rawValue]) }
    private func setTag(_ note: Note, _ key: String) {
        model.perform("edit", ["id": note.id, "title": note.title, "resume": note.resume, "category": key])
    }
    private func drop(_ providers: [NSItemProvider], before: UInt64?) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.dragType.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let source = UInt64(text) else { return }
            DispatchQueue.main.async { model.move(source, before: before) }
        }
        return true
    }
}

private enum BoardSheet: Identifiable {
    case edit(Note), original(Note), tags, settings
    var id: String {
        switch self {
        case .edit(let note): return "edit-\(note.id)"
        case .original(let note): return "original-\(note.id)"
        case .tags: return "tags"
        case .settings: return "settings"
        }
    }
}

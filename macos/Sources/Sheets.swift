import SwiftUI

struct EditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BoardModel
    let note: Note
    @ViewState private var title: String
    @ViewState private var resume: String
    @ViewState private var category: String
    @ViewState private var error = ""

    init(model: BoardModel, note: Note) {
        self.model = model; self.note = note
        _title = State(initialValue: note.title)
        _resume = State(initialValue: note.resume)
        _category = State(initialValue: note.category)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("編輯便條").font(.headline)
            TextField("標題", text: $title)
            Text("回來先做什麼").font(.subheadline)
            TextEditor(text: $resume).font(.body).frame(height: 80)
                .accessibilityLabel("回來先做什麼")
                .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3)))
            Picker("標籤", selection: $category) { ForEach(model.tags) { Text($0.label).tag($0.key) } }
            if !error.isEmpty { Text(error).foregroundStyle(Color.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存") {
                    if model.perform("edit", ["id": note.id, "title": title, "resume": resume, "category": category]) != nil { dismiss() }
                    else { error = model.notice }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 360)
    }
}

struct OriginalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("便條原文").font(.headline)
            ScrollView { Text(note.original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 235)
            Button("關閉") { dismiss() }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(18).frame(width: 380)
    }
}

struct TagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BoardModel
    @ViewState private var key: String?
    @ViewState private var name = ""
    @ViewState private var confirm = false
    @ViewState private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("管理標籤").font(.headline)
            Picker("標籤", selection: $key) {
                Text("新增標籤…").tag(nil as String?)
                ForEach(model.tags.filter { $0.key != "其他" }) { Text($0.label).tag(Optional($0.key)) }
            }
            .onChange(of: key) { value in name = value.map(model.tagName) ?? ""; error = "" }
            TextField("標籤名稱", text: $name)
            Text("可設最多 32 個，包含保留的「其他」。").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Color.red) }
            HStack {
                Button("刪除…", role: .destructive) { confirm = true }.disabled(key == nil)
                Spacer()
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(key == nil ? "新增" : "改名") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 340)
        .confirmationDialog("要刪除這個標籤嗎？", isPresented: $confirm, titleVisibility: .visible) {
            Button("刪除標籤", role: .destructive) {
                if let key, model.perform("tag", ["key": key]) != nil { self.key = nil }
                else { error = model.notice }
            }
        } message: { Text("便條不會被刪除，會移到「其他」。") }
    }
    private func save() {
        var fields: [String: Any] = ["label": name]
        if let key { fields["key"] = key }
        if model.perform("tag", fields, notice: "已更新標籤") != nil { error = ""; if key == nil { name = "" } }
        else { error = model.notice }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BoardModel
    @ViewState private var provider: AIProvider
    @ViewState private var enabled: Bool
    @ViewState private var name: String
    @ViewState private var key = ""
    @ViewState private var confirmation = false
    @ViewState private var message = ""
    @ViewState private var localError = false

    init(model: BoardModel) {
        self.model = model
        let provider = model.settings?.provider ?? .gemini
        _provider = State(initialValue: provider)
        _enabled = State(initialValue: model.settings?.cloudEnabled ?? false)
        _name = State(initialValue: model.settings?.modelName(for: provider) ?? provider.defaultModel)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 分類設定").font(.headline)
            Picker("AI 供應商", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }.onChange(of: provider) { selected in
                name = model.settings?.modelName(for: selected) ?? selected.defaultModel
                enabled = model.settings?.provider == selected && model.settings?.cloudEnabled == true
                key = ""; message = ""; model.tell("")
            }
            Toggle("用 AI 整理新便條", isOn: $enabled)
            Text("預設關閉，可離線使用。啟用後，分類時會將便條原文和標籤名稱送給 \(provider.title)。各供應商的金鑰分開存在 macOS 鑰匙圈，不寫入匯出檔。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("模型名稱", text: $name)
            SecureField("API key（留空保留這個供應商的金鑰）", text: $key)
            HStack {
                Link("取得 \(provider.title) API key", destination: provider == .gemini
                     ? URL(string: "https://aistudio.google.com/apikey")!
                     : URL(string: "https://platform.openai.com/api-keys")!)
                Text("不使用訂閱帳號直接登入").foregroundStyle(.secondary)
            }.font(.caption)
            Text("測試連線只送範例，不儲存設定；可能產生 API 費用。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty || !model.notice.isEmpty {
                Text(message.isEmpty ? model.notice : message).font(.caption)
                    .foregroundStyle((message.isEmpty ? model.failure : localError) ? Color.red : Color.secondary)
            }
            HStack {
                Button("移除金鑰…", role: .destructive) { confirmation = true }
                Spacer()
                Button("測試連線") {
                    message = ""; localError = false
                    let input = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.classify(testing: provider, model: name.trimmingCharacters(in: .whitespacesAndNewlines), temporaryKey: input.isEmpty ? nil : input)
                }.disabled(model.aiBusy)
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存") { if save() { message = "已儲存設定" } }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 454)
            .confirmationDialog("移除 \(provider.title) 的 API key？", isPresented: $confirmation, titleVisibility: .visible) {
                Button("移除金鑰", role: .destructive) {
                    do {
                        if model.settings?.provider == provider {
                            guard model.perform("preferences", ["ai_enabled": false]) != nil else { throw NoteError(model.notice) }
                            model.cancelAI()
                        }
                        try AIKey.remove(provider); key = ""; enabled = false
                        message = "已移除金鑰"; localError = false
                    } catch { message = error.localizedDescription; localError = true }
                }
            }
    }
    private func save() -> Bool {
        message = ""; localError = false
        do {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.range(of: #"\A[A-Za-z0-9.-]{1,100}\z"#, options: .regularExpression) != nil else {
                throw NoteError("模型名稱格式不正確。")
            }
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try AIKey.save(key, for: provider); self.key = ""
            } else if enabled, try AIKey.read(provider) == nil {
                throw NoteError("啟用前請輸入 \(provider.title) API key。")
            }
            let changed = provider != model.settings?.provider || name != model.settings?.modelName(for: provider)
            if !enabled || changed || !key.isEmpty { model.cancelAI() }
            guard model.perform("preferences", ["provider": provider.rawValue, "ai_enabled": enabled, "model": name], notice: "已儲存設定") != nil else {
                throw NoteError(model.notice)
            }
            return true
        } catch { message = error.localizedDescription; localError = true; return false }
    }
}

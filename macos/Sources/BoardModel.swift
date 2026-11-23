import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Tag: Decodable, Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

enum NoteStatus: String, Decodable, CaseIterable {
    case inbox = "Inbox", now = "Now", waiting = "Waiting", later = "Later", done = "Done"
    var title: String {
        switch self {
        case .inbox: return "待辦"
        case .now: return "現在做"
        case .waiting: return "等結果"
        case .later: return "稍後"
        case .done: return "完成"
        }
    }
}

struct Note: Decodable, Identifiable {
    let id: UInt64
    let original, title, category, resume: String
    let status: NoteStatus
    let remind_at, timer_started, spent_seconds: UInt64?
    let reminder_due: Bool

    func elapsed(at: UInt64) -> String {
        let running = timer_started.map { at > $0 ? at - $0 : 0 } ?? 0
        let sum = (spent_seconds ?? 0).addingReportingOverflow(running)
        let seconds = sum.overflow ? UInt64.max : sum.partialValue
        if seconds >= 3600 { return String(format: "%llu:%02llu:%02llu", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
}

struct Settings: Decodable {
    let tags: [Tag]
    let zoom_percent: Int
    let topmost, ai_enabled: Bool
    let sidebar_collapsed: Bool?
    let model: String
    let ai_provider: AIProvider?
    let openai_enabled: Bool?
    let openai_model: String?
    var provider: AIProvider { ai_provider ?? .gemini }
    var cloudEnabled: Bool { provider == .gemini ? ai_enabled : openai_enabled == true }
    func modelName(for provider: AIProvider) -> String { provider == .gemini ? model : (openai_model ?? provider.defaultModel) }
}

struct Board: Decodable {
    let notes: [Note]
    let draft: String
    let settings: Settings
}

struct Snapshot: Decodable {
    let board: Board
    let ordered_ids: [UInt64]
    let captured: UInt64?
    let reminded: Bool?
}

struct NoteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Core {
    let folder: URL

    func raw(_ action: String, _ fields: [String: Any] = [:]) throws -> Data {
        var request = fields
        request["action"] = action
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: data, as: UTF8.self)
        let result = folder.path.withCString { path in json.withCString { rn_call(path, $0) } }
        guard let result else { throw NoteError("資料核心沒有回應。") }
        defer { rn_free(result) }
        let bytes = Data(bytes: result, count: strlen(result))
        struct Failure: Decodable { let error: String? }
        if let failure = try? JSONDecoder().decode(Failure.self, from: bytes), let error = failure.error {
            throw NoteError(error)
        }
        return bytes
    }

    func call(_ action: String, _ fields: [String: Any] = [:]) throws -> Snapshot {
        do { return try JSONDecoder().decode(Snapshot.self, from: raw(action, fields)) }
        catch is DecodingError { throw NoteError("無法讀取便條資料，原檔已保留。") }
    }
}

final class BoardModel: ObservableObject {
    static let focusCapture = Notification.Name("ReturnNote.FocusCapture")
    static let focusSearch = Notification.Name("ReturnNote.FocusSearch")
    @Published var snapshot: Snapshot?
    @Published var draft = "" { didSet { if !syncingDraft && draft != oldValue { debounceDraft() } } }
    @Published var category: String?
    @Published var completed = false
    @Published var query = ""
    @Published var showSearch = false
    @Published var notice = ""
    @Published var failure = false
    @Published var hotkeyAvailable = true
    @Published var clock = timestamp()
    @Published var aiBusy = false
    let core: Core
    let ai = AIClient()
    private var draftSave: DispatchWorkItem?
    private var syncingDraft = false
    private var retryReminderAt: UInt64 = 0
    private var activeAI: [(UUID, URLSessionDataTask)] = []

    init(core: Core) { self.core = core; reload() }
    static func timestamp() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970)) }
    var settings: Settings? { snapshot?.board.settings }
    var tags: [Tag] { settings?.tags ?? [] }
    var notes: [Note] { snapshot?.board.notes ?? [] }
    var zoom: CGFloat { CGFloat(min(125, max(70, settings?.zoom_percent ?? 100))) / 100 }
    var badge: Int { notes.filter(\.reminder_due).count }
    var visible: [Note] {
        let lookup = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.ordered_ids ?? []).compactMap { lookup[$0] }.filter { note in
            (note.status == .done) == completed && (category == nil || note.category == category)
            && (term.isEmpty || [note.title, note.resume, note.original, tagName(note.category)].contains { $0.localizedCaseInsensitiveContains(term) })
        }
    }

    func tagName(_ key: String) -> String { tags.first { $0.key == key }?.label ?? key }
    func tell(_ text: String, failure: Bool = false) { notice = text; self.failure = failure }
    func show(_ error: Error) { tell(error.localizedDescription, failure: true) }

    func reload() {
        do {
            let result = try core.call("load")
            syncingDraft = true
            draft = result.board.draft
            syncingDraft = false
            snapshot = result
            tell("")
        } catch { show(error) }
    }

    @discardableResult func perform(_ action: String, _ fields: [String: Any] = [:], notice: String? = nil) -> Snapshot? {
        guard snapshot != nil else { return nil }
        do {
            let result = try core.call(action, fields)
            snapshot = result
            if let category, !result.board.settings.tags.contains(where: { $0.key == category }) { self.category = nil }
            if let notice { tell(notice) }
            else if failure && action != "tick" { tell("") }
            return result
        } catch { show(error); return nil }
    }

    private func debounceDraft() {
        draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flushDraft() }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: work)
    }

    @discardableResult func flushDraft() -> Bool {
        draftSave?.cancel()
        draftSave = nil
        guard let snapshot, snapshot.board.draft != draft else { return true }
        return perform("draft", ["text": draft]) != nil
    }

    func capture() {
        guard let id = perform("capture", ["text": draft], notice: "已加到便條")?.captured else { return }
        draftSave?.cancel()
        draftSave = nil
        syncingDraft = true
        draft = ""
        syncingDraft = false
        category = nil
        completed = false
        query = ""
        if settings?.cloudEnabled == true { classify(id) }
    }

    func tick(at: UInt64 = timestamp(), notify: Bool = true) {
        if (notes.contains(where: { $0.timer_started != nil }) || notes.contains(where: { $0.remind_at != nil })) && clock != at { clock = at }
        if at >= retryReminderAt && notes.contains(where: { ($0.remind_at ?? UInt64.max) <= at && $0.status == .waiting }) {
            if perform("tick", ["at": at])?.reminded == true {
                tell("有一件等結果的工作，可以回去看一下了。")
                if notify && !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            } else { retryReminderAt = at + 10 }
        }
    }

    func toggleSearch() {
        showSearch.toggle()
        if showSearch { focusSearch() } else { query = ""; focusCapture() }
    }
    func focusSearch() {
        showSearch = true
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.focusSearch, object: nil) }
    }
    func focusCapture() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.focusCapture, object: nil) }
    }

    func move(_ id: UInt64, before: UInt64?) {
        var next = [String: Any]()
        if let before { next["before"] = before }
        next["id"] = id
        next["visible"] = visible.map(\.id)
        perform("move", next)
    }
    func nudge(_ id: UInt64, down: Bool) {
        let list = visible.map(\.id)
        guard let i = list.firstIndex(of: id) else { return }
        if down && i + 1 < list.count { move(id, before: i + 2 < list.count ? list[i + 2] : nil) }
        if !down && i > 0 { move(id, before: list[i - 1]) }
    }

    func exportSheet(_ window: NSWindow) {
        guard flushDraft(), snapshot != nil else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.nameFieldStringValue = "return-note-backup-\(Self.timestamp()).json"
        save.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = save.url else { return }
            guard self.flushDraft() else { return }
            guard url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                != self.core.folder.standardizedFileURL.resolvingSymlinksInPath() else {
                self.tell("請匯出到便條資料夾以外的位置。", failure: true); return
            }
            do {
                var object = try JSONSerialization.jsonObject(with: self.core.raw("load")) as? [String: Any]
                guard let board = object?.removeValue(forKey: "board") else { throw NoteError("沒有可匯出的便條。") }
                let output = try JSONSerialization.data(withJSONObject: board, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                try output.write(to: url, options: .atomic)
                self.tell("已匯出便條備份")
            } catch { self.show(error) }
        }
    }

    func classify(_ id: UInt64? = nil, testing provider: AIProvider? = nil, model: String? = nil, temporaryKey: String? = nil) {
        let token = UUID()
        do {
            var fields: [String: Any] = [:]
            if let id { fields["id"] = id }
            if let provider { fields["provider"] = provider.rawValue }
            if let model { fields["model"] = model }
            let job = try JSONDecoder().decode(AIJobEnvelope.self, from: core.raw("ai_job", fields)).job
            guard let key = try temporaryKey ?? AIKey.read(job.provider) else { throw NoteError("請在設定輸入 \(job.provider.title) API key。") }
            let task = try ai.send(job: job, key: key) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.activeAI.contains(where: { $0.0 == token }) else { return }
                    self.activeAI.removeAll { $0.0 == token }
                    self.aiBusy = !self.activeAI.isEmpty
                    do {
                        let (http, response) = try result.get()
                        if !(200..<300).contains(http) { _ = try self.core.raw("ai_error", ["provider": job.provider.rawValue, "status": http, "response": response]); return }
                        if let id {
                            try self.applyClassification(id, job: job, response: response)
                        } else {
                            _ = try self.core.raw("ai_check", ["provider": job.provider.rawValue, "tags": job.tags, "response": response])
                            self.tell("\(job.provider.title) 連線成功")
                        }
                    } catch { self.show(error) }
                }
            }
            activeAI.append((token, task))
            aiBusy = true
            tell(id == nil ? "正在測試 \(job.provider.title)…" : "便條已儲存，正在分類…")
        } catch { show(error) }
    }

    private func applyClassification(_ id: UInt64, job: AIJob, response: Any) throws {
        let data = try core.raw("ai_result", ["id": id, "revision": job.revision, "provider": job.provider.rawValue, "model": job.model, "tags": job.tags, "response": response])
        snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        struct Applied: Decodable { let applied: Bool }
        let applied = try JSONDecoder().decode(Applied.self, from: data).applied
        tell(applied ? "已用 \(job.provider.title) 分類" : "便條或設定已變更，保留本機內容。")
    }

    func cancelAI() {
        for (_, task) in activeAI { task.cancel() }
        activeAI.removeAll()
        aiBusy = false
    }
}

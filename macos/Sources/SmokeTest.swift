import AppKit

/// Integration test for the packaged Swift → C → Rust → JSON stack; no production notes or keychain access.
@MainActor
func runSmokeTest() -> Int32 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReturnNoteSmoke-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NoteError("smoke: \(message)") }
    }
    do {
        _ = NSApplication.shared
        let model = BoardModel(core: Core(folder: dir))
        try check(model.snapshot != nil && model.notes.isEmpty && model.settings?.ai_enabled == false, "blank board")
        model.draft = "測試巨集\n保留原文"
        try check(model.flushDraft(), "save draft")
        try check(BoardModel(core: model.core).draft == model.draft, "reload draft")
        model.capture()
        try check(model.notes.count == 1 && model.draft.isEmpty, "capture")
        try check(model.notes.first?.original == "測試巨集\n保留原文", "preserve Chinese and newline")
        try check(model.notes.first?.category == "產品／開發", "reuse Rust taxonomy")
        model.perform("edit", ["id": 1, "title": "測試登入", "resume": "先看錯誤訊息", "category": "產品／開發"])
        model.perform("timer", ["id": 1])
        try check(model.notes.first?.timer_started != nil, "timer started")
        model.perform("reminder", ["id": 1, "enabled": true])
        guard let due = model.notes.first?.remind_at else { throw NoteError("smoke: missing remind time") }
        model.tick(at: due, notify: false)
        try check(model.badge == 1, "reminder fires")
        model.query = "錯誤訊息"
        try check(model.visible.map(\.id) == [1], "search return step")
        model.query = "不匹配"
        try check(model.visible.isEmpty, "search excludes unrelated")
        model.query = ""
        model.perform("status", ["id": 1, "status": "Done"])
        try check(model.visible.isEmpty && model.badge == 0, "complete item, clear reminder")
        model.completed = true
        try check(model.visible.first?.timer_started == nil && model.visible.first?.status == .done, "completed item stops timer")
        model.perform("tag", ["label": "課業"])
        model.draft = "讀課業章節"
        model.capture()
        let fresh = BoardModel(core: model.core)
        try check(fresh.notes.last?.category == fresh.tags.first(where: { $0.label == "課業" })?.key, "custom tag persists")
        try check(fresh.notes.first?.resume == "先看錯誤訊息", "return step persists")
        let before = fresh.visible.map(\.id)
        fresh.draft = "營運報價"
        fresh.capture()
        fresh.move(2, before: 3)
        try check(before == [2] && fresh.visible.map(\.id) == [2, 3], "reorder within current view")
        try check(BoardModel(core: fresh.core).visible.map(\.id) == [2, 3], "reorder persists")
        let content = try Data(contentsOf: dir.appendingPathComponent("notes.json"))
        try check((try? JSONDecoder().decode(Board.self, from: content)) != nil, "Windows-compatible board file")
        try check(model.settings?.cloudEnabled == false, "cloud AI defaults to off")
        let gemini = try JSONDecoder().decode(AIJobEnvelope.self, from: fresh.core.raw("ai_job", ["provider": "gemini"])).job
        let openai = try JSONDecoder().decode(AIJobEnvelope.self, from: fresh.core.raw("ai_job", ["provider": "openai", "model": "gpt-test"])).job
        let dummy = "smoke-test-only"
        let googleRequest = try AIClient.request(job: gemini, key: dummy)
        let openaiRequest = try AIClient.request(job: openai, key: dummy)
        try check(googleRequest.url?.host == "generativelanguage.googleapis.com" && googleRequest.value(forHTTPHeaderField: "x-goog-api-key") == dummy && googleRequest.value(forHTTPHeaderField: "Authorization") == nil, "Gemini endpoint and auth")
        try check(openaiRequest.url?.absoluteString == "https://api.openai.com/v1/responses" && openaiRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(dummy)" && openaiRequest.value(forHTTPHeaderField: "x-goog-api-key") == nil, "OpenAI endpoint and auth")
        try check((try? AIClient.request(job: openai, key: "bad\nkey")) == nil, "reject malformed unsaved key before creating a request")
        try check(BoardModel(core: fresh.core).settings?.provider == .gemini, "testing a provider does not select it")
        fresh.perform("preferences", ["provider": "openai", "model": "gpt-test", "ai_enabled": true])
        let updated = BoardModel(core: fresh.core).settings
        try check(updated?.provider == .openai && updated?.cloudEnabled == true && updated?.modelName(for: .openai) == "gpt-test" && updated?.ai_enabled == false, "reopen OpenAI preferences independently of Gemini")
        print("macOS smoke test passed: capture, draft, taxonomy, edit, search, timer, reminder, completion, reorder, persistence, AI settings and request routing (offline)")
        return 0
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        return 1
    }
}

#![cfg(target_os = "macos")]

use return_note::macos_bridge::{rn_call, rn_free};
use serde_json::{Value, json};
use std::ffi::{CStr, CString};

struct Fixture(tempfile_like::Directory);
impl Fixture {
    fn new() -> Self {
        Self(tempfile_like::Directory::new())
    }
    fn call(&self, request: Value) -> Value {
        let folder = CString::new(self.0.0.to_str().unwrap()).unwrap();
        let input = CString::new(request.to_string()).unwrap();
        unsafe {
            let output = rn_call(folder.as_ptr(), input.as_ptr());
            assert!(!output.is_null());
            let response = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
            rn_free(output);
            response
        }
    }
}

#[test]
fn native_bridge_reopens_windows_compatible_data_after_capture() {
    let app = Fixture::new();
    let result = app.call(json!({"action":"capture","text":"測試登入\n保留原文"}));
    assert_eq!(result["captured"], 1);
    assert_eq!(result["board"]["notes"][0]["category"], "產品／開發");
    let board = return_note::storage::Storage::new(&app.0.0)
        .unwrap()
        .load()
        .unwrap();
    assert_eq!(board.notes[0].original, "測試登入\n保留原文");
    assert_eq!(app.call(json!({"action":"load"}))["board"]["version"], 2);
}

#[test]
fn invalid_capture_preserves_saved_draft() {
    let app = Fixture::new();
    app.call(json!({"action":"draft","text":"待續"}));
    assert!(app.call(json!({"action":"capture","text":" "}))["error"].is_string());
    assert_eq!(app.call(json!({"action":"load"}))["board"]["draft"], "待續");
}

#[test]
fn reminder_and_timer_flows_use_persistent_board() {
    let app = Fixture::new();
    app.call(json!({"action":"capture","text":"等報價"}));
    app.call(json!({"action":"timer","id":1}));
    let waiting = app.call(json!({"action":"reminder","id":1,"enabled":true}));
    let now = waiting["board"]["notes"][0]["remind_at"].as_u64().unwrap();
    assert_eq!(waiting["board"]["notes"][0]["status"], "Waiting");
    assert_eq!(
        app.call(json!({"action":"tick","at":now}))["board"]["notes"][0]["reminder_due"],
        true
    );
    let done = app.call(json!({"action":"status","id":1,"status":"Done"}));
    assert_eq!(done["board"]["notes"][0]["status"], "Done");
    assert!(done["board"]["notes"][0]["timer_started"].is_null());
    assert_eq!(done["board"]["notes"][0]["reminder_due"], false);
}

#[test]
fn stale_ai_response_cannot_overwrite_a_human_edit() {
    let app = Fixture::new();
    app.call(json!({"action":"preferences","ai_enabled":true}));
    app.call(json!({"action":"capture","text":"測試登入"}));
    let job = app.call(json!({"action":"ai_job","id":1}))["job"].clone();
    assert_eq!(job["revision"], 0);
    app.call(json!({"action":"edit","id":1,"title":"用我的標題","resume":"先看失敗測試","category":"產品／開發"}));
    let response = json!({"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"{\"title\":\"AI 標題\",\"category\":\"其他\"}"}]}}]});
    let result = app.call(json!({"action":"ai_result","id":1,"revision":0,"model":job["model"],"tags":job["tags"],"response":response}));
    assert_eq!(result["applied"], false);
    assert_eq!(result["board"]["notes"][0]["title"], "用我的標題");
}

fn openai_response(text: &str) -> Value {
    json!({"status":"completed","output":[{"type":"reasoning"},{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text}]}]})
}

#[test]
fn openai_provider_round_trip_uses_structured_output_and_keeps_gemini_settings() {
    let app = Fixture::new();
    app.call(json!({"action":"preferences","model":"gemini-test","ai_enabled":true}));
    app.call(
        json!({"action":"preferences","provider":"openai","model":"gpt-test","ai_enabled":true}),
    );
    app.call(json!({"action":"capture","text":"測試登入"}));
    let job = app.call(json!({"action":"ai_job","id":1}))["job"].clone();
    assert_eq!(job["provider"], "openai");
    assert_eq!(job["body"]["model"], "gpt-test");
    assert_eq!(job["body"]["store"], false);
    assert_eq!(job["body"]["input"], "測試登入");
    assert_eq!(job["body"]["text"]["format"]["strict"], true);
    let settings = app.call(json!({"action":"load"}))["board"]["settings"].clone();
    assert_eq!(settings["model"], "gemini-test");
    assert_eq!(
        settings["ai_enabled"], false,
        "Windows must not opt in to Gemini just because macOS enabled OpenAI"
    );
    let result = app.call(json!({"action":"ai_result","id":1,"revision":job["revision"],"provider":job["provider"],"model":job["model"],"tags":job["tags"],"response":openai_response(r#"{"title":"登入測試","category":"其他"}"#)}));
    assert_eq!(result["applied"], true);
    assert_eq!(result["board"]["notes"][0]["title"], "登入測試");
    assert_eq!(result["board"]["notes"][0]["original"], "測試登入");
}

#[test]
fn switched_provider_rejects_old_result_even_if_the_model_name_matches() {
    let app = Fixture::new();
    app.call(
        json!({"action":"preferences","provider":"openai","ai_enabled":true,"model":"same-model"}),
    );
    app.call(json!({"action":"capture","text":"測試登入"}));
    let job = app.call(json!({"action":"ai_job","id":1}))["job"].clone();
    app.call(
        json!({"action":"preferences","provider":"gemini","ai_enabled":true,"model":"same-model"}),
    );
    let result = app.call(json!({"action":"ai_result","id":1,"revision":job["revision"],"provider":job["provider"],"model":"same-model","tags":job["tags"],"response":openai_response(r#"{"title":"不應採用","category":"其他"}"#)}));
    assert_eq!(result["applied"], false);
    assert_eq!(result["board"]["notes"][0]["title"], "測試登入");
}

#[test]
fn cloud_connection_check_sends_sample_and_only_generic_labels() {
    let app = Fixture::new();
    app.call(json!({"action":"tag","label":"私人專案"}));
    app.call(json!({"action":"capture","text":"不出現在測試的文字"}));
    let job =
        app.call(json!({"action":"ai_job","provider":"openai","model":"gpt-test"}))["job"].clone();
    assert_eq!(job["model"], "gpt-test");
    assert_eq!(job["tags"], json!([["其他", "其他"]]));
    assert!(!job.to_string().contains("私人專案"));
    assert!(!job.to_string().contains("不出現在測試的文字"));
    assert_eq!(app.call(json!({"action":"ai_check","provider":"openai","tags":job["tags"],"response":openai_response(r#"{"title":"測試","category":"其他"}"#)}))["ok"], true);
    assert_eq!(
        app.call(json!({"action":"load"}))["board"]["settings"]["ai_enabled"],
        false
    );
}

mod tempfile_like {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    pub struct Directory(pub PathBuf);
    impl Directory {
        pub fn new() -> Self {
            static ID: AtomicUsize = AtomicUsize::new(0);
            let p = std::env::temp_dir().join(format!(
                "return-note-mac-test-{}-{}",
                std::process::id(),
                ID.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

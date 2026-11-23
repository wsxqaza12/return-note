//! JSON command boundary for the native macOS frontend. The caller serializes writes.
use crate::{
    ai,
    model::{AiProvider, Board, MAX_TEXT, Settings, Status, now},
    storage::Storage,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::Path,
};

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum Command {
    Load,
    Capture {
        text: String,
    },
    Draft {
        text: String,
    },
    Edit {
        id: u64,
        title: String,
        resume: String,
        category: String,
    },
    Status {
        id: u64,
        status: Status,
    },
    Timer {
        id: u64,
    },
    Reminder {
        id: u64,
        enabled: bool,
    },
    Tick {
        at: u64,
    },
    Tag {
        key: Option<String>,
        label: Option<String>,
    },
    Sort {
        visible: Vec<u64>,
    },
    Move {
        visible: Vec<u64>,
        id: u64,
        before: Option<u64>,
    },
    Preferences {
        topmost: Option<bool>,
        sidebar_collapsed: Option<bool>,
        zoom_percent: Option<u16>,
        ai_enabled: Option<bool>,
        model: Option<String>,
        provider: Option<AiProvider>,
    },
    AiJob {
        id: Option<u64>,
        provider: Option<AiProvider>,
        model: Option<String>,
    },
    AiResult {
        id: u64,
        revision: u64,
        #[serde(default)]
        provider: AiProvider,
        model: String,
        tags: Vec<(String, String)>,
        response: Value,
    },
    AiError {
        #[serde(default)]
        provider: AiProvider,
        status: u32,
        response: Value,
    },
    AiCheck {
        #[serde(default)]
        provider: AiProvider,
        response: Value,
        tags: Vec<(String, String)>,
    },
}

fn tags(board: &Board) -> Vec<(String, String)> {
    board
        .settings
        .tags
        .iter()
        .map(|t| (t.key.clone(), t.label.clone()))
        .collect()
}

fn ai_model(s: &Settings, provider: AiProvider) -> &str {
    match provider {
        AiProvider::Gemini => &s.model,
        AiProvider::OpenAi => &s.openai_model,
    }
}

fn ai_enabled(s: &Settings) -> bool {
    match s.ai_provider {
        AiProvider::Gemini => s.ai_enabled,
        AiProvider::OpenAi => s.openai_enabled,
    }
}

fn parse_ai(
    provider: AiProvider,
    response: &Value,
    labels: &[String],
) -> Result<ai::Classification, String> {
    match provider {
        AiProvider::Gemini => ai::parse_with_labels(response, labels),
        AiProvider::OpenAi => ai::openai::parse(response, labels),
    }
}

fn execute(folder: &str, command: Command) -> Result<Value, String> {
    if let Command::AiError {
        provider,
        status,
        response,
    } = command
    {
        return Err(match provider {
            AiProvider::Gemini => ai::service_error(status, &response),
            AiProvider::OpenAi => ai::openai::error(status, &response),
        });
    }
    if let Command::AiCheck {
        provider,
        response,
        tags,
    } = command
    {
        parse_ai(
            provider,
            &response,
            &tags.into_iter().map(|(_, label)| label).collect::<Vec<_>>(),
        )?;
        return Ok(json!({"ok":true}));
    }
    let storage = Storage::new(Path::new(folder))?;
    let mut board = storage.load()?;
    let mut response = json!({});
    let mut save = true;
    match command {
        Command::Load => save = false,
        Command::Capture { text } => response["captured"] = json!(board.capture(&text)?),
        Command::Draft { text } => {
            // Keep drafts even if they exceed the capture limit; never silently truncate them.
            save = board.draft != text;
            board.draft = text;
        }
        Command::Edit {
            id,
            title,
            resume,
            category,
        } => board.edit(id, title, resume, category)?,
        Command::Status { id, status } => board.set_status(id, status)?,
        Command::Timer { id } => board
            .notes
            .iter_mut()
            .find(|n| n.id == id)
            .ok_or("找不到這張便條。")?
            .toggle_timer(now()),
        Command::Reminder { id, enabled } => {
            board.set_status(id, Status::Waiting)?;
            let n = board.notes.iter_mut().find(|n| n.id == id).unwrap();
            n.remind_at = enabled.then(|| now().saturating_add(600));
            n.reminder_due = false;
        }
        Command::Tick { at } => {
            save = board.due_reminders(at);
            response["reminded"] = json!(save);
        }
        Command::Tag { key, label } => {
            let index = key
                .map(|k| {
                    board
                        .settings
                        .tags
                        .iter()
                        .position(|t| t.key == k)
                        .ok_or("找不到這個標籤。")
                })
                .transpose()?;
            board.change_tag(index, label.as_deref())?;
        }
        Command::Sort { visible } => save = board.sort_by_tag(&visible)?,
        Command::Move {
            visible,
            id,
            before,
        } => save = board.reorder_visible(&visible, id, before)?,
        Command::Preferences {
            topmost,
            sidebar_collapsed,
            zoom_percent,
            ai_enabled,
            model,
            provider,
        } => {
            let s = &mut board.settings;
            if let Some(v) = topmost {
                s.topmost = v;
            }
            if let Some(v) = sidebar_collapsed {
                s.sidebar_collapsed = v;
            }
            if let Some(v) = zoom_percent {
                if !(70..=125).contains(&v) {
                    return Err("請選擇 70% 到 125%。".into());
                }
                s.zoom_percent = v;
            }
            let selected = provider.unwrap_or(s.ai_provider);
            if let Some(v) = model {
                if !ai::valid_model(&v) {
                    return Err("模型名稱格式不正確。".into());
                }
                match selected {
                    AiProvider::Gemini => s.model = v,
                    AiProvider::OpenAi => s.openai_model = v,
                }
            }
            // Older Windows builds only read `ai_enabled`, which always refers to Gemini.
            let enable =
                ai_enabled.unwrap_or_else(|| selected == s.ai_provider && self::ai_enabled(s));
            s.ai_provider = selected;
            s.ai_enabled = selected == AiProvider::Gemini && enable;
            s.openai_enabled = selected == AiProvider::OpenAi && enable;
        }
        Command::AiJob {
            id,
            provider,
            model,
        } => {
            let s = &board.settings;
            let provider = if id.is_some() {
                s.ai_provider
            } else {
                provider.unwrap_or(s.ai_provider)
            };
            let model = if id.is_some() {
                ai_model(s, provider)
            } else {
                model.as_deref().unwrap_or_else(|| ai_model(s, provider))
            };
            if !ai::valid_model(model) {
                return Err("模型名稱格式不正確。".into());
            }
            let tagged = if id.is_some() {
                tags(&board)
            } else {
                vec![("其他".into(), "其他".into())]
            };
            let labels = tagged
                .iter()
                .map(|(_, label)| label.clone())
                .collect::<Vec<_>>();
            let (text, revision) = match id {
                Some(id) => {
                    if !ai_enabled(s) {
                        return Err("AI 分類未開啟。".into());
                    }
                    let note = board
                        .notes
                        .iter()
                        .find(|n| n.id == id && n.status != Status::Done)
                        .ok_or("找不到可分類的便條。")?;
                    if note.original.chars().count() > MAX_TEXT {
                        return Err("原文太長，未送出。".into());
                    }
                    (note.original.as_str(), note.revision)
                }
                None => ("測試連線：整理今天的工作", 0),
            };
            let body = match provider {
                AiProvider::Gemini => ai::request_body(text, &labels),
                AiProvider::OpenAi => ai::openai::request(model, text, &labels),
            };
            return Ok(
                json!({"job": {"provider":provider,"model":model,"tags":tagged,"revision":revision,"body":body}}),
            );
        }
        Command::AiResult {
            id,
            revision,
            provider,
            model,
            tags: sent,
            response: data,
        } => {
            save = false;
            let s = &board.settings;
            if ai_enabled(s)
                && provider == s.ai_provider
                && model == ai_model(s, provider)
                && sent == tags(&board)
            {
                let labels = sent
                    .iter()
                    .map(|(_, label)| label.clone())
                    .collect::<Vec<_>>();
                let result = parse_ai(provider, &data, &labels)?;
                let (key, _) = sent
                    .iter()
                    .find(|(_, label)| label == &result.category)
                    .ok_or("標籤已變更，原文已保留。")?;
                save = board.apply_ai(id, revision, result.title, key.clone());
            }
            response["applied"] = json!(save);
        }
        Command::AiError { .. } | Command::AiCheck { .. } => unreachable!(),
    }
    if save {
        storage.save(&board)?;
    }
    response["ordered_ids"] = json!(board.ordered_ids());
    response["board"] = json!(board);
    Ok(response)
}

/// # Safety
/// Both pointers must be valid UTF-8, NUL-terminated strings for the duration of the call.
/// The returned pointer is owned by Rust and must be released using `rn_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rn_call(folder: *const c_char, input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value, String> {
        if folder.is_null() || input.is_null() {
            return Err("無法讀取便條指令。".into());
        }
        let folder = unsafe { CStr::from_ptr(folder) }
            .to_str()
            .map_err(|_| "資料夾路徑格式不正確。")?;
        let command = serde_json::from_slice(unsafe { CStr::from_ptr(input) }.to_bytes())
            .map_err(|_| "無法讀取便條指令。")?;
        execute(folder, command)
    });
    let response = match result {
        Ok(Ok(response)) => response,
        Ok(Err(error)) => json!({"error":error}),
        Err(_) => json!({"error":"便條處理失敗。"}),
    };
    CString::new(response.to_string()).unwrap().into_raw()
}

/// # Safety
/// Pass a pointer returned by `rn_call` exactly once, or a null pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rn_free(response: *mut c_char) {
    if !response.is_null() {
        drop(unsafe { CString::from_raw(response) });
    }
}

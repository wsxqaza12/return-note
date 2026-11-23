use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub const CATEGORIES: [&str; 5] = ["產品／開發", "行銷／GTM", "營運", "外部案子", "其他"];
pub const CATEGORY_LABELS: [&str; 5] = ["產品開發", "行銷 GTM", "營運", "外部案子", "其他"];
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Tag {
    pub key: String,
    pub label: String,
}
fn default_tags() -> Vec<Tag> {
    CATEGORIES
        .iter()
        .zip(CATEGORY_LABELS)
        .map(|(key, label)| Tag {
            key: key.to_string(),
            label: label.into(),
        })
        .collect()
}
pub const MAX_TEXT: usize = 8000;
pub const MAX_TAGS: usize = 32;
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    #[default]
    Inbox,
    Now,
    Waiting,
    Later,
    Done,
}
impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Self::Inbox => "待辦",
            Self::Now => "現在做",
            Self::Waiting => "等結果",
            Self::Later => "稍後",
            Self::Done => "完成",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Note {
    pub id: u64,
    pub original: String,
    pub title: String,
    pub category: String,
    pub status: Status,
    pub resume: String,
    pub created: u64,
    pub revision: u64,
    pub ai: String,
    pub remind_at: Option<u64>,
    pub reminder_due: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timer_started: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spent_seconds: Option<u64>,
}

impl Note {
    pub fn elapsed(&self, at: u64) -> u64 {
        self.spent_seconds.unwrap_or(0).saturating_add(
            self.timer_started
                .map_or(0, |start| at.saturating_sub(start)),
        )
    }
    fn pause_timer(&mut self, at: u64) {
        if self.timer_started.is_some() {
            self.spent_seconds = Some(self.elapsed(at));
            self.timer_started = None;
        }
    }
    pub fn toggle_timer(&mut self, at: u64) {
        if self.status == Status::Done {
            return;
        }
        if self.timer_started.is_some() {
            self.pause_timer(at);
        } else {
            self.timer_started = Some(at);
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub tags: Vec<Tag>,
    pub next_tag: u64,
    pub zoom_percent: u16,
    pub topmost: bool,
    pub compact: bool,
    pub ai_enabled: bool,
    pub model: String,
    #[serde(skip_serializing_if = "AiProvider::is_gemini")]
    pub ai_provider: AiProvider,
    #[serde(skip_serializing_if = "is_false")]
    pub openai_enabled: bool,
    pub openai_model: String,
    #[serde(skip_serializing_if = "is_false")]
    pub sidebar_collapsed: bool,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AiProvider {
    #[default]
    Gemini,
    OpenAi,
}
impl AiProvider {
    fn is_gemini(&self) -> bool {
        *self == Self::Gemini
    }
}
fn is_false(value: &bool) -> bool {
    !value
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            tags: default_tags(),
            next_tag: 1,
            zoom_percent: 100,
            topmost: true,
            compact: true,
            ai_enabled: false,
            model: "gemini-3.1-flash-lite".into(),
            ai_provider: AiProvider::Gemini,
            openai_enabled: false,
            openai_model: "gpt-5-mini".into(),
            sidebar_collapsed: false,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Board {
    pub version: u32,
    pub next_id: u64,
    pub notes: Vec<Note>,
    pub draft: String,
    pub settings: Settings,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub order: Vec<u64>,
}
impl Default for Board {
    fn default() -> Self {
        Self {
            version: 2,
            next_id: 1,
            notes: vec![],
            draft: String::new(),
            settings: Settings::default(),
            order: Vec::new(),
        }
    }
}

impl Board {
    pub fn index(&self, key: &str) -> usize {
        self.settings
            .tags
            .iter()
            .position(|t| t.key == key)
            .unwrap_or(self.settings.tags.len().saturating_sub(1))
    }
    fn has_tag(&self, key: &str) -> bool {
        self.settings.tags.iter().any(|t| t.key == key)
    }
    pub fn change_tag(&mut self, index: Option<usize>, name: Option<&str>) -> Result<(), String> {
        let tags = &mut self.settings.tags;
        if let Some(i) = index
            && (i >= tags.len() || tags[i].key == "其他")
        {
            return Err("「其他」保留給未分類的便條。".into());
        }
        if let Some(raw) = name {
            let name = raw.trim();
            if name.is_empty() || name.chars().count() > 24 || name.chars().any(char::is_control) {
                return Err("標籤名稱請填 1 到 24 字。".into());
            }
            if name == "全部"
                || tags
                    .iter()
                    .enumerate()
                    .any(|(i, t)| Some(i) != index && t.label.to_lowercase() == name.to_lowercase())
            {
                return Err("這個標籤名稱已經使用。".into());
            }
            if let Some(i) = index {
                tags[i].label = name.into()
            } else {
                if tags.len() >= MAX_TAGS {
                    return Err("最多可設 32 個標籤。".into());
                }
                let key = format!("tag-{}", self.settings.next_tag);
                self.settings.next_tag = self
                    .settings
                    .next_tag
                    .checked_add(1)
                    .ok_or("標籤編號已達上限。")?;
                tags.insert(
                    tags.len() - 1,
                    Tag {
                        key,
                        label: name.into(),
                    },
                );
            }
        } else if let Some(i) = index {
            let key = tags.remove(i).key;
            for n in &mut self.notes {
                if n.category == key {
                    n.category = "其他".into();
                    n.revision += 1;
                }
            }
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version != 2 {
            return Err("這份資料來自較新的版本，請先更新程式。".into());
        }
        let tags = &self.settings.tags;
        if tags.is_empty()
            || tags.len() > MAX_TAGS
            || tags.last().is_none_or(|t| t.key != "其他")
            || tags.iter().any(|t| t.label.trim().is_empty())
            || tags
                .iter()
                .map(|t| &t.key)
                .collect::<std::collections::HashSet<_>>()
                .len()
                != tags.len()
        {
            return Err("標籤資料格式不完整。".into());
        }
        let mut ids = std::collections::HashSet::new();
        if self.notes.iter().any(|n| {
            n.id >= self.next_id
                || !ids.insert(n.id)
                || n.title.trim().is_empty()
                || !self.has_tag(&n.category)
        }) || self
            .notes
            .iter()
            .filter(|n| n.status == Status::Now)
            .count()
            > 1
        {
            return Err("便條資料格式不完整，原檔已保留。".into());
        }
        if !self.order.is_empty() {
            let ordered: std::collections::HashSet<_> = self.order.iter().copied().collect();
            if ordered != ids || ordered.len() != self.order.len() {
                return Err("便條排序資料不完整，原檔已保留。".into());
            }
        }
        Ok(())
    }
    /// Visible order is independent of note storage and AI revisions.
    pub fn ordered_ids(&self) -> Vec<u64> {
        if !self.order.is_empty() {
            return self.order.clone();
        }
        let mut notes: Vec<_> = self.notes.iter().rev().collect();
        notes.sort_by_key(|note| note.status != Status::Now);
        notes.into_iter().map(|note| note.id).collect()
    }
    pub fn sort_by_tag(&mut self, visible: &[u64]) -> Result<bool, String> {
        let categories: std::collections::HashMap<_, _> = self
            .notes
            .iter()
            .map(|note| (note.id, self.index(&note.category)))
            .collect();
        let mut sorted = visible.to_vec();
        if sorted.iter().any(|id| !categories.contains_key(id)) {
            return Err("清單已更新，請再整理一次。".into());
        }
        sorted.sort_by_key(|id| categories[id]);
        if sorted == visible {
            return Ok(false);
        }
        let slots: std::collections::HashMap<_, _> = visible.iter().copied().zip(sorted).collect();
        self.order = self
            .ordered_ids()
            .into_iter()
            .map(|id| slots.get(&id).copied().unwrap_or(id))
            .collect();
        self.validate()?;
        Ok(true)
    }
    /// Reorder only the visible slots. Hidden categories and completed items stay put.
    pub fn reorder_visible(
        &mut self,
        visible: &[u64],
        source: u64,
        before: Option<u64>,
    ) -> Result<bool, String> {
        self.validate()?;
        let visible_set: std::collections::HashSet<_> = visible.iter().copied().collect();
        let order = self.ordered_ids();
        if visible_set.len() != visible.len()
            || !visible_set.contains(&source)
            || before.is_some_and(|target| !visible_set.contains(&target))
            || order
                .iter()
                .filter(|id| visible_set.contains(id))
                .copied()
                .collect::<Vec<_>>()
                != visible
        {
            return Err("清單已更新，請再拖一次。".into());
        }
        if before == Some(source) {
            return Ok(false);
        }
        let mut moved: Vec<_> = visible.iter().copied().filter(|id| *id != source).collect();
        let target = before
            .and_then(|id| moved.iter().position(|item| *item == id))
            .unwrap_or(moved.len());
        moved.insert(target, source);
        if moved == visible {
            return Ok(false);
        }
        let mut replacement = moved.into_iter();
        self.order = order
            .into_iter()
            .map(|id| {
                if visible_set.contains(&id) {
                    replacement.next().unwrap()
                } else {
                    id
                }
            })
            .collect();
        Ok(true)
    }
    /// Rename the legacy taxonomy without replacing titles or human category choices.
    /// Storage persists a byte-for-byte backup before committing this migration.
    pub fn upgrade_categories(&mut self) -> Result<bool, String> {
        if self.version == 2 {
            self.validate()?;
            return Ok(false);
        }
        if self.version != 1 {
            return Err("這份資料來自較新的版本，請先更新程式。".into());
        }
        let mut next = self.clone();
        for note in &mut next.notes {
            let mapped = match note.category.as_str() {
                "產品開發" => CATEGORIES[0],
                "內容寫作" => CATEGORIES[1],
                "營運溝通" => CATEGORIES[2],
                "生活" | "未分類" => CATEGORIES[4],
                _ => return Err("便條分類格式無法辨識，原檔未被改寫。".into()),
            };
            let inferred = local_category(&format!("{} {}", note.title, note.original));
            note.category = if note.ai == "已手動調整" || note.category == "生活" {
                mapped
            } else if note.category == "未分類"
                || inferred == CATEGORIES[3]
                || is_startup_application(&note.original)
            {
                inferred
            } else {
                mapped
            }
            .into();
        }
        next.version = 2;
        next.validate()?;
        *self = next;
        Ok(true)
    }
    pub fn capture(&mut self, raw: &str) -> Result<u64, String> {
        let text = raw.trim();
        if text.is_empty() {
            return Err("先寫一句要記住的事。".into());
        }
        if text.chars().count() > MAX_TEXT {
            return Err("一次最多 8,000 字，請分成幾張便條。".into());
        }
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1).ok_or("便條編號已達上限。")?;
        self.notes.push(Note {
            id,
            original: text.into(),
            title: text
                .lines()
                .next()
                .unwrap_or(text)
                .chars()
                .take(100)
                .collect(),
            category: self
                .settings
                .tags
                .iter()
                .filter(|t| {
                    t.key != "其他" && text.to_lowercase().contains(&t.label.to_lowercase())
                })
                .max_by_key(|t| t.label.len())
                .map(|t| t.key.clone())
                .unwrap_or_else(|| {
                    let key = local_category(text);
                    if self.has_tag(key) {
                        key.into()
                    } else {
                        "其他".into()
                    }
                }),
            status: Status::Inbox,
            resume: String::new(),
            created: now(),
            revision: 0,
            ai: "本機分類".into(),
            remind_at: None,
            reminder_due: false,
            timer_started: None,
            spent_seconds: None,
        });
        if !self.order.is_empty() {
            self.order.insert(0, id);
        }
        self.draft.clear();
        Ok(id)
    }
    pub fn set_status(&mut self, id: u64, status: Status) -> Result<(), String> {
        if !self.notes.iter().any(|n| n.id == id) {
            return Err("找不到這張便條。".into());
        }
        for note in &mut self.notes {
            if note.id == id {
                if status == Status::Done {
                    note.pause_timer(now());
                }
                note.status = status;
                note.revision += 1;
                if status != Status::Waiting {
                    note.remind_at = None;
                    note.reminder_due = false;
                }
            } else if status == Status::Now && note.status == Status::Now {
                note.status = Status::Later;
                note.revision += 1;
            }
        }
        Ok(())
    }
    pub fn edit(
        &mut self,
        id: u64,
        title: String,
        resume: String,
        category: String,
    ) -> Result<(), String> {
        if title.trim().is_empty() || title.chars().count() > 200 {
            return Err("便條標題請填 1 到 200 字。".into());
        }
        if resume.chars().count() > MAX_TEXT || !self.has_tag(&category) {
            return Err("請檢查回來步驟與分類。".into());
        }
        let n = self
            .notes
            .iter_mut()
            .find(|n| n.id == id)
            .ok_or("找不到這張便條。")?;
        if n.title != title.trim() || n.resume != resume.trim() || n.category != category {
            n.title = title.trim().into();
            n.resume = resume.trim().into();
            n.category = category;
            n.revision += 1;
            n.ai = "已手動調整".into();
        }
        Ok(())
    }
    // A model can label only the capture it received. It never alters status, timers,
    // other notes, or a note edited while the request was running.
    pub fn apply_ai(&mut self, id: u64, revision: u64, title: String, category: String) -> bool {
        if !self.has_tag(&category) {
            return false;
        }
        if let Some(n) = self
            .notes
            .iter_mut()
            .find(|n| n.id == id && n.revision == revision && n.status != Status::Done)
            && !title.trim().is_empty()
            && title.chars().count() <= 100
        {
            n.title = title.trim().into();
            n.category = category;
            n.ai = "AI 分類".into();
            n.revision += 1;
            return true;
        }
        false
    }
    pub fn due_reminders(&mut self, at: u64) -> bool {
        let mut changed = false;
        for n in &mut self.notes {
            if n.status == Status::Waiting && n.remind_at.is_some_and(|t| t <= at) {
                n.remind_at = None;
                n.reminder_due = true;
                changed = true;
            }
        }
        changed
    }
}

fn is_startup_application(text: &str) -> bool {
    let lower = text.to_lowercase();
    (lower.contains("startup") || lower.contains("新創"))
        && ["google", "申請", "補助", "credits", "額度", "計畫"]
            .iter()
            .any(|s| lower.contains(s))
}
pub fn local_category(text: &str) -> &'static str {
    let lower = text.to_lowercase();
    if ["客戶", "委託案", "外部案"]
        .iter()
        .any(|word| lower.contains(word))
    {
        return CATEGORIES[3];
    }
    if is_startup_application(text) {
        return CATEGORIES[2];
    }
    let words: [&[&str]; 4] = [
        &[
            "bug",
            "code",
            "deploy",
            "api",
            "pr ",
            "測試",
            "程式",
            "開發",
            "部署",
            "修復",
            "產品",
            "架構",
            "功能",
            "上限問題",
        ],
        &[
            "文章",
            "文稿",
            "寫稿",
            "貼文",
            "寫作",
            "簡報",
            "投影片",
            "影片",
            "社群",
            "linkedin",
            "threads",
            "行銷",
            "gtm",
            "go-to-market",
            "獲客",
            "推廣",
            "seo",
        ],
        &[
            "會議", "合約", "發票", "報價", "回信", "投資", "合作", "帳務", "營運", "申請", "補助",
            "startup", "新創", "募資",
        ],
        &["外務", "外部案", "客戶案", "接案", "委託", "交付客戶"],
    ];
    let best = words
        .iter()
        .enumerate()
        .map(|(i, w)| (i, w.iter().filter(|s| lower.contains(**s)).count()))
        .max_by_key(|(_, n)| *n);
    match best {
        Some((i, n)) if n > 0 => CATEGORIES[i],
        _ => CATEGORIES[4],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn switching_preserves_return_step_and_keeps_one_active() {
        let mut b = Board::default();
        let a = b.capture("修 bug").unwrap();
        let c = b.capture("回客戶信").unwrap();
        b.edit(
            a,
            "修 bug".into(),
            "回來先看測試結果".into(),
            CATEGORIES[0].into(),
        )
        .unwrap();
        b.set_status(a, Status::Now).unwrap();
        b.set_status(c, Status::Now).unwrap();
        assert_eq!(b.notes[0].status, Status::Later);
        assert_eq!(b.notes[0].resume, "回來先看測試結果");
        b.validate().unwrap();
    }
    #[test]
    fn late_model_cannot_overwrite_human_edits_or_completion() {
        let mut b = Board::default();
        let id = b.capture("明天聯絡客戶").unwrap();
        b.edit(
            id,
            "寄報價".into(),
            "先確認價格".into(),
            CATEGORIES[2].into(),
        )
        .unwrap();
        assert!(!b.apply_ai(id, 0, "錯的標題".into(), CATEGORIES[0].into()));
        assert_eq!(b.notes[0].title, "寄報價");
        b.set_status(id, Status::Done).unwrap();
        assert!(!b.apply_ai(id, 2, "復活".into(), CATEGORIES[0].into()));
    }
    #[test]
    fn capture_is_lossless_and_does_not_switch_focus() {
        let mut b = Board::default();
        let a = b.capture("工作 A").unwrap();
        b.set_status(a, Status::Now).unwrap();
        let text = "第一件事\n第二件事\n第三件事";
        b.capture(text).unwrap();
        assert_eq!(b.notes[1].original, text);
        assert_eq!(b.notes[0].status, Status::Now);
        assert!(b.capture("  ").is_err());
        assert_eq!(b.notes.len(), 2);
    }
    #[test]
    fn reminder_fires_once_and_completion_cancels_it() {
        let mut b = Board::default();
        let id = b.capture("等測試").unwrap();
        b.set_status(id, Status::Waiting).unwrap();
        b.notes[0].remind_at = Some(100);
        assert!(!b.due_reminders(99));
        assert!(b.due_reminders(100));
        assert!(!b.due_reminders(101));
        b.set_status(id, Status::Done).unwrap();
        assert!(!b.notes[0].reminder_due);
    }
    #[test]
    fn categories_follow_the_users_workstreams() {
        assert_eq!(local_category("一個星期的文稿"), CATEGORIES[1]);
        assert_eq!(
            local_category("申請 Google startup API credits"),
            CATEGORIES[2]
        );
        assert_eq!(local_category("客戶 的開發測試"), CATEGORIES[3]);
        assert_eq!(local_category("外部案架構圖"), CATEGORIES[3]);
        assert_eq!(local_category("委託案架構圖"), CATEGORIES[3]);
        assert_eq!(local_category("50人上限問題"), CATEGORIES[0]);
        assert_eq!(local_category("其他想法"), CATEGORIES[4]);
    }
    #[test]
    fn migration_preserves_manual_choices_and_rejects_unknown_legacy_categories() {
        let mut b = Board::default();
        b.capture("客戶 的產品開發").unwrap();
        b.version = 1;
        b.notes[0].category = "產品開發".into();
        b.notes[0].ai = "已手動調整".into();
        assert!(b.upgrade_categories().unwrap());
        assert_eq!(b.notes[0].category, CATEGORIES[0]);
        assert!(!b.upgrade_categories().unwrap());
        b.version = 1;
        b.notes[0].category = "未知損壞值".into();
        assert!(b.upgrade_categories().is_err());
        assert_eq!(b.version, 1);
        assert_eq!(b.notes[0].category, "未知損壞值");
    }
    #[test]
    fn manual_order_survives_status_changes_ai_results_and_new_capture() {
        let mut b = Board::default();
        let a = b.capture("a").unwrap();
        let c = b.capture("c").unwrap();
        let d = b.capture("d").unwrap();
        b.set_status(a, Status::Now).unwrap();
        assert_eq!(b.ordered_ids(), vec![a, d, c]);
        let content = serde_json::to_value(&b.notes).unwrap();
        assert!(b.reorder_visible(&[a, d, c], a, None).unwrap());
        assert_eq!(b.ordered_ids(), vec![d, c, a]);
        assert_eq!(serde_json::to_value(&b.notes).unwrap(), content);
        assert!(b.apply_ai(d, 0, "updated".into(), CATEGORIES[0].into()));
        b.set_status(c, Status::Now).unwrap();
        assert_eq!(b.ordered_ids(), vec![d, c, a]);
        let e = b.capture("new").unwrap();
        assert_eq!(b.ordered_ids(), vec![e, d, c, a]);
        b.validate().unwrap();
    }
    #[test]
    fn filtered_reorder_preserves_hidden_slots_and_rejects_stale_views() {
        let mut b = Board::default();
        for name in ["a", "b", "c", "d", "e"] {
            b.capture(name).unwrap();
        }
        assert!(b.reorder_visible(&[5, 3, 1], 1, Some(5)).unwrap());
        assert_eq!(b.order, vec![1, 4, 5, 2, 3]);
        assert!(b.reorder_visible(&[5, 3, 1], 5, None).is_err());
        assert!(b.reorder_visible(&[1, 1], 1, None).is_err());
        assert!(!b.reorder_visible(&[1, 5, 3], 5, Some(3)).unwrap());
        b.order.push(1);
        assert!(b.validate().is_err());
    }
    #[test]
    fn custom_tag_lifecycle() {
        let mut b = Board::default();
        b.change_tag(None, Some("課業")).unwrap();
        let id = b.capture("課業報告").unwrap();
        let key = b.notes[0].category.clone();
        assert_ne!(key, "其他");
        b.change_tag(Some(b.index(&key)), Some("上課")).unwrap();
        assert_eq!(b.notes[0].category, key);
        assert!(b.change_tag(None, Some("上課")).is_err());
        b.change_tag(Some(b.index(&key)), None).unwrap();
        assert_eq!(b.notes[0].category, "其他");
        assert!(!b.apply_ai(id, 0, "舊請求".into(), key));
        assert!(b.change_tag(Some(b.index("其他")), None).is_err());
        b.validate().unwrap();
    }
    #[test]
    fn invalid_data_is_rejected() {
        let mut b = Board::default();
        b.capture("a").unwrap();
        b.next_id = 1;
        assert!(b.validate().is_err());
    }
}

# 回來 · Return Note

一張放在 Windows 或 macOS 桌面角落的繁中待辦便條。切走前，留一句「回來先做什麼」。

比如等一輪測試時，你得先去回客戶。按 `⌥⌘N`（macOS）或 `Ctrl+Alt+N`（Windows）記下「回來先看登入失敗的兩筆」，按 Enter 就能繼續手上的事。回到桌面時，下一步就在那裡。

**[下載 Windows x64 版](https://github.com/wsxqaza12/return-note/releases/latest/download/return-note-windows-x64.zip)** · [發行紀錄](https://github.com/wsxqaza12/return-note/releases) · [回報問題](https://github.com/wsxqaza12/return-note/issues)

![回來的 Windows 桌面視窗，示範待辦依標籤排列](docs/desktop.png)

## macOS

需要 macOS 13 Ventura 或更新版本。Universal 安裝包同時包含 Apple Silicon 和 Intel 版本；解壓縮後，把 `Return Note.app` 拖到「應用程式」，再開啟。從原始碼建置的本機版本僅有臨時簽章，並未經 Apple 公證；若 Gatekeeper 阻擋，只在確認來源可信後，從「系統設定 → 隱私權與安全性」允許這個 App，不必關閉系統防護。

- **⌥⌘N** 叫回並聚焦便條。關閉視窗不會結束 App，也可從選單列的便條圖示叫回。**⌘F** 搜尋，**Enter** 加入，**⇧Enter** 換行。
- 雙擊標題編輯「回來先做什麼」，拖曳右側把手排序；點圖釘切換置頂，右鍵可切換狀態或設定 10 分鐘回看。提醒會在程式執行期間更新便條、選單列和 Dock 徽章。
- 預設離線，資料在 `~/Library/Application Support/ReturnNote/notes.json`。選「⋯ → 匯出便條」可備份。要從 Windows 搬資料，先結束 Mac 版並備份現有檔案，再將 Windows 的 `notes.json` 複製到上述位置（不會自動合併）。Windows 金鑰不隨 JSON 搬移，請在 Mac 版重新輸入。

### 選用 AI 分類（macOS）

在「⋯ → 設定」選擇 **Google Gemini** 或 **OpenAI（GPT）**，填入模型名稱和該服務的 API key。可先按「測試連線」，這只會送出固定的範例文字與通用標籤，不會送出真實便條或儲存設定，但可能產生 API 費用。確認後，勾選「用 AI 整理新便條」並儲存。每個供應商的金鑰分開存在 macOS 鑰匙圈，儲存時留空可保留既有金鑰。

- **Google Gemini**：在 [Google AI Studio](https://aistudio.google.com/apikey) 取得金鑰。Google AI Pro 的 AI Studio 每日額度不能直接用於外部 App，但可依 [Google 的方案說明](https://aistudio.google.com/docs/google-ai-plans) 領取適用於付費 Gemini API key 的 Google Cloud 點數。
- **OpenAI（GPT）**：在 [OpenAI API 平台](https://platform.openai.com/api-keys) 取得金鑰。需選擇支援 Responses API 結構化輸出的模型；[API 計費與 ChatGPT 訂閱分開](https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform)。[符合資格的 ChatGPT Pro／Business 訂閱](https://help.openai.com/en/articles/20001626-api-credits-benefit-for-eligible-chatgpt-subscriptions) 可另行領取 API 點數。

啟用後，新便條和手動重新分類的便條會將原文及可選標籤名稱送給目前選擇的供應商；不會將既有便條整批上傳。若連線失敗，原文與本機分類會保留。關閉 AI 後可完全離線使用。

### 在 macOS 建置

需要 Rust stable、rustup 及 Xcode Command Line Tools（`xcode-select --install`）。執行 App 不需要 Rust 或 Xcode。

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo test --locked
bash scripts/build-macos.sh
"dist/Return Note.app/Contents/MacOS/return-note" --smoke-test
open "dist/Return Note.app"
```

輸出在 `dist/Return Note.app` 和 `dist/return-note-macos-universal.zip`。只打包目前機器的架構，使用 `bash scripts/build-macos.sh native`。Smoke test 使用暫存便條，不會碰正式資料或鑰匙圈。

## 開始使用（Windows）

1. 下載 ZIP，完整解壓縮，雙擊 `return-note.exe`。這是 Rust 製作的 Windows 原生程式，可直接執行。發行檔尚未簽署，Windows 首次啟動時可能顯示提示。
2. 在底下打一句待辦，按 **Enter** 加入。**Shift+Enter** 換行，雙擊便條可編輯標題及「回來先做什麼」。
3. 把視窗拖到桌面角落。點圖釘可置頂，在 **⋯ → 字體與便條大小** 可選 70% 到 125%。左上角可收起分類側欄。

## 在便條上就能做的事

| 想做什麼 | 怎麼操作 |
| --- | --- |
| 整理待辦 | 新便條會自動分類。在「⋯ → 管理標籤」可新增、改名或刪除，最多 32 個。刪除前會提示確認，原便條會移到保留的「其他」。點彩色標籤可換分類，拖文字可排序。圖釘左邊的三條橫線可依標籤整理目前清單，同類內保留原順序。 |
| 記錄花費時間 | 點某一列的小時鐘開始，再點可暫停。勾選完成會停表，到「⋯ → 已完成的便條」查看累計用時。 |
| 等結果時先切走 | 右鍵選「等結果」，可加 10 分鐘回看提醒。提醒在程式執行期間生效。 |
| 找回之前的事 | 按 **Ctrl+F** 搜尋。視窗收到工作列後，用 **Ctrl+Alt+N** 叫回來。 |

## 本機資料與選用的 AI（Windows）

預設可離線使用，可依自訂標籤名稱配對便條，初始分類為產品開發、行銷 GTM、營運、外部案子與其他。想讓 Gemini 整理短標題及分類，可在「設定」填入自己的 Google Gemini API key，儲存後按「測試連線」。開啟後，新便條原文與可選標籤名稱會送到 Google。金鑰存於 Windows 認證管理員。

便條、排序、累計用時和草稿存於 `%LOCALAPPDATA%\ReturnNote\notes.json`。設定中的「匯出便條」可備份資料。要更新版本，先從選單結束程式，再換成新版執行檔。

## 從原始碼建置（Windows）

使用 Rust stable（edition 2024）。在 Linux／WSL 安裝 Rust 的 Windows x64 GNU LLVM target，並將 llvm-mingw 的 `bin` 加到 PATH。建置會用到其中的 clang 與 windres。

```sh
rustup target add x86_64-pc-windows-gnullvm
cargo test --locked
CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER=x86_64-w64-mingw32-clang \
  cargo build --locked --release --target x86_64-pc-windows-gnullvm
```

執行檔位於 `target/x86_64-pc-windows-gnullvm/release/return-note.exe`。Windows 操作測試見 [驗證腳本](scripts/verify-windows.ps1)。

## 為什麼留一句下一步

工作中斷時，先記下做到哪、之後從哪裡接手，有助於減少切換後仍惦記上一件事的注意力殘留。「回來先做什麼」這個欄位來自這個想法。[華盛頓大學研究說明](https://www.washington.edu/news/2018/01/16/task-interrupted-a-plan-for-returning-helps-you-move-on/)

#![cfg_attr(windows, windows_subsystem = "windows")]
#[cfg(windows)]
mod appearance;
#[cfg(windows)]
mod native;
#[cfg(windows)]
mod network;
fn main() {
    #[cfg(windows)]
    native::run();
    #[cfg(target_os = "macos")]
    eprintln!("macOS 請執行 bash scripts/build-macos.sh，再開啟 dist/Return Note.app。");
    #[cfg(not(any(windows, target_os = "macos")))]
    eprintln!("回來的桌面版支援 Windows 與 macOS。可在此平台執行 cargo test 驗證資料核心。");
}

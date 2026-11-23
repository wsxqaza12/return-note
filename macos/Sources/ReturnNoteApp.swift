import AppKit
import SwiftUI

@main
struct ReturnNoteApp {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--smoke-test" {
            exit(runSmokeTest())
        }
        // The shared Rust store inherits this process umask, including drafts and backups.
        _ = umask(0o077)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReturnNote", isDirectory: true)
        let delegate = AppDelegate(folder: folder)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let folder: URL
    private var model: BoardModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem?
    private var hotkey: GlobalHotkey?
    private var tick: Timer?
    private var observers: [NSObjectProtocol] = []

    init(folder: URL) { self.folder = folder }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = BoardModel(core: Core(folder: folder))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 415),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "回來 · Return Note"
        window.minSize = NSSize(width: 430, height: 330)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BoardView(model: model))
        if !window.setFrameUsingName("ReturnNoteMain"), let screen = NSScreen.main {
            let bounds = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: bounds.maxX - window.frame.width - 20, y: bounds.minY + 25))
        }
        window.setFrameAutosaveName("ReturnNoteMain")
        installMenus()
        hotkey = GlobalHotkey { [weak self] in self?.reveal() }
        model.hotkeyAvailable = hotkey?.register() == true
        if !model.hotkeyAvailable { statusItem?.menu?.item(at: 0)?.keyEquivalent = "" }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.model.flushDraft() }
        })
        tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        if let tick { RunLoop.main.add(tick, forMode: .common) }
        window.makeKeyAndOrderFront(nil)
        model.focusCapture()
        update()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { reveal(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.flushDraft() else { return false }
        sender.orderOut(nil)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil, !model.flushDraft() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "草稿尚未存好"
        alert.informativeText = model.notice
        alert.addButton(withTitle: "繼續編輯")
        alert.addButton(withTitle: "不儲存並結束")
        reveal()
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        tick?.invalidate()
        hotkey = nil
        model?.cancelAI()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func update() {
        model.tick()
        window.level = model.settings?.topmost == true ? .floating : .normal
        // A bulletin count is visible in Dock and the menu bar even when the window is closed.
        let badge = model.badge
        NSApp.dockTile.badgeLabel = badge > 0 ? String(badge) : nil
        statusItem?.button?.image = NSImage(systemSymbolName: badge > 0 ? "bell.badge" : "note.text", accessibilityDescription: "回來")
    }
    @objc private func reveal() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        model.focusCapture()
    }
    @objc private func findNotes() { reveal(); model.focusSearch() }
    @objc private func exportNotes() { reveal(); model.exportSheet(window) }
    @objc private func openFolder() { NSWorkspace.shared.open(folder) }

    private func menuItem(_ label: String, _ selector: Selector?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: label, action: selector, keyEquivalent: key)
        item.target = target
        return item
    }
    private func installMenus() {
        let bar = NSMenu()
        let appMenu = NSMenu(title: "回來")
        appMenu.addItem(menuItem("關於回來", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("隱藏回來", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        appMenu.addItem(menuItem("結束回來", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        bar.addItem(NSMenuItem()); bar.items[0].submenu = appMenu

        let edit = NSMenu(title: "編輯")
        for (label, action, key) in [("復原", "undo:", "z"), ("重做", "redo:", "Z"), ("剪下", "cut:", "x"),
                                      ("拷貝", "copy:", "c"), ("貼上", "paste:", "v"), ("全選", "selectAll:", "a")] {
            edit.addItem(menuItem(label, NSSelectorFromString(action), key))
        }
        edit.addItem(.separator())
        edit.addItem(menuItem("搜尋便條", #selector(findNotes), "f", target: self))
        let editRoot = NSMenuItem(title: "編輯", action: nil, keyEquivalent: "")
        editRoot.submenu = edit; bar.addItem(editRoot)

        let windows = NSMenu(title: "視窗")
        windows.addItem(menuItem("關閉視窗", #selector(NSWindow.performClose(_:)), "w"))
        windows.addItem(menuItem("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        let windowsRoot = NSMenuItem(title: "視窗", action: nil, keyEquivalent: "")
        windowsRoot.submenu = windows; bar.addItem(windowsRoot)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let show = menuItem("顯示回來", #selector(reveal), "n", target: self)
        show.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(show)
        menu.addItem(menuItem("搜尋便條", #selector(findNotes), target: self))
        menu.addItem(menuItem("匯出便條…", #selector(exportNotes), target: self))
        menu.addItem(menuItem("開啟資料夾", #selector(openFolder), target: self))
        menu.addItem(.separator())
        menu.addItem(menuItem("結束回來", #selector(NSApplication.terminate(_:)), target: NSApp))
        status.menu = menu
        statusItem = status
    }
}

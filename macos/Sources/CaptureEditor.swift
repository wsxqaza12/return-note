import AppKit
import SwiftUI

struct CaptureEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let submit: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: CaptureEditor
        weak var editor: InputView?
        init(_ owner: CaptureEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            if let editor, !editor.hasMarkedText() { owner.text = editor.string }
        }
        @objc func focus() {
            guard let editor, let window = editor.window, window.isKeyWindow else { return }
            window.makeFirstResponder(editor)
        }
    }

    final class InputView: NSTextView {
        var capture: (() -> Void)?
        override func doCommand(by selector: Selector) {
            if selector == #selector(NSTextView.insertNewline(_:)), !hasMarkedText(), let event = NSApp.currentEvent,
               event.type == .keyDown, !event.modifierFlags.contains(.shift), let capture {
                capture(); return
            }
            super.doCommand(by: selector)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = InputView(frame: scroll.contentView.bounds)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 3, height: 5)
        editor.setAccessibilityLabel("新增便條")
        editor.setAccessibilityIdentifier("CaptureField")
        editor.delegate = context.coordinator
        context.coordinator.editor = editor
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.focus), name: BoardModel.focusCapture, object: nil)
        editor.capture = { [weak coordinator = context.coordinator] in
            guard let coordinator, let editor = coordinator.editor else { return }
            if coordinator.owner.text != editor.string { coordinator.owner.text = editor.string }
            coordinator.owner.submit()
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let editor = context.coordinator.editor, !editor.hasMarkedText() else { return }
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize) }
        if editor.string != text { editor.string = text }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

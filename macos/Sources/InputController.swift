import AppKit
import InputMethodKit

@objc(WeTypeInputController)
final class WeTypeInputController: IMKInputController {
    private var composition: Composition?
    private var panel: CandidatePanel?
    private weak var activeClient: AnyObject?
    private var lastMarkedText: String?
    private var caret = NSRect.zero

    private func configure(_ sender: Any?) {
        activeClient = sender as AnyObject?
        if let composition, composition.raw.isEmpty, composition.preferences != PreferencesStore.shared.current {
            composition.close()
            self.composition = nil
            panel?.orderOut(nil)
        }
        guard composition == nil else { return }
        guard let command = try? EngineCommand.load() else { return }
        let composition = Composition(engine: ProcessEngine(command: command), preferences: PreferencesStore.shared.current)
        let panel = CandidatePanel()
        panel.onSelect = { [weak composition] in composition?.selectVisible($0) }
        panel.onToggleExpand = { [weak composition] in composition?.toggleExpanded() }
        panel.onPage = { [weak composition] in composition?.handle(.page($0)) }
        panel.onSettings = { (NSApp.delegate as? AppDelegate)?.showSettings() }
        self.composition = composition
        self.panel = panel
        lastMarkedText = nil
        composition.onCommit = { [weak self] text in
            guard let self, let client = self.activeClient as? IMKTextInput else { return }
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.lastMarkedText = nil
        }
        composition.onUpdate = { [weak self] in self?.updateClient() }
    }

    override func activateServer(_ sender: Any!) { configure(sender) }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        configure(sender)
        guard let event, let composition, let key = inputKey(for: event, composition: composition) else { return false }
        return composition.handle(key)
    }

    override func commitComposition(_ sender: Any!) {
        activeClient = sender as AnyObject?
        composition?.fallback()
    }

    override func deactivateServer(_ sender: Any!) {
        activeClient = sender as AnyObject?
        composition?.close()
        panel?.orderOut(nil)
        composition = nil
        panel = nil
        activeClient = nil
        lastMarkedText = nil
        caret = .zero
    }

    private func updateClient() {
        guard let composition, let client = activeClient as? IMKTextInput else { return }
        let text = composition.preedit
        if text != lastMarkedText {
            client.setMarkedText(text, selectionRange: NSRange(location: (text as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            lastMarkedText = text
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            if rect.height > 0 && rect.origin.x.isFinite && rect.origin.y.isFinite { caret = rect }
        }
        if text.isEmpty { panel?.orderOut(nil) }
        else if caret.height > 0 { panel?.show(composition: composition, caret: caret) }
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        for (title, action) in [("设置…", #selector(openSettings(_:))), ("打开测试窗口", #selector(showTestWindow(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }
    @objc private func openSettings(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.showSettings() }
    @objc private func showTestWindow(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.showDemo() }
}

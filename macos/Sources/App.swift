import AppKit
import InputMethodKit

final class DemoTextView: NSTextView {
    var composition: Composition?
    var candidatePanel: CandidatePanel?
    var beforeInput: (() -> Void)?
    // This view already owns composition. Bypass the active system input
    // method so testing WeType never composes the same keys twice.
    override var inputContext: NSTextInputContext? { nil }

    override func keyDown(with event: NSEvent) {
        beforeInput?()
        guard let composition, let key = inputKey(for: event, composition: composition), composition.handle(key) else {
            super.keyDown(with: event)
            return
        }
    }

    func refreshComposition() {
        guard let composition else { return }
        let text = composition.preedit
        setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                      replacementRange: NSRange(location: NSNotFound, length: 0))
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        candidatePanel?.show(composition: composition, caret: rect)
    }

    override func resignFirstResponder() -> Bool {
        composition?.fallback()
        return super.resignFirstResponder()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var server: IMKServer?
    private var demoWindow: NSWindow?
    private var demoComposition: Composition?
    private weak var demoTextView: DemoTextView?
    private var settingsWindow: SettingsWindowController?

    private var draftURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WeTypeIME/TestDraft.txt")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appMenu = NSMenu(title: "WeType")
        appMenu.addItem(withTitle: "打开测试窗口", action: #selector(showDemo), keyEquivalent: "")
        appMenu.items.last?.target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.items.last?.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WeType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showSettings),
            name: Notification.Name("io.github.plintash.wetype.showSettings"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showDemo),
            name: Notification.Name("io.github.plintash.wetype.showDemo"), object: nil)
        server = IMKServer(name: "io.github.plintash.inputmethod.wetype_Connection",
                           bundleIdentifier: Bundle.main.bundleIdentifier)
        // The test window can coexist with an active system input-method server.
        // The system can launch without arguments; keep that path background-only.
        if CommandLine.arguments.contains("--demo") { showDemo() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }

    @objc func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showDemo() {
        if let window = demoWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "WeType · 小鹤双拼"
        window.minSize = NSSize(width: 540, height: 360)
        window.delegate = self
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "打字，按自己的习惯。")
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        let description = NSTextField(labelWithString: "空格选词  ·  ← → 选择  ·  ↓ 展开候选  ·  − / = 翻页")
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        let status = NSTextField(labelWithString: "输入 nihc 试试「你好」")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        let text = DemoTextView(frame: .zero)
        text.isRichText = false
        text.delegate = self
        text.string = (try? String(contentsOf: draftURL, encoding: .utf8)) ?? ""
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .systemFont(ofSize: 22)
        text.textContainerInset = NSSize(width: 18, height: 20)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        demoTextView = text
        let stack = NSStackView(views: [title, description, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        do {
            let engine = ProcessEngine(command: try EngineCommand.load())
            engine.onStatus = { message in status.stringValue = message }
            let composition = Composition(engine: engine, preferences: PreferencesStore.shared.current)
            let panel = CandidatePanel()
            panel.onSelect = { [weak composition] index in composition?.selectVisible(index) }
            panel.onToggleExpand = { [weak composition] in composition?.toggleExpanded() }
            panel.onPage = { [weak composition] in composition?.handle(.page($0)) }
            panel.onSettings = { [weak self] in self?.showSettings() }
            text.composition = composition
            text.candidatePanel = panel
            composition.onCommit = { [weak text] string in
                text?.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            composition.onUpdate = { [weak text] in text?.refreshComposition() }
            demoComposition = composition
            text.beforeInput = { [weak self, weak text, weak status] in
                guard let self, let text, let current = text.composition,
                      current.raw.isEmpty, current.preferences != PreferencesStore.shared.current,
                      let command = try? EngineCommand.load() else { return }
                current.close()
                let engine = ProcessEngine(command: command)
                engine.onStatus = { [weak status] in status?.stringValue = $0 }
                let next = Composition(engine: engine, preferences: PreferencesStore.shared.current)
                text.composition = next
                self.demoComposition = next
                next.onCommit = { [weak text] in text?.insertText($0, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                next.onUpdate = { [weak text] in text?.refreshComposition() }
                text.candidatePanel?.onSelect = { [weak next] in next?.selectVisible($0) }
                text.candidatePanel?.onToggleExpand = { [weak next] in next?.toggleExpanded() }
                text.candidatePanel?.onPage = { [weak next] in next?.handle(.page($0)) }
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
        demoWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        demoComposition?.close()
        saveDraft()
        demoComposition = nil
        demoWindow = nil
        if server == nil { NSApp.terminate(nil) } else { NSApp.setActivationPolicy(.accessory) }
    }

    private func saveDraft() {
        guard let text = demoTextView?.string else { return }
        try? FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: draftURL, atomically: true, encoding: .utf8)
    }

    func textDidChange(_ notification: Notification) {
        if demoTextView?.hasMarkedText() == false { saveDraft() }
    }

    func applicationWillTerminate(_ notification: Notification) { demoComposition?.close(); saveDraft() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showSettings() }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { demoComposition?.fallback() }
}

@main
struct WeTypeApp {
    static func main() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if running {
            let action = CommandLine.arguments.contains("--demo") ? "showDemo" : "showSettings"
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("io.github.plintash.wetype.\(action)"), object: nil,
                userInfo: nil, deliverImmediately: true)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

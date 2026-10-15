import AppKit
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    private let scheme = NSPopUpButton()
    private let pageSize = NSPopUpButton()
    private let limit = NSPopUpButton()
    private let punctuation = NSButton(checkboxWithTitle: "使用中文标点（小数点和数字后的逗号保留半角）", target: nil, action: nil)
    private let glossary = NSButton(checkboxWithTitle: "在候选词下显示英文释义", target: nil, action: nil)
    private let glossaryStatus = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "设置会在当前这次输入结束后生效。")
    private let store = PreferencesStore.shared

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WeType 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        scheme.addItems(withTitles: ["小鹤双拼", "全拼"])
        pageSize.addItems(withTitles: (1...10).map { "\($0) 个" })
        limit.addItems(withTitles: ["10 个", "20 个", "40 个", "72 个"])
        let title = NSTextField(labelWithString: "输入与候选")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "拼音方案"), scheme],
            [NSTextField(labelWithString: "单行候选数"), pageSize],
            [NSTextField(labelWithString: "候选总数上限"), limit]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        glossaryStatus.font = .systemFont(ofSize: 12)
        glossaryStatus.textColor = .secondaryLabelColor
        let importButton = NSButton(title: "导入 TSV 词表…", target: self, action: #selector(importGlossary))
        let folderButton = NSButton(title: "打开数据文件夹", target: self, action: #selector(openData))
        let logButton = NSButton(title: "打开日志文件夹", target: self, action: #selector(openLogs))
        let restore = NSButton(title: "恢复默认设置", target: self, action: #selector(restoreDefaults))
        let folders = NSStackView(views: [folderButton, logButton, restore])
        folders.spacing = 12
        let help = NSTextField(wrappingLabelWithString: "← → 选择候选，↓ 展开更多，↑ 返回单行；空格确认，Esc 收起或取消。− / =、[ / ]、Page Up / Down 翻页。英文词表仅用于本地显示，不改变上屏内容。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, grid, punctuation, glossary,
                                       NSStackView(views: [importButton, glossaryStatus]), help, folders, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for control in [scheme, pageSize, limit, punctuation, glossary] as [NSControl] {
            control.target = self
            control.action = #selector(save)
        }
        load()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func load() {
        let preferences = store.current
        scheme.selectItem(at: preferences.scheme == "full" ? 1 : 0)
        pageSize.selectItem(at: preferences.pageSize - 1)
        limit.selectItem(at: [10, 20, 40, 72].firstIndex(of: preferences.maxCandidates) ?? 3)
        punctuation.state = preferences.fullwidthPunctuation ? .on : .off
        glossary.state = preferences.showGlossary ? .on : .off
        glossaryStatus.stringValue = store.glossary.entries.isEmpty ? "未导入词表" : "已载入 \(store.glossary.entries.count) 条释义"
    }
    @objc private func save() {
        var preferences = InputPreferences()
        preferences.scheme = scheme.indexOfSelectedItem == 1 ? "full" : "flypy"
        preferences.pageSize = pageSize.indexOfSelectedItem + 1
        preferences.maxCandidates = [10, 20, 40, 72][limit.indexOfSelectedItem]
        preferences.fullwidthPunctuation = punctuation.state == .on
        preferences.showGlossary = glossary.state == .on
        store.save(preferences)
        status.stringValue = "已保存。当前这次输入结束后生效。"
    }
    @objc private func restoreDefaults() { store.save(InputPreferences()); load(); status.stringValue = "已恢复默认设置。" }
    @objc private func openData() { NSWorkspace.shared.open(PreferencesStore.directory) }
    @objc private func openLogs() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WeTypeIME")) }
    @objc private func importGlossary() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard let window else { return }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = picker.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1024 * 1024 else { throw NSError(domain: "WeType", code: 1, userInfo: [NSLocalizedDescriptionKey: "词表超过 32 MB，请使用较小的 TSV 文件。"] ) }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard !Glossary(text).entries.isEmpty else { throw NSError(domain: "WeType", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有找到有效释义。格式为：词语、Tab、英文释义（每行一条）。"]) }
                try FileManager.default.createDirectory(at: PreferencesStore.directory, withIntermediateDirectories: true)
                try text.write(to: PreferencesStore.glossaryURL, atomically: true, encoding: .utf8)
                self.store.reloadGlossary()
                self.glossary.state = .on
                self.save()
                self.load()
                self.status.stringValue = "词表已复制到本地数据文件夹。"
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}

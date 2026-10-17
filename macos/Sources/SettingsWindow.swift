import AppKit
import UniformTypeIdentifiers

private final class SettingsNavigationCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 12, y: floor(rect.midY - 9), width: 18, height: 18)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let height = (title as NSString).size(withAttributes: [.font: font!]).height
        return NSRect(x: rect.minX + 40, y: floor(rect.midY - height / 2), width: max(0, rect.width - 52), height: height)
    }
    override func drawInterior(withFrame rect: NSRect, in controlView: NSView) {
        let color: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
        let symbol = image?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [color])))
        if let symbol {
            let slot = imageRect(forBounds: rect)
            let scale = min(slot.width / symbol.size.width, slot.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
        (title as NSString).draw(in: titleRect(forBounds: rect), withAttributes: [.font: font!, .foregroundColor: color])
    }
}

private final class SettingsNavigationButton: NSButton {
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.23 : 0.15).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let scheme = NSPopUpButton()
    private let pageSize = NSPopUpButton()
    private let limit = NSPopUpButton()
    private let punctuation = NSSwitch()
    private let glossary = NSSwitch()
    private let glossaryStatus = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let search = NSSearchField()
    private let table = NSTableView()
    private let listStatus = NSTextField(labelWithString: "")
    private let emptyState = NSTextField(wrappingLabelWithString: "打开此页时读取本机的学习记录。")
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let detailTitle = NSTextField(labelWithString: "选中一个字词，查看学习状态")
    private let heat = NSTextField(labelWithString: "学习权重  —")
    private let historyHeat = NSTextField(labelWithString: "历史权重  —")
    private let learnCount = NSTextField(labelWithString: "累计计数  —")
    private let lastUsed = NSTextField(labelWithString: "最近更新  —")
    private let backupButton = NSButton(title: "查看备份", target: nil, action: nil)
    private var learningBackup: URL?
    private let pages = NSView()
    private var navigation: [SettingsNavigationButton] = []
    private var pageViews: [NSView] = []
    private var records: [LearnedWord] = []
    private var rows: [LearnedWord] = []
    private var loading = false
    private var resetting = false
    private var loaded = false
    private let resetLearningAction: (LearningResetRequest, @escaping (Result<URL, Error>) -> Void) -> Void
    private let loadLearningAction: (@escaping (Result<[LearnedWord], Error>) -> Void) -> Void
    private let store = PreferencesStore.shared

    init(loadLearning: @escaping (@escaping (Result<[LearnedWord], Error>) -> Void) -> Void = { completion in
        do { LearningResetService.load(command: try EngineCommand.load(), completion: completion) }
        catch { completion(.failure(error)) }
    }, resetLearning: @escaping (LearningResetRequest, @escaping (Result<URL, Error>) -> Void) -> Void = { request, completion in
        do { LearningResetService.reset(request, command: try EngineCommand.load(), completion: completion) }
        catch { completion(.failure(error)) }
    }) {
        resetLearningAction = resetLearning
        loadLearningAction = loadLearning
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "巨疑设置"
        window.minSize = NSSize(width: 800, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        scheme.addItems(withTitles: ["小鹤双拼", "全拼"])
        pageSize.addItems(withTitles: (1...10).map { "\($0) 个" })
        limit.addItems(withTitles: ["10 个", "20 个", "40 个", "72 个"])
        for control in [scheme, pageSize, limit, punctuation, glossary] as [NSControl] {
            control.target = self
            control.action = #selector(save)
        }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let brand = label("巨疑输入法", size: 14, weight: .semibold)
        let brandIcon = NSImageView(image: NSImage(named: NSImage.applicationIconName)!)
        brandIcon.identifier = NSUserInterfaceItemIdentifier("settings.logo")
        brandIcon.setAccessibilityLabel("巨疑输入法")
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        brandIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let brandRow = NSStackView(views: [brandIcon, brand])
        brandRow.spacing = 10
        brandRow.alignment = .centerY
        let nav = vertical([], spacing: 5)
        for (index, item) in [("输入与候选", "keyboard"), ("词语学习", "text.book.closed"), ("词表与数据", "externaldrive")].enumerated() {
            let button = SettingsNavigationButton()
            button.cell = SettingsNavigationCell(textCell: item.0)
            button.setButtonType(.momentaryPushIn)
            button.target = self
            button.action = #selector(changePage(_:))
            button.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("settings.page.\(index)")
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            navigation.append(button)
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }
        let sidebarStack = vertical([brandRow, nav], spacing: 26)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)
        let signature = label("WeSus", size: 11, color: .tertiaryLabelColor)
        signature.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(signature)
        pages.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(sidebar)
        content.addSubview(pages)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.identifier = NSUserInterfaceItemIdentifier("settings.status")
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 14).isActive = true
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 180),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            nav.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            signature.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            signature.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
            pages.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            pages.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            pages.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: pages.leadingAnchor), status.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        pageViews = [inputPage(), learningPage(), dataPage()]
        for page in pageViews {
            page.translatesAutoresizingMaskIntoConstraints = false
            pages.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pages.leadingAnchor), page.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
                page.topAnchor.constraint(equalTo: pages.topAnchor), page.bottomAnchor.constraint(equalTo: pages.bottomAnchor)
            ])
        }
        load()
        showPage(0)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
    private func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
    private func heading(_ title: String, _ subtitle: String? = nil) -> NSView {
        var views: [NSView] = [label(title, size: 22, weight: .semibold)]
        if let subtitle { views.append(label(subtitle, size: 12, color: .secondaryLabelColor)) }
        return vertical(views, spacing: 6)
    }
    private func card(_ views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 16, height: 14)
        let stack = vertical(views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }
    private func row(_ title: String, description: String? = nil, control: NSView) -> NSView {
        var labels: [NSView] = [label(title)]
        if let description { labels.append(label(description, size: 11, color: .secondaryLabelColor)) }
        let text = vertical(labels, spacing: 4)
        text.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        let result = NSStackView(views: [text, spacer, control])
        result.spacing = 16
        return result
    }
    private func page(_ views: [NSView], fill: NSView? = nil) -> NSView {
        let stack = vertical(views, spacing: 18)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if fill == nil { stack.addArrangedSubview(NSView()) }
        return stack
    }
    private func inputPage() -> NSView {
        for popup in [scheme, pageSize, limit] { popup.widthAnchor.constraint(equalToConstant: 150).isActive = true }
        let options = card([
            row("拼音方案", control: scheme),
            row("单行候选数", control: pageSize),
            row("候选总数上限", control: limit)
        ])
        let marks = card([row("中文标点", description: "小数点和数字后的逗号保留半角", control: punctuation)])
        let keys = card([
            row("确认候选", control: label("空格", size: 12, weight: .medium, color: .secondaryLabelColor)),
            row("移动、展开与收起", control: label("↑ ↓ ← →", size: 12, weight: .medium, color: .secondaryLabelColor)),
            row("翻页", control: label("− / =   或   [ / ]", size: 12, weight: .medium, color: .secondaryLabelColor)),
            row("收起或取消", control: label("Esc", size: 12, weight: .medium, color: .secondaryLabelColor))
        ])
        return page([heading("输入与候选"), options, marks,
                     label("常用按键", size: 12, weight: .semibold, color: .secondaryLabelColor), keys])
    }
    private func learningPage() -> NSView {
        search.placeholderString = "搜索字词或拼音"
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("learning.search")
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新学习记录")
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshLearning)
        refreshButton.toolTip = "重新读取本机学习记录"
        refreshButton.identifier = NSUserInterfaceItemIdentifier("learning.refresh")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let searchRow = NSStackView(views: [search, spinner, refreshButton])
        searchRow.spacing = 10
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listStatus.font = .systemFont(ofSize: 11)
        listStatus.textColor = .secondaryLabelColor
        listStatus.identifier = NSUserInterfaceItemIdentifier("learning.summary")
        table.identifier = NSUserInterfaceItemIdentifier("learning.table")
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .inset
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        for (id, width) in [("word", 210.0), ("rank", 210.0), ("reset", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = id == "word" ? 120 : width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let tableBox = NSBox()
        tableBox.boxType = .custom
        tableBox.borderWidth = 1
        tableBox.cornerRadius = 10
        tableBox.borderColor = .separatorColor
        tableBox.fillColor = .controlBackgroundColor
        tableBox.contentViewMargins = NSSize(width: 2, height: 2)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tableBox.contentView!.addSubview(scroll)
        emptyState.font = .systemFont(ofSize: 12)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        tableBox.contentView!.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: tableBox.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: tableBox.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tableBox.contentView!.topAnchor), scroll.bottomAnchor.constraint(equalTo: tableBox.contentView!.bottomAnchor),
            tableBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            emptyState.centerXAnchor.constraint(equalTo: tableBox.contentView!.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: tableBox.contentView!.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: tableBox.widthAnchor, constant: -40)
        ])
        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        for (field, id) in [(heat, "heat"), (historyHeat, "historyHeat"), (learnCount, "count"), (lastUsed, "lastUsed")] {
            field.font = .systemFont(ofSize: 12)
            field.identifier = NSUserInterfaceItemIdentifier("learning." + id)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let metrics = NSStackView(views: [vertical([heat, historyHeat], spacing: 8),
                                          vertical([learnCount, lastUsed], spacing: 8)])
        metrics.distribution = .fillEqually
        metrics.alignment = .top
        metrics.spacing = 24
        let note = label("权重是引擎热度值，排名还受基础词频影响。", size: 11, color: .secondaryLabelColor)
        let detail = card([detailTitle, metrics, note])
        backupButton.target = self
        backupButton.action = #selector(openLearningBackup)
        backupButton.isHidden = true
        let footer = NSStackView(views: [label("重置前自动备份", size: 11, color: .secondaryLabelColor), NSView(), backupButton])
        footer.spacing = 8
        return page([heading("词语学习", "查看提权词，或搜索字词与拼音。"),
                     searchRow, listStatus, tableBox, detail, footer], fill: tableBox)
    }
    private func dataPage() -> NSView {
        glossaryStatus.font = .systemFont(ofSize: 11)
        glossaryStatus.textColor = .secondaryLabelColor
        let importButton = NSButton(title: "导入词表…", target: self, action: #selector(importGlossary))
        let dictionary = card([
            row("英文释义", description: "在候选词下显示本地英文释义", control: glossary),
            row("本地词表", control: importButton), glossaryStatus,
            label("UTF-8 TSV：每行“中文词 + Tab + 英文释义”。", size: 11, color: .secondaryLabelColor)
        ])
        let data = card([
            row("学习数据与词表", control: NSButton(title: "打开数据文件夹", target: self, action: #selector(openData))),
            row("诊断日志", control: NSButton(title: "打开日志文件夹", target: self, action: #selector(openLogs))),
            row("重置前的学习备份", control: NSButton(title: "打开备份文件夹", target: self, action: #selector(openBackups)))
        ])
        let restore = card([row("恢复输入设置", description: "保留词表及所有词语学习记录", control: NSButton(title: "恢复默认设置", target: self, action: #selector(restoreDefaults)))])
        return page([heading("词表与数据"), dictionary, data, restore])
    }

    @objc private func changePage(_ sender: NSButton) { showPage(sender.tag) }
    private func showPage(_ index: Int) {
        if !resetting { status.stringValue = "" }
        for (i, view) in pageViews.enumerated() { view.isHidden = i != index; navigation[i].selected = i == index }
        if index == 1 && !loaded && !loading { refreshLearning() }
    }
    @objc private func refreshLearning() {
        guard !loading && !resetting else { return }
        loading = true
        refreshButton.isEnabled = false
        spinner.startAnimation(nil)
        listStatus.stringValue = "正在读取学习记录…"
        emptyState.stringValue = "正在读取本机学习状态…"
        emptyState.isHidden = !rows.isEmpty
        table.reloadData()
        loadLearningAction { [weak self] result in
            guard let self else { return }
            self.loading = false
            self.refreshButton.isEnabled = true
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let records): self.records = records; self.loaded = true; self.updateResults()
            case .failure(let error):
                self.listStatus.stringValue = "读取失败，可点击刷新重试"
                self.emptyState.stringValue = error.localizedDescription
                self.emptyState.isHidden = !self.rows.isEmpty
                self.status.stringValue = error.localizedDescription
                self.table.reloadData()
            }
        }
    }
    func controlTextDidChange(_ notification: Notification) { if notification.object as AnyObject? === search { updateResults() } }
    private func updateResults() {
        if loading && records.isEmpty {
            rows = []
            table.reloadData()
            listStatus.stringValue = "正在读取学习记录…"
            emptyState.stringValue = "正在读取本机学习状态，搜索词已保留…"
            emptyState.isHidden = false
            updateDetail()
            return
        }
        let previous = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        let matches = LearnedWord.matching(records, query: search.stringValue)
        let searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let maximum = searching ? 50 : 10
        rows = Array(matches.prefix(maximum))
        listStatus.stringValue = searching ? "找到 \(matches.count) 项" : "提升明显 · \(matches.count) 项"
        if matches.count > maximum { listStatus.stringValue += " · 显示前 \(maximum) 项" }
        if loading { listStatus.stringValue += " · 正在刷新" }
        emptyState.stringValue = searching ? "没有找到这个字词或读音的学习记录。" : "没有明显提权的字词。\n也可以搜索字词或拼音，查看具体学习状态。"
        emptyState.isHidden = !rows.isEmpty
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == previous }) ?? (rows.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "word":
            let text = vertical([label(entry.word, size: 15, weight: .medium), label(entry.reading, size: 11, color: .secondaryLabelColor)], spacing: 3)
            text.toolTip = "引擎累计学习计数 \(entry.count)；点击查看权重与更新时间"
            return text
        case "rank":
            let title = label(entry.rankSummary, size: 12, weight: .medium)
            title.toolTip = "独立输入该读音时：基础词库排名 → 个人学习排名，比较前 72 项。"
            let subtitle = label(entry.lift > 0 ? "提升 \(entry.lift) 位" : "默认 → 当前排名", size: 11, color: entry.isProminent ? .systemOrange : .secondaryLabelColor)
            return vertical([title, subtitle], spacing: 3)
        case "reset":
            let button = NSButton(title: "重置学习…", target: self, action: #selector(resetRow(_:)))
            button.controlSize = .small
            button.tag = row
            button.isEnabled = !loading && !resetting
            button.identifier = NSUserInterfaceItemIdentifier("learning.reset.\(row)")
            return button
        default: return nil
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private func updateDetail() {
        guard rows.indices.contains(table.selectedRow) else {
            detailTitle.stringValue = "选中一个字词，查看学习状态"
            heat.stringValue = "学习权重  —"; historyHeat.stringValue = "历史权重  —"
            learnCount.stringValue = "累计计数  —"; lastUsed.stringValue = "最近更新  —"
            return
        }
        let entry = rows[table.selectedRow]
        detailTitle.stringValue = "\(entry.word) · \(entry.reading)"
        heat.stringValue = "学习权重  \(String(format: "%.6g", entry.heat))"
        historyHeat.stringValue = "历史权重  \(String(format: "%.6g", entry.historyHeat))"
        learnCount.stringValue = "累计计数  \(entry.count)"
        learnCount.toolTip = "引擎累计学习记录，不等于手动改选次数。"
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        lastUsed.stringValue = "最近更新  \(formatter.string(from: Date(timeIntervalSince1970: entry.lastUsed)))"
    }
    @objc private func resetRow(_ sender: NSButton) {
        guard !loading && !resetting, rows.indices.contains(sender.tag), let window else { return }
        let entry = rows[sender.tag]
        let request: LearningResetRequest
        do { request = try LearningResetRequest(pinyin: entry.pinyin, word: entry.word) }
        catch { status.stringValue = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = "重置「\(entry.word)」的学习？"
        alert.informativeText = "读音：\(entry.reading)。重置后恢复默认排序，自学词可能消失。将自动备份。"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.resetting = true
            self.refreshButton.isEnabled = false
            self.table.reloadData()
            self.status.stringValue = "正在重置「\(entry.word)」…"
            self.resetLearningAction(request) { [weak self] result in
                guard let self else { return }
                self.resetting = false
                self.refreshButton.isEnabled = true
                switch result {
                case .success(let backup):
                    self.learningBackup = backup
                    self.backupButton.isHidden = false
                    self.status.stringValue = "已重置「\(entry.word)」"
                    self.refreshLearning()
                case .failure(let error): self.status.stringValue = error.localizedDescription; self.table.reloadData()
                }
            }
        }
    }
    private func load() {
        let preferences = store.current
        scheme.selectItem(at: preferences.scheme == "full" ? 1 : 0)
        pageSize.selectItem(at: preferences.pageSize - 1)
        limit.selectItem(at: [10, 20, 40, 72].firstIndex(of: preferences.maxCandidates) ?? 3)
        punctuation.state = preferences.fullwidthPunctuation ? .on : .off
        glossary.state = preferences.showGlossary ? .on : .off
        glossaryStatus.stringValue = store.glossary.entries.isEmpty ? "尚未导入词表" : "已载入 \(store.glossary.entries.count) 条释义"
    }
    @objc private func save() {
        var preferences = InputPreferences()
        preferences.scheme = scheme.indexOfSelectedItem == 1 ? "full" : "flypy"
        preferences.pageSize = pageSize.indexOfSelectedItem + 1
        preferences.maxCandidates = [10, 20, 40, 72][limit.indexOfSelectedItem]
        preferences.fullwidthPunctuation = punctuation.state == .on
        preferences.showGlossary = glossary.state == .on
        store.save(preferences)
        status.stringValue = "已保存"
        status.toolTip = "当前组词结束后生效"
    }
    @objc private func restoreDefaults() { store.save(InputPreferences()); load(); status.stringValue = "已恢复输入设置" }
    @objc private func openLearningBackup() {
        if let learningBackup { NSWorkspace.shared.selectFile(learningBackup.path, inFileViewerRootedAtPath: "") }
    }
    @objc private func openBackups() {
        let path = PreferencesStore.directory.appendingPathComponent("LearningBackups")
        if FileManager.default.fileExists(atPath: path.path) { NSWorkspace.shared.open(path) }
        else { status.stringValue = "还没有学习重置备份。" }
    }
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
                guard size <= 32 * 1024 * 1024 else { throw LearningResetError("词表超过 32 MB，请使用较小的 TSV 文件。") }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard !Glossary(text).entries.isEmpty else { throw LearningResetError("没有找到有效释义。每行应为中文词、Tab、英文释义。") }
                try FileManager.default.createDirectory(at: PreferencesStore.directory, withIntermediateDirectories: true)
                try text.write(to: PreferencesStore.glossaryURL, atomically: true, encoding: .utf8)
                self.store.reloadGlossary()
                self.glossary.state = .on
                self.save(); self.load()
                self.status.stringValue = "词表已导入，英文释义已开启。"
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}

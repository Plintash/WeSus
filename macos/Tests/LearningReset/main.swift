import AppKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func wait(_ message: String, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), message)
}
func reply(_ engine: ProcessEngine, _ command: String) -> String {
    var response: String?
    engine.send(command) { response = $0 }
    wait("No reply to \(command)") { response != nil }
    return response!
}
func candidates(_ engine: ProcessEngine, _ keys: String) -> [Candidate] {
    check(reply(engine, "C") == "OK", "Reset failed")
    return Candidate.parse(reply(engine, "B \(keys)"))!
}
func learn(_ engine: ProcessEngine, _ keys: String, _ word: String) {
    let words = candidates(engine, keys)
    let rank = words.firstIndex { $0.text == word }!
    check(reply(engine, "S \(rank)") == "OK", "Selection failed")
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
}

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = base.appendingPathComponent(".deps/learning-settings-test.\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let request = try LearningResetRequest(pinyin: " HE ", word: " 鹤 ")
check(request.command == "FORGET\the\t鹤", "Request normalization failed")
let phraseRequest = try LearningResetRequest(pinyin: "ni hao", word: "拟好")
check(phraseRequest.pinyin == "ni'hao", "Syllable normalization failed")
for (pinyin, word) in [("", "鹤"), ("../he", "鹤"), ("he", ""), ("he", "鹤\t和"), ("ni1", "拟好")] {
    check((try? LearningResetRequest(pinyin: pinyin, word: word)) == nil, "Invalid request accepted")
}
print("PASS individual word validation and explicit full-pinyin syllables")

let command = EngineCommand(executable: base.appendingPathComponent("build/macos/WeTypeNativeEngine"),
    arguments: [base.appendingPathComponent(".deps/mac-engine/WeType.app").path,
                root.appendingPathComponent("Dictionary").path, "flypy"])
let engine = ProcessEngine(command: command)
let original = candidates(engine, "he")
for _ in 0..<2 { learn(engine, "he", "鹤"); learn(engine, "nihc", "拟好") }
check(candidates(engine, "he").first?.text == "鹤", "Failed to reproduce aggressive learning")
let learnedPhrase = candidates(engine, "nihc")
var busyResult: Result<URL, Error>?
LearningResetService.reset(request, command: command) { busyResult = $0 }
check(busyResult != nil && (try? busyResult!.get()) == nil, "Busy composition must block reset")
check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("LearningBackups").path), "Busy reset wrote a backup")
check(reply(engine, "C") == "OK", "Could not finish input")

var catalogResult: Result<[LearnedWord], Error>?
LearningResetService.load(command: command) { catalogResult = $0 }
wait("Catalog load timed out") { catalogResult != nil }
let catalog = try catalogResult!.get()
let crane = catalog.first { $0.word == "鹤" && $0.pinyin == "he" }!
check(crane.count == 2 && crane.currentRank == 1 && crane.baseRank == 10 && crane.heat > 1.8,
      "Catalog did not expose actual learning state and a clean baseline")
check(candidates(engine, "he").first?.text == "鹤", "Inspecting changed the learned word")
check(reply(engine, "C") == "OK", "Could not finish input after inspection")
check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("LearningBackups").path), "Read-only inspection created reset backups")
print("PASS snapshot inspection, actual counters/heat, clean baseline and unchanged source learning")

var resetResult: Result<URL, Error>?
LearningResetService.reset(request, command: command) { resetResult = $0 }
var concurrent: Result<URL, Error>?
LearningResetService.reset(request, command: command) { concurrent = $0 }
check(concurrent != nil && (try? concurrent!.get()) == nil, "Concurrent reset accepted")
wait("Settings reset timed out") { resetResult != nil }
let backup = try resetResult!.get()
check(FileManager.default.fileExists(atPath: backup.path), "Missing pre-reset backup")
check(candidates(engine, "he") == original, "Settings reset did not reload the idle connection")
check(candidates(engine, "nihc") == learnedPhrase, "Other learned phrase changed")
check(reply(engine, "C") == "OK", "Could not finish input")
print("PASS busy/concurrent protection, orderly shutdown, backup, targeted reset and connection reload")

var backupCommand = command.arguments
backupCommand[1] = backup.path
let backupEngine = ProcessEngine(command: EngineCommand(executable: command.executable, arguments: backupCommand))
check(candidates(backupEngine, "he").first?.text == "鹤", "Backup did not retain original learning")
check(candidates(backupEngine, "nihc") == learnedPhrase, "Backup lost phrase learning")
backupEngine.stop()
// Cover a reset immediately after deactivation starts Q/finalize.
engine.stop()
var phraseResult: Result<URL, Error>?
LearningResetService.reset(try LearningResetRequest(pinyin: "ni'hao", word: "拟好"), command: command) { phraseResult = $0 }
wait("Reset after deactivation timed out") { phraseResult != nil }
_ = try phraseResult!.get()
check(candidates(engine, "nihc").first?.text == "你好", "Phrase reset failed after deactivation")
check(candidates(engine, "he") == original, "Unrelated character changed after phrase reset")
engine.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("PASS usable backup and individual phrase reset after input-client deactivation")

let unavailable = EngineCommand(executable: root.appendingPathComponent("missing/WeTypeNativeEngine"), arguments: command.arguments)
var failure: Result<URL, Error>?
LearningResetService.reset(request, command: unavailable) { failure = $0 }
wait("Unavailable helper did not report failure") { failure != nil }
check((try? failure!.get()) == nil, "Unavailable helper reported success")
check(candidates(engine, "he") == original, "Failed reset changed the dictionary or kept input suspended")
engine.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("PASS helper startup failure preserves data and releases the input suspension")

_ = NSApplication.shared
func entry(_ word: String, _ pinyin: String, _ current: Int, _ baseline: Int, heat: Double = 1.99999) -> LearnedWord {
    LearnedWord(word: word, pinyin: pinyin, count: 2, lastUsed: Date().timeIntervalSince1970,
                heat: heat, historyHeat: 1.90484, currentRank: current, baseRank: baseline)
}
var fixtures = [entry("鹤", "he", 1, 10), entry("和", "he", 2, 1)]
check(LearnedWord.matching(fixtures + [entry("城", "cheng", 1, 1), entry("合并", "he'bing", 1, 1)], query: "he").count == 2,
      "Exact reading search included unrelated syllables or longer phrases")
check(LearnedWord.matching([entry("拟好", "ni'hao", 1, 3)], query: "ni hao").count == 1,
      "Joined full-pinyin search failed")
fixtures += (0..<14).map { entry(String(UnicodeScalar(0x4e00 + $0)!), "yi", 1, 15 + $0) }
var fakeRecords = fixtures
var pendingLoad: ((Result<[LearnedWord], Error>) -> Void)?
var delayLoad = true
var calls: [LearningResetRequest] = []
var completeReset: ((Result<URL, Error>) -> Void)?
let settings = SettingsWindowController(loadLearning: { completion in
    if delayLoad { pendingLoad = completion } else { completion(.success(fakeRecords)) }
}, resetLearning: { request, completion in
    calls.append(request); completeReset = completion
})
let window = settings.window!
window.alphaValue = 0
window.orderFront(nil)
func find(_ view: NSView, _ id: String) -> NSView? {
    if view.identifier?.rawValue == id { return view }
    return view.subviews.compactMap { find($0, id) }.first
}
let content = window.contentView!
check(find(content, "learning.word") == nil && find(content, "learning.pinyin") == nil,
      "Manual word/pinyin entry still required")
(find(content, "settings.page.1") as! NSButton).performClick(nil)
content.layoutSubtreeIfNeeded()
let search = find(content, "learning.search") as! NSSearchField
let table = find(content, "learning.table") as! NSTableView
let status = find(content, "settings.status") as! NSTextField
func searchFor(_ value: String) {
    search.stringValue = value
    settings.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    content.layoutSubtreeIfNeeded()
}
searchFor("he")
check((find(content, "learning.summary") as! NSTextField).stringValue.contains("正在读取"),
      "Searching during the first load incorrectly reported zero results")
searchFor("")
delayLoad = false
pendingLoad?(.success(fakeRecords))
check(table.numberOfRows == 10, "Default list must show only ten strongly promoted records")
searchFor("he")
check(table.numberOfRows == 2, "Pinyin search did not include all matching records")
check((find(content, "learning.heat") as! NSTextField).stringValue.contains("1.99999"), "Actual heat not displayed")
check((find(content, "learning.count") as! NSTextField).stringValue.contains("2"), "Cumulative count not displayed")
searchFor("鹤")
check(table.numberOfRows == 1, "Chinese word search failed")
searchFor("不存在的词")
check(table.numberOfRows == 0 && !(find(content, "learning.heat") as! NSTextField).stringValue.contains("1.99999"), "Empty search retained stale state")
searchFor("鹤")
func resetButton() -> NSButton { table.view(atColumn: 2, row: 0, makeIfNecessary: true) as! NSButton }
resetButton().performClick(nil)
wait("Missing confirmation sheet") { window.attachedSheet != nil }
window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
wait("Cancel did not dismiss") { window.attachedSheet == nil }
check(calls.isEmpty, "Cancel reset learning")
resetButton().performClick(nil)
wait("Missing second confirmation") { window.attachedSheet != nil }
window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
wait("Confirmed row reset was not dispatched") { calls.count == 1 }
check(calls[0].word == "鹤" && calls[0].pinyin == "he", "Reset targeted a different row")
check(!resetButton().isEnabled, "Reset can be submitted twice")
fakeRecords.removeAll { $0.word == "鹤" }
completeReset?(.success(backup))
check(table.numberOfRows == 0 && status.stringValue == "已重置「鹤」", "Reset did not refresh the current search with a concise confirmation")
wait("Sheet did not finish") { window.attachedSheet == nil }
fakeRecords = fixtures
(find(content, "learning.refresh") as! NSButton).performClick(nil)
searchFor("he")
check(table.numberOfRows == 2, "Refresh did not retain the active query")
resetButton().performClick(nil)
wait("Missing failure confirmation") { window.attachedSheet != nil }
window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
wait("Failure reset was not dispatched") { calls.count == 2 }
completeReset?(.failure(LearningResetError("测试重置失败")))
check(resetButton().isEnabled && status.stringValue == "测试重置失败", "Failure was hidden or controls stayed disabled")
for control in [search, table, find(content, "learning.heat")!, status] as [NSView] {
    let frame = control.convert(control.bounds, to: content)
    check(content.bounds.contains(frame), "Settings control clipped: \(control.identifier?.rawValue ?? "")")
}
let logo = find(content, "settings.logo") as! NSImageView
check(!logo.image!.isTemplate && logo.frame.size == NSSize(width: 32, height: 32), "Settings must use the application logo at a fixed size")
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearance)
    for size in [NSSize(width: 800, height: 598), NSSize(width: 840, height: 660), NSSize(width: 1040, height: 780)] {
        window.setContentSize(size)
        for index in 0..<3 {
            let button = find(content, "settings.page.\(index)") as! NSButton
            button.performClick(nil)
            content.layoutSubtreeIfNeeded()
            let cell = button.cell as! NSButtonCell
            let icon = cell.imageRect(forBounds: button.bounds)
            let title = cell.titleRect(forBounds: button.bounds)
            check(icon.minX >= 12 && title.minX - icon.maxX >= 10 && button.bounds.maxX - title.maxX >= 12,
                  "Navigation content is cramped or lacks consistent insets")
            check(title.width >= (button.title as NSString).size(withAttributes: [.font: button.font!]).width,
                  "Navigation title is clipped")
            check(status.stringValue.isEmpty, "A status message from another page leaked into this page")
            for control in [search, find(content, "learning.heat")!, find(content, "learning.lastUsed")!, status] {
                let frame = control.convert(control.bounds, to: content)
                check(content.bounds.contains(frame), "Settings control clipped at \(size): \(control.identifier?.rawValue ?? "")")
            }
            if size.width == 840 {
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("build/macos/settings-page-\(index).png"))
            }
        }
    }
}
window.orderOut(nil)
print("PASS compact pages, capped discovery list, word/pinyin search, actual state, per-row cancel/confirm, refresh and errors")

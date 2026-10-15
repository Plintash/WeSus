import Foundation

final class FakeEngine: EngineConnection {
    var onFailure: (() -> Void)?
    var requests: [(String, (String) -> Void)] = []
    func send(_ command: String, reply: @escaping (String) -> Void) { requests.append((command, reply)) }
    func stop() {}
    func answer(_ command: String, _ line: String) {
        guard let index = requests.firstIndex(where: { $0.0 == command }) else {
            fatalError("Missing request: \(command)")
        }
        requests.remove(at: index).1(line)
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

do {
    let engine = FakeEngine(), session = Composition(engine: FakeEngine())
    let model = Composition(engine: engine)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    for key in "nihc" { model.handle(.text(String(key))) }
    model.handle(.space)
    model.handle(.text("v"))
    require(model.preedit == "nihc v", "Pending selection must preserve subsequent input")
    engine.answer("B n", "CAND\t1:你")
    require(committed.isEmpty, "Old candidates cannot satisfy a newer Space")
    engine.answer("B c", "CAND\t4:你好\t2:你")
    engine.answer("S 0", "OK")
    require(committed == ["你好"] && model.raw == "v", "Space must select latest candidates and replay keys")
    require(session.raw.isEmpty, "Composition leaked to another session")
    print("PASS delayed Space, stale replies, queued input, session isolation")
}

do {
    let engine = FakeEngine()
    let session = Composition(engine: engine)
    var committed: [String] = []
    session.onCommit = { committed.append($0) }
    session.handle(.text("nihcvsgo"))
    engine.answer("B nihcvsgo", "CAND\t4:你好\t2:你")
    session.handle(.space)
    engine.answer("S 0", "CAND\t4:中国")
    require(committed == ["你好"] && session.raw == "vsgo", "Partial selection must consume physical keys")
    session.handle(.text("1"))
    engine.answer("S 0", "OK")
    require(committed == ["你好", "中国"] && session.raw.isEmpty, "Numeric selection failed")
    print("PASS Flypy partial coverage and numeric selection")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    model.handle(.text("nihc")); model.handle(.space)
    model.handle(.text("v")); model.handle(.backspace)
    engine.onFailure?()
    require(committed == ["nihc "], "Failure must retain Space and honor queued Backspace")
    engine.answer("B nihc", "CAND\t4:你好")
    require(committed == ["nihc "], "Late replies must not commit after failure")
    model.handle(.text("vsgo")); model.handle(.space); model.handle(.escape)
    engine.answer("B vsgo", "CAND\t4:中国")
    require(model.raw.isEmpty && committed == ["nihc "], "Esc must cancel delayed selection")
    print("PASS failure fallback, Backspace queue, Escape, late callback cancellation")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    model.handle(.text("nihc")); engine.answer("B nihc", "CAND\t4:你好")
    model.handle(.backspace)
    require(model.raw == "nih" && engine.requests.contains(where: { $0.0 == "B nih" }), "Backspace must rebuild the session")
    model.handle(.enter)
    require(committed == ["nih"], "Enter must commit original key sequence")
    model.handle(.text("3")); model.handle(.text(".")); model.handle(.text("1")); model.handle(.text(","))
    model.handle(.text("\"")); model.handle(.text("\""))
    require(committed.suffix(6) == ["3", ".", "1", ",", "“", "”"], "Numeric punctuation and quote pairing failed")
    require(Candidate.parse("CAND\t999:非法") == [Candidate(cover: 999, text: "非法")], "Parser failed")
    print("PASS Backspace rebuild, literal Enter, punctuation")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    model.handle(.text("nihc")); model.handle(.space); model.handle(.text("v"))
    engine.answer("B nihc", "CAND\t999:非法")
    require(committed == ["nihc v"], "Invalid coverage must preserve original input")
    require(Candidate.parse("CAND\tzero:bad") == nil, "Malformed response accepted")
    print("PASS malformed candidate and coverage fallback")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    model.handle(.text("n"))
    engine.answer("B n", "EMPTY")
    model.handle(.space)
    require(committed == ["n "] && model.raw.isEmpty,
            "Already resolved EMPTY must fall back immediately, without waiting five seconds")
    print("PASS Space after resolved EMPTY does not stall input")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    model.handle(.text("ni")); engine.answer("B ni", "CAND\t2:你\t2:呢")
    model.handle(.text("h"))
    require(model.candidates.map(\.text) == ["你", "呢"],
            "Typing must retain the visible candidates while the new reply is in flight; clearing them flickers the window")
    model.handle(.space)
    require(!engine.requests.contains(where: { $0.0.hasPrefix("S ") }), "Retained candidates must never select an outdated word")
    engine.answer("B h", "CAND\t3:你好")
    require(engine.requests.contains(where: { $0.0 == "S 0" }), "Space must wait for current candidates")
    print("PASS candidate continuity without stale selection")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    model.handle(.text("ni"))
    let words = (0..<42).map { "2:词\($0)" }.joined(separator: "\t")
    engine.answer("B ni", "CAND\t" + words)
    model.handle(.arrow(1, 0))
    require(model.selectedIndex == 1 && model.page == 0, "Right arrow must move highlight without committing")
    model.handle(.space)
    require(engine.requests.contains(where: { $0.0 == "S 1" }), "Space must select the highlighted word")
    engine.answer("S 1", "OK")
    model.handle(.text("ni")); engine.answer("B ni", "CAND\t" + words)
    model.handle(.arrow(0, 1))
    require(model.expanded && model.visibleCandidates.count == 29 && model.selectedIndex == 0, "Down must expand the first row plus four rows of six candidates")
    model.handle(.arrow(0, 1))
    require(model.selectedIndex == 5, "Down inside the grid must move one row")
    model.handle(.arrow(1, 0)); model.handle(.arrow(0, -1))
    require(model.selectedIndex == 1 && model.expanded, "Grid movement must preserve the column")
    model.handle(.arrow(0, -1))
    require(!model.expanded && model.selectedIndex == 1, "Up from the first row must collapse without losing selection")
    model.handle(.arrow(0, 1)); model.handle(.page(1))
    require(model.selectedIndex == 29 && model.page == 1, "Expanded paging must show the next candidate grid")
    model.handle(.text("2"))
    require(engine.requests.contains(where: { $0.0 == "S 30" }), "Number keys must match the numbered first row of the displayed page")
    engine.answer("S 30", "OK")
    require(!model.expanded && model.raw.isEmpty, "Commit must reset expanded state")
    require(!model.handle(.arrow(1, 0)), "Idle arrow keys must reach the application")
    print("PASS arrow selection, Space, expansion, grid navigation, paging and zero selection")
}

do {
    var preferences = InputPreferences()
    preferences.pageSize = 10
    preferences.fullwidthPunctuation = false
    let engine = FakeEngine(), model = Composition(engine: engine, preferences: preferences)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    model.handle(.text(","))
    require(committed == [","], "Halfwidth preference must reach punctuation behavior")
    model.handle(.text("ni")); engine.answer("B ni", "CAND\t" + (0..<10).map { "2:词\($0)" }.joined(separator: "\t"))
    require(model.visibleCandidates.count == 10, "Configured page size must reach the view model")
    model.handle(.text("0")); engine.answer("S 9", "OK")
    require(committed.last == "词9", "Ten-candidate pages must support zero")
    let suite = "WeTypeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    preferences.scheme = "full"; preferences.maxCandidates = 20; preferences.showGlossary = true
    preferences.save(to: defaults)
    require(InputPreferences(defaults: defaults) == preferences, "Settings must survive a fresh read")
    defaults.set(999, forKey: "pageSize"); defaults.set(-2, forKey: "maxCandidates")
    require(InputPreferences(defaults: defaults).pageSize == 10 && InputPreferences(defaults: defaults).maxCandidates == 10, "Corrupt settings must be bounded")
    let glossary = Glossary("# comment\r\n你好\tn. hello\r\n世界\te.g. world\textra\n坏行\n空\t\n你好\thi\n")
    require(glossary.entries == ["你好": "hi", "世界": "e.g. world"], "Glossary parsing must match Linux POS, comments, CRLF and duplicate handling")
    print("PASS settings persistence, bounds, page size, halfwidth punctuation and Linux-compatible glossary")
}

do {
    var preferences = InputPreferences()
    preferences.pageSize = 6
    let engine = FakeEngine(), model = Composition(engine: engine, preferences: preferences)
    var committed: [String] = []
    model.onCommit = { committed.append($0) }
    model.handle(.text("ni"))
    engine.answer("B ni", "CAND\t" + (0..<42).map { "2:词\($0)" }.joined(separator: "\t"))
    require(model.numberedCandidateRange == 0..<6, "The compact row must be numbered")
    model.handle(.arrow(0, 1))
    model.handle(.arrow(0, 1))
    model.handle(.arrow(1, 0))
    require(model.selectedIndex == 7, "Fixture must highlight the second candidate in the second row")
    require(model.numberedCandidateRange == 6..<12, "The number labels must move to the highlighted row")
    model.handle(.text("2"))
    require(engine.requests.contains(where: { $0.0 == "S 7" }),
            "Numeric selection must follow the highlighted row, rather than remaining bound to the first row")
    engine.answer("S 7", "OK")
    require(committed == ["词7"], "The numbered row must select the actual displayed word")
    print("PASS numeric selection follows the highlighted candidate row")
}

do {
    let engine = FakeEngine(), model = Composition(engine: engine)
    model.handle(.text("ni"))
    engine.answer("B ni", "CAND\t" + (0..<37).map { "2:词\($0)" }.joined(separator: "\t"))
    model.handle(.arrow(0, 1)); model.handle(.page(1)); model.handle(.arrow(0, 1))
    require(model.selectedIndex == 34 && model.numberedCandidateRange == 5..<8,
            "The last partial row must number only its three existing words")
    model.handle(.text("6"))
    require(!engine.requests.contains(where: { $0.0.hasPrefix("S ") }) && model.raw == "ni",
            "An empty numbered slot must not select a word from another row or emit a digit")
    model.handle(.arrow(0, -1))
    require(model.numberedCandidateRange == 0..<5, "Moving back up must restore top-row number bindings")
    model.handle(.arrow(0, 1)); model.handle(.text("3"))
    require(engine.requests.contains(where: { $0.0 == "S 36" }), "Numbers must include the displayed page offset")
    engine.answer("S 36", "OK")
    model.handle(.text("ni")); engine.answer("B ni", "CAND\t2:你\t2:呢")
    require(model.numberedCandidateRange == 0..<2 && !model.expanded,
            "Starting a new composition must reset the numbered row")
    print("PASS row bindings across pages, short final rows, upward movement and new composition")
}

print("COMPOSITION_RESULT = PASS")

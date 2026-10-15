import Foundation

struct Candidate: Equatable {
    let cover: Int
    let text: String

    static func parse(_ line: String) -> [Candidate]? {
        guard line.hasPrefix("CAND\t") else { return nil }
        var result: [Candidate] = []
        for item in line.split(separator: "\t").dropFirst() {
            guard let colon = item.firstIndex(of: ":"),
                  let cover = Int(item[..<colon]), cover > 0 else { return nil }
            let text = String(item[item.index(after: colon)...])
            guard !text.isEmpty else { return nil }
            result.append(Candidate(cover: cover, text: text))
        }
        return result.isEmpty ? nil : result
    }
}

protocol EngineConnection: AnyObject {
    var onFailure: (() -> Void)? { get set }
    func send(_ command: String, reply: @escaping (String) -> Void)
    func stop()
}

enum InputKey: Equatable {
    case text(String), space, backspace, escape, enter, page(Int), arrow(Int, Int), shortcut

    var literal: String {
        switch self {
        case .text(let text): return text
        case .space: return " "
        case .enter: return "\n"
        default: return ""
        }
    }
}

// Main-thread state shared by InputMethodKit and the standalone test window.
// The engine consumes physical keys: Flypy coverage must not be interpreted as
// full-pinyin character counts. Every reply is tied to the composition revision.
final class Composition {
    let engine: EngineConnection
    private(set) var raw = ""
    private(set) var candidates: [Candidate] = []
    private(set) var page = 0
    private(set) var selectedIndex = 0
    private(set) var expanded = false
    let preferences: InputPreferences
    var pageSize: Int { preferences.pageSize }
    let gridColumns = 6
    var displayPageSize: Int { expanded ? pageSize + gridColumns * 4 : pageSize }
    var onUpdate: (() -> Void)?
    var onCommit: ((String) -> Void)?
    private var revision = 0
    private var pending = false
    private var selecting = false
    private(set) var awaitingCandidates = false
    private var pendingRank = 0
    private var pendingLiteral = " "
    private var queued: [InputKey] = []
    private var timeout: DispatchWorkItem?
    private var doubleQuoteOpen = true
    private var singleQuoteOpen = true
    private var previousCharacter: Character?

    init(engine: EngineConnection, preferences: InputPreferences = InputPreferences()) {
        self.engine = engine
        self.preferences = preferences
        engine.onFailure = { [weak self] in self?.fallback() }
    }

    var preedit: String {
        raw + ((pending || selecting) ? pendingLiteral + queued.map(\.literal).joined() : "")
    }

    var visibleCandidates: [Candidate] {
        Array(candidates.dropFirst(page * displayPageSize).prefix(displayPageSize))
    }

    var selectedVisibleIndex: Int { selectedIndex - page * displayPageSize }

    // Numbers belong to the highlighted row, in page-local coordinates.
    // The first row may have a different width from the six-column grid.
    private var numberedRowStart: Int {
        guard expanded, selectedVisibleIndex >= pageSize else { return 0 }
        return pageSize + ((selectedVisibleIndex - pageSize) / gridColumns) * gridColumns
    }

    private var numberedRowCapacity: Int {
        expanded && selectedVisibleIndex >= pageSize ? gridColumns : pageSize
    }

    var numberedCandidateRange: Range<Int> {
        let start = numberedRowStart
        return start..<max(start, min(start + numberedRowCapacity, visibleCandidates.count))
    }

    func toggleExpanded() {
        guard !raw.isEmpty, !candidates.isEmpty else { return }
        expanded.toggle()
        page = selectedIndex / displayPageSize
        onUpdate?()
    }

    @discardableResult
    func handle(_ key: InputKey) -> Bool {
        if pending || selecting {
            switch key {
            case .escape: reset(); return true
            case .arrow, .page: return true
            case .shortcut: fallback(); return false
            case .enter: fallback(); return false
            case .backspace:
                if !queued.isEmpty {
                    queued.removeLast()
                } else if selecting {
                    queued.append(key)
                } else if !raw.isEmpty {
                    raw.removeLast()
                    if raw.isEmpty { reset() } else { replay() }
                }
                onUpdate?()
                return true
            default:
                if queued.count >= 256 { fallback(); return handle(key) }
                queued.append(key)
                onUpdate?()
                return true
            }
        }
        switch key {
        case .text(let text):
            if !raw.isEmpty, text.count == 1, let number = Int(text) {
                let index = number == 0 ? 9 : number - 1
                if (0..<numberedRowCapacity).contains(index) {
                    let target = numberedRowStart + index
                    // During refresh, defer the key until its current candidates
                    // arrive. An empty cell on a short final row is a no-op.
                    if awaitingCandidates || candidates.isEmpty || numberedCandidateRange.contains(target) {
                        selectVisible(target, literal: text)
                    }
                    return true
                }
            }
            let letters = !text.isEmpty && text.utf8.allSatisfy { (97...122).contains($0) }
            if letters || (text == "'" && !raw.isEmpty) {
                raw += text
                request(text)
                onUpdate?()
                return true
            }
            if !raw.isEmpty {
                selectVisible(selectedVisibleIndex, literal: "")
                if pending || selecting { queued.append(key) } else { _ = handle(key) }
                onUpdate?()
                return true
            }
            if text.count == 1 { commit(punctuation(text)); return true }
            return false
        case .space:
            guard !raw.isEmpty else { return false }
            selectVisible(selectedVisibleIndex, literal: " ")
            return true
        case .backspace:
            guard !raw.isEmpty else { return false }
            raw.removeLast()
            if raw.isEmpty { reset() } else { replay(); onUpdate?() }
            return true
        case .escape:
            guard !raw.isEmpty else { return false }
            if expanded { toggleExpanded(); return true }
            reset()
            return true
        case .enter:
            guard !raw.isEmpty else { return false }
            if expanded { selectVisible(selectedVisibleIndex); return true }
            let text = raw
            reset()
            commit(text)
            return true
        case .page(let delta):
            guard !raw.isEmpty else { return false }
            guard !awaitingCandidates else { return true }
            page = min(max(0, page + delta), max(0, (candidates.count - 1) / displayPageSize))
            selectedIndex = page * displayPageSize
            onUpdate?()
            return true
        case .arrow(let horizontal, let vertical):
            guard !raw.isEmpty else { return false }
            guard !candidates.isEmpty, !awaitingCandidates else { return true }
            if !expanded && vertical > 0 { toggleExpanded(); return true }
            if !expanded && vertical < 0 { return true }
            let local = selectedVisibleIndex
            var target = selectedIndex + horizontal
            if expanded && vertical != 0 {
                if vertical > 0 {
                    if local < pageSize { target = page * displayPageSize + pageSize + min(local, gridColumns - 1) }
                    else if local + gridColumns >= displayPageSize { target = (page + 1) * displayPageSize + min((local - pageSize) % gridColumns, pageSize - 1) }
                    else { target = selectedIndex + gridColumns }
                } else if local < pageSize {
                    if page == 0 { toggleExpanded(); return true }
                    target = (page - 1) * displayPageSize + pageSize + gridColumns * 3 + min(local, gridColumns - 1)
                } else if local < pageSize + gridColumns {
                    target = page * displayPageSize + min(local - pageSize, pageSize - 1)
                } else { target = selectedIndex - gridColumns }
            }
            selectedIndex = min(max(0, target), candidates.count - 1)
            page = selectedIndex / displayPageSize
            onUpdate?()
            return true
        case .shortcut:
            if !raw.isEmpty { let text = raw; reset(); commit(text) }
            return false
        }
    }

    func selectVisible(_ index: Int, literal: String = "") {
        guard !raw.isEmpty, !pending, !selecting else { return }
        guard (0..<displayPageSize).contains(index) else { return }
        pendingRank = page * displayPageSize + index
        pendingLiteral = literal
        if awaitingCandidates {
            pending = true
            armTimeout()
            onUpdate?()
        } else if candidates.indices.contains(pendingRank) {
            select(pendingRank)
        } else if candidates.isEmpty {
            pending = true
            if awaitingCandidates { armTimeout(); onUpdate?() }
            else { fallback() }
        }
    }

    private func request(_ keys: String) {
        revision += 1
        awaitingCandidates = true
        page = 0
        selectedIndex = 0
        expanded = false
        let expected = revision
        engine.send("B " + keys) { [weak self] line in
            guard let self, self.revision == expected, !self.raw.isEmpty else { return }
            if line == "SKIP" { return }
            self.awaitingCandidates = false
            if let words = Candidate.parse(line), words.allSatisfy({ $0.cover <= self.raw.count }) {
                self.candidates = words
                if self.pending {
                    let rank = self.pendingRank
                    self.pending = false
                    if words.indices.contains(rank) { self.select(rank) } else { self.fallback() }
                }
            } else {
                self.candidates = []
                if self.pending { self.fallback() }
            }
            self.onUpdate?()
        }
    }

    private func replay() {
        revision += 1
        engine.send("C") { _ in }
        request(raw)
    }

    private func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        let word = candidates[index]
        guard word.cover <= raw.count else { fallback(); return }
        selecting = true
        pending = false
        revision += 1
        let expected = revision
        armTimeout()
        engine.send("S \(index)") { [weak self] line in
            guard let self, self.revision == expected, self.selecting else { return }
            let rest = String(self.raw.dropFirst(word.cover))
            let words = Candidate.parse(line)
            guard (rest.isEmpty && line == "OK") ||
                    (!rest.isEmpty && (line == "EMPTY" ||
                        (words != nil && words!.allSatisfy { $0.cover <= rest.count }))) else {
                self.fallback()
                return
            }
            self.timeout?.cancel()
            self.selecting = false
            self.raw = rest
            self.candidates = words ?? []
            self.page = 0
            self.selectedIndex = 0
            self.expanded = false
            self.pendingLiteral = ""
            // Mark the remaining composition only after the selected prefix is
            // committed, so the client's replacement range still spans the old one.
            self.commit(word.text)
            if rest.isEmpty { self.engine.send("C") { _ in } }
            let replay = self.queued
            self.queued = []
            self.onUpdate?()
            for key in replay {
                if !self.handle(key), !key.literal.isEmpty { self.commit(key.literal) }
            }
        }
        onUpdate?()
    }

    private func armTimeout() {
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.fallback() }
        timeout = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    func fallback() {
        let text = preedit
        guard !text.isEmpty else { return }
        reset()
        if !text.isEmpty { commit(text) }
    }

    func reset() {
        revision += 1
        timeout?.cancel()
        timeout = nil
        raw = ""
        candidates = []
        page = 0
        selectedIndex = 0
        expanded = false
        pending = false
        selecting = false
        awaitingCandidates = false
        queued = []
        pendingLiteral = ""
        engine.send("C") { _ in }
        onUpdate?()
    }

    func close() {
        fallback()
        engine.stop()
    }

    private func commit(_ text: String) {
        previousCharacter = text.last ?? previousCharacter
        onCommit?(text)
    }

    private func punctuation(_ text: String) -> String {
        guard preferences.fullwidthPunctuation else { return text }
        if (text == "." || text == ","), previousCharacter?.isNumber == true { return text }
        if text == "\"" {
            defer { doubleQuoteOpen.toggle() }
            return doubleQuoteOpen ? "“" : "”"
        }
        if text == "'" {
            defer { singleQuoteOpen.toggle() }
            return singleQuoteOpen ? "‘" : "’"
        }
        let map = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
                   "\\": "、", "(": "（", ")": "）", "[": "【", "]": "】", "<": "《", ">": "》"]
        if let value = map[text] { return value }
        if let value = text.unicodeScalars.first, text != "`", (33...126).contains(value.value),
           !(48...57).contains(value.value), !(65...90).contains(value.value) {
            return String(UnicodeScalar(value.value + 0xfee0)!)
        }
        return text
    }
}

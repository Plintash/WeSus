import Foundation

struct InputPreferences: Equatable {
    var scheme = "flypy"
    var pageSize = 5
    var maxCandidates = 72
    var fullwidthPunctuation = true
    var showGlossary = false

    init() {}
    init(defaults: UserDefaults) {
        scheme = defaults.string(forKey: "scheme") == "full" ? "full" : "flypy"
        if defaults.object(forKey: "pageSize") != nil { pageSize = min(10, max(1, defaults.integer(forKey: "pageSize"))) }
        if defaults.object(forKey: "maxCandidates") != nil { maxCandidates = min(72, max(10, defaults.integer(forKey: "maxCandidates"))) }
        if defaults.object(forKey: "fullwidthPunctuation") != nil { fullwidthPunctuation = defaults.bool(forKey: "fullwidthPunctuation") }
        showGlossary = defaults.bool(forKey: "showGlossary")
    }

    func save(to defaults: UserDefaults) {
        defaults.set(scheme, forKey: "scheme")
        defaults.set(pageSize, forKey: "pageSize")
        defaults.set(maxCandidates, forKey: "maxCandidates")
        defaults.set(fullwidthPunctuation, forKey: "fullwidthPunctuation")
        defaults.set(showGlossary, forKey: "showGlossary")
    }
}

struct Glossary {
    let entries: [String: String]
    init(_ text: String) {
        let prefixes = ["n. ", "v. ", "a. ", "adj. ", "adv. ", "pron. ", "prep. ", "conj. ",
                        "int. ", "num. ", "art. ", "det. ", "aux. ", "vt. ", "vi. ", "interj. "]
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty else { continue }
            var gloss = String(fields[1])
            if let prefix = prefixes.first(where: { gloss.hasPrefix($0) }) { gloss.removeFirst(prefix.count) }
            if !gloss.isEmpty { result[String(fields[0])] = gloss }
        }
        entries = result
    }
}

final class PreferencesStore {
    static let shared = PreferencesStore()
    static let didChange = Notification.Name("WeTypePreferencesDidChange")
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeTypeIME")
    static let glossaryURL = directory.appendingPathComponent("glossary-en.tsv")
    private let defaults: UserDefaults = {
        let identifier = "io.github.plintash.inputmethod.wetype"
        // Foundation rejects adding an application's own domain as a suite.
        if Bundle.main.bundleIdentifier == identifier { return .standard }
        return UserDefaults(suiteName: identifier)!
    }()
    private(set) var glossary = Glossary("")
    var current: InputPreferences { InputPreferences(defaults: defaults) }

    private init() { reloadGlossary() }
    func save(_ preferences: InputPreferences) {
        preferences.save(to: defaults)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    func reloadGlossary() {
        glossary = Glossary((try? String(contentsOf: Self.glossaryURL, encoding: .utf8)) ?? "")
    }
}

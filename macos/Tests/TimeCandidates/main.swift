import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

func waitFor(_ message: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    try check(condition(), message)
}

func settle(_ model: Composition) throws {
    try waitFor("Timed out waiting for candidates") { !model.awaitingCandidates }
}

func run(scheme: String) throws {
    let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let executable = CommandLine.arguments.count > 2
        ? URL(fileURLWithPath: CommandLine.arguments[2])
        : base.appendingPathComponent("build/macos/WeTypeNativeEngine")
    let work = base.appendingPathComponent(".deps/time-candidates-test.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let engine = ProcessEngine(command: EngineCommand(
        executable: executable,
        arguments: [base.appendingPathComponent(".deps/mac-engine/WeType.app").path, work.path, scheme]))
    let model = Composition(engine: engine)
    var commits: [String] = []
    model.onCommit = { commits.append($0) }
    defer {
        engine.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    let timeKeys = scheme == "flypy" ? "uijm" : "shijian"
    let timePrefix = scheme == "flypy" ? "uij" : "shij"
    for key in timeKeys {
        model.handle(.text(String(key)))
        try settle(model)
        try check(!model.candidates.isEmpty, "No frontend candidates for \(model.raw)")
        if model.raw == timePrefix || model.raw == timeKeys {
            try check(model.candidates.contains(where: { $0.text == "时间" }),
                      "Missing 时间 for \(model.raw)")
        }
    }
    model.handle(.space)
    try waitFor("Ordinary 时间 selection failed") { commits == ["时间"] && model.raw.isEmpty }
    print("PASS \(scheme) incremental \(timeKeys) candidates and 时间 commit")

    for keys in [timePrefix, timeKeys, "riqi"] {
        model.handle(.text(keys))
        try settle(model)
        let pattern = keys == "riqi" ? #"^\d{1,2}月\d{1,2}日$"# : #"^\d{2}:\d{2}$"#
        guard let rank = model.candidates.firstIndex(where: { $0.text.range(of: pattern, options: .regularExpression) != nil }) else {
            throw TestFailure(description: "Missing generated date/time candidate for \(scheme) \(keys)")
        }
        let chosen = model.candidates[rank]
        try check(chosen.cover == keys.count, "Generated candidate must cover the current physical keys")
        let previous = commits.count
        model.selectVisible(rank)
        try waitFor("Generated candidate did not commit: \(keys)") { commits.count > previous }
        try check(commits.last == chosen.text && model.raw.isEmpty,
                  "Generated selection must commit its text and clear composition")
    }
    print("PASS \(scheme) generated time/date coverage and selection")

    // A partial selection must still consume only its own physical keys.
    let helloKeys = scheme == "flypy" ? "nihc" : "nihao"
    model.handle(.text(helloKeys + timeKeys))
    try settle(model)
    guard let helloRank = model.candidates.firstIndex(where: { $0.text == "你好" && $0.cover == helloKeys.count }) else {
        throw TestFailure(description: "Missing partial 你好 candidate")
    }
    let previous = commits.count
    model.selectVisible(helloRank)
    try waitFor("Partial selection did not commit") { commits.count > previous }
    try check(commits.last == "你好" && model.raw == timeKeys && model.candidates.first?.text == "时间",
              "Partial selection must preserve the remaining 时间 candidates")
    model.handle(.space)
    try waitFor("Remaining 时间 did not commit") { model.raw.isEmpty }
    try check(commits.last == "时间", "Remaining candidate selection failed")
    print("PASS \(scheme) partial selection followed by 时间")
}

do {
    try run(scheme: "flypy")
    try run(scheme: "full")
}
catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}

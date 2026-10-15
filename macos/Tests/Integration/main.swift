import Foundation

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let work = base.appendingPathComponent(".deps/native-frontend-test.\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }
let command = EngineCommand(executable: base.appendingPathComponent("build/macos/WeTypeNativeEngine"),
                            arguments: [base.appendingPathComponent(".deps/mac-engine/WeType.app").path,
                                        work.path, "flypy"])
let engine = ProcessEngine(command: command)
let model = Composition(engine: engine)
var commits: [String] = []
var finished = false
var selectedSecond = false
model.onCommit = { text in
    commits.append(text)
    if commits == ["你好", "中国"] {
        model.close()
        finished = true
    } else if commits.count > 1 || commits[0] != "你好" {
        fatalError("Unexpected native commit: \(commits)")
    }
}
model.onUpdate = {
    if commits == ["你好"] && model.raw == "vsgo" && !model.candidates.isEmpty && !selectedSecond {
        selectedSecond = true
        model.handle(.space)
    }
}
// Type ahead before the helper has even reached READY. Space must wait for
// the correct physical-key sequence, then replay the next word without losing it.
for key in "nihc" { model.handle(.text(String(key))) }
model.handle(.space)
for key in "vsgo" { model.handle(.text(String(key))) }
let deadline = Date().addingTimeInterval(15)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
guard finished else { fatalError("Native frontend timed out: \(commits), preedit=\(model.preedit)") }
print("PASS native process startup, real candidates, pending Space, type ahead and selection")
// Allow orderly Q/finalize before removing the isolated dictionary.
RunLoop.main.run(until: Date().addingTimeInterval(0.5))

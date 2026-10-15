import Foundation
import Darwin

// The frontend speaks the same line protocol regardless of the helper's runtime.
// Only this launch description changes between the Linux reference engine and
// the native macOS helper. Nothing about OrbStack belongs in composition logic.
struct EngineCommand {
    let executable: URL
    let arguments: [String]

    static func load() throws -> EngineCommand {
        guard let path = Bundle.main.url(forResource: "EngineCommand", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: path),
              let executable = dictionary["Executable"] as? String,
              let arguments = dictionary["Arguments"] as? [String] else {
            throw NSError(domain: "WeTypeIME", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "引擎尚未配置，请重新构建应用。"])
        }
        let resolved = executable.replacingOccurrences(of: "$BUNDLE", with: Bundle.main.bundlePath)
        var configured = arguments
        if URL(fileURLWithPath: resolved).lastPathComponent == "WeTypeNativeEngine", configured.count == 3 {
            configured[2] = PreferencesStore.shared.current.scheme
        }
        return EngineCommand(executable: URL(fileURLWithPath: resolved), arguments: configured)
    }
}

final class ProcessEngine: EngineConnection {
    var onFailure: (() -> Void)?
    var onStatus: ((String) -> Void)?
    private let command: EngineCommand
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var log: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var failed = false
    private var waiting: [(String, (String) -> Void)] = []
    private var handlers: [(String) -> Void] = []
    private var watchdog: DispatchWorkItem?

    init(command: EngineCommand) { self.command = command }

    func send(_ command: String, reply: @escaping (String) -> Void) {
        guard !failed else { return }
        if process == nil { start() }
        guard !failed else { return }
        if ready { write(command, reply: reply) } else { waiting.append((command, reply)) }
    }

    private func start() {
        onStatus?("正在连接引擎…")
        let task = Process()
        let stdin = Pipe(), stdout = Pipe()
        task.executableURL = command.executable
        task.arguments = command.arguments
        task.environment = ProcessInfo.processInfo.environment.merging(
            ["WETYPE_MAX_CAND": String(PreferencesStore.shared.current.maxCandidates)]) { _, new in new }
        task.standardInput = stdin
        task.standardOutput = stdout
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/WeTypeIME", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("engine.log")
            // Keep developer diagnostics bounded across repeated startups.
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
               (attributes[.size] as? NSNumber)?.intValue ?? 0 > 16 * 1024 * 1024 {
                let previous = directory.appendingPathComponent("engine.log.1")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: path, to: previous)
            }
            if !FileManager.default.fileExists(atPath: path.path) {
                FileManager.default.createFile(atPath: path.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600])
            }
            log = try FileHandle(forWritingTo: path)
            try log?.seekToEnd()
            task.standardError = log
            process = task
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            task.terminationHandler = { [weak self] task in
                DispatchQueue.main.async {
                    guard self?.process === task else { return }
                    self?.fail("引擎连接已断开")
                }
            }
            output?.readabilityHandler = { [weak self, weak task] handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    guard let self, self.process === task else { return }
                    if data.isEmpty { self.fail("引擎连接已断开") } else { self.receive(data) }
                }
            }
            try task.run()
            armWatchdog(seconds: 30)
        } catch {
            fail("无法连接引擎：\(error.localizedDescription)")
        }
    }

    private func write(_ command: String, reply: @escaping (String) -> Void) {
        do {
            handlers.append(reply)
            try input?.write(contentsOf: Data((command + "\n").utf8))
            if handlers.count == 1 { armWatchdog(seconds: 10) }
        } catch { fail("引擎连接已断开") }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1024 * 1024 else { fail("引擎返回了异常数据"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let bytes = buffer.prefix(upTo: newline)
            guard let line = String(data: bytes, encoding: .utf8) else {
                fail("引擎返回了异常数据"); return
            }
            buffer.removeSubrange(...newline)
            if !ready {
                guard line == "READY" else { continue }
                ready = true
                watchdog?.cancel()
                // Coverage is always physical key count, including in Flypy mode.
                write("OPT spans") { [weak self] line in
                    if line != "OK" { self?.fail("引擎协议不兼容") }
                }
                let commands = waiting
                waiting = []
                for (command, reply) in commands { write(command, reply: reply) }
                onStatus?("小鹤双拼 · 已连接")
            } else {
                guard !handlers.isEmpty else { fail("引擎协议不兼容"); return }
                let callback = handlers.removeFirst()
                watchdog?.cancel()
                if !handlers.isEmpty { armWatchdog(seconds: 10) }
                callback(line)
            }
        }
    }

    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.fail("引擎响应超时") }
        watchdog = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        stop()
        onStatus?(message)
        onFailure?()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        output?.readabilityHandler = nil
        if ready { try? input?.write(contentsOf: Data("Q\n".utf8)) }
        try? input?.close()
        try? output?.close()
        try? log?.close()
        let task = process
        process = nil
        task?.terminationHandler = nil
        if let task, task.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if task.isRunning { task.terminate() }
            }
        }
        input = nil
        output = nil
        log = nil
        buffer = Data()
        ready = false
        waiting = []
        handlers = []
    }

    deinit { stop() }
}

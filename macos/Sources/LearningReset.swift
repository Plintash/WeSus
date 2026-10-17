import Foundation
import Darwin

struct LearningResetRequest {
    let pinyin: String
    let word: String
    var command: String { "FORGET\t\(pinyin)\t\(word)" }

    init(pinyin: String, word: String) throws {
        let syllables = pinyin.lowercased().split { $0.isWhitespace || $0 == "'" }
        let normalized = syllables.map(String.init).joined(separator: "'")
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 256,
              normalized.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || $0 == "'" }) else {
            throw LearningResetError("请填写不带声调的全拼，多字词用空格或 ' 分隔音节，例如 ni'hao。")
        }
        guard !text.isEmpty, text.utf8.count <= 512,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw LearningResetError("请填写一个要重置的字或词，不要包含空格或换行。")
        }
        self.pinyin = normalized
        self.word = text
    }
}

struct LearningResetError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LearnedWord: Codable, Equatable {
    let word: String
    let pinyin: String
    let count: Int
    let lastUsed: Double
    let heat: Double
    let historyHeat: Double
    let currentRank: Int
    var baseRank: Int

    var id: String { pinyin + "\t" + word }
    var lift: Int { baseRank > 0 && currentRank > 0 ? baseRank - currentRank : 0 }
    var isProminent: Bool { (1...5).contains(currentRank) && lift >= 5 }
    var reading: String { pinyin.replacingOccurrences(of: "'", with: " ") }
    var rankSummary: String {
        let before = baseRank > 0 ? "第 \(baseRank)" : "前 72 名外"
        let after = currentRank > 0 ? "第 \(currentRank)" : "前 72 名外"
        return before + " → " + after
    }

    static func matching(_ records: [LearnedWord], query: String) -> [LearnedWord] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func normalized(_ text: String) -> String { text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "") }
        let key = normalized(search)
        let hasWholeReading = !search.isEmpty && records.contains { normalized($0.pinyin) == key }
        let hasSyllable = !hasWholeReading && !search.isEmpty && records.contains { $0.pinyin.split(separator: "'").contains(Substring(key)) }
        return records.filter { entry in
            if search.isEmpty { return entry.isProminent }
            if entry.word.localizedCaseInsensitiveContains(search) { return true }
            if hasWholeReading { return normalized(entry.pinyin) == key }
            if hasSyllable { return entry.pinyin.split(separator: "'").contains(Substring(key)) }
            return normalized(entry.pinyin).hasPrefix(key)
        }.sorted { lhs, rhs in
            if !search.isEmpty {
                let leftExact = lhs.word == search || normalized(lhs.pinyin) == key
                let rightExact = rhs.word == search || normalized(rhs.pinyin) == key
                if leftExact != rightExact { return leftExact }
            }
            if lhs.lift != rhs.lift { return lhs.lift > rhs.lift }
            if lhs.heat != rhs.heat { return lhs.heat > rhs.heat }
            return lhs.id < rhs.id
        }
    }
}

enum LearningResetService {
    static func load(command: EngineCommand, completion: @escaping (Result<[LearnedWord], Error>) -> Void) {
        guard command.executable.lastPathComponent == "WeTypeNativeEngine", command.arguments.count == 3 else {
            completion(.failure(LearningResetError("当前引擎不支持查看学习记录。")))
            return
        }
        let source = URL(fileURLWithPath: command.arguments[1], isDirectory: true)
        let accepted = ProcessEngine.prepareLearningReset(dictionary: source) { saved in
            guard saved else {
                ProcessEngine.finishLearningReset()
                completion(.failure(LearningResetError("引擎未能正常保存数据，请稍后刷新。")))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("WeSus-Learning-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                var released = false
                let result = Result<[LearnedWord], Error> {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let snapshot = root.appendingPathComponent("Snapshot")
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: snapshot)
                    }
                    // Analysis runs on a private copy. Resume typing as soon as
                    // that copy is consistent, rather than blocking on ranking.
                    DispatchQueue.main.async { ProcessEngine.finishLearningReset() }
                    released = true
                    if !FileManager.default.fileExists(atPath: snapshot.path) { return [] }
                    var arguments = command.arguments
                    arguments[1] = snapshot.path
                    arguments[2] = "full"
                    let personal = EngineCommand(executable: command.executable, arguments: arguments)
                    let raw = try runHelper("LEARNING", command: personal)
                    var entries = try decode(raw, prefix: "LEARNED\t")
                    if entries.isEmpty { return [] }
                    // disable_user_dict does not remove all ranking effects in
                    // this vendor build. A genuinely fresh dictionary is needed.
                    arguments[1] = root.appendingPathComponent("Baseline").path
                    let baseline = EngineCommand(executable: command.executable, arguments: arguments)
                    let data = try JSONEncoder().encode(entries).base64EncodedString()
                    let ranked = try decode(runHelper("RANKS\t" + data, command: baseline), prefix: "RANKED\t")
                    let ranks = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0.currentRank) })
                    for index in entries.indices { entries[index].baseRank = ranks[entries[index].id] ?? 0 }
                    return entries
                }
                DispatchQueue.main.async {
                    if !released { ProcessEngine.finishLearningReset() }
                    completion(result)
                }
            }
        }
        if !accepted { completion(.failure(LearningResetError("请先完成或取消当前输入，再刷新学习记录。"))) }
    }

    private static func decode(_ response: String, prefix: String) throws -> [LearnedWord] {
        guard response.hasPrefix(prefix), let data = Data(base64Encoded: String(response.dropFirst(prefix.count))) else {
            throw LearningResetError("没有收到有效的学习记录，请重试。")
        }
        return try JSONDecoder().decode([LearnedWord].self, from: data)
    }

    static func reset(_ request: LearningResetRequest, command: EngineCommand,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        guard command.executable.lastPathComponent == "WeTypeNativeEngine", command.arguments.count == 3 else {
            completion(.failure(LearningResetError("当前引擎不支持单词学习重置，请使用原生 macOS 引擎。")))
            return
        }
        let dictionary = URL(fileURLWithPath: command.arguments[1], isDirectory: true)
        let accepted = ProcessEngine.prepareLearningReset(dictionary: dictionary) { saved in
            guard saved else {
                ProcessEngine.finishLearningReset()
                completion(.failure(LearningResetError("引擎未能正常保存学习数据，未执行重置，请稍后重试。")))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try perform(request, command: command, dictionary: dictionary) }
                DispatchQueue.main.async {
                    ProcessEngine.finishLearningReset()
                    completion(result)
                }
            }
        }
        if !accepted {
            completion(.failure(LearningResetError("请先完成或取消当前输入，等待候选返回后再重试。")))
        }
    }

    private static func perform(_ request: LearningResetRequest, command: EngineCommand, dictionary: URL) throws -> URL {
        let files = FileManager.default
        guard files.fileExists(atPath: dictionary.path) else {
            throw LearningResetError("还没有本地学习数据，无需重置。")
        }
        let backups = dictionary.deletingLastPathComponent().appendingPathComponent("LearningBackups", isDirectory: true)
        try files.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = backups.appendingPathComponent("\(stamp)-\(UUID().uuidString)", isDirectory: true)
        // All writer processes have exited, so the LevelDB snapshot is complete.
        try files.copyItem(at: dictionary, to: backup)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)

        do {
            guard try runHelper(request.command, command: command) == "OK" else {
                throw LearningResetError("引擎未能重置这条学习记录。")
            }
            return backup
        } catch {
            throw LearningResetError("未能确认重置结果：\(error.localizedDescription) 重置前备份保存在 \(backup.path)")
        }
    }

    private static func runHelper(_ request: String, command: EngineCommand) throws -> String {
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.standardInput = input
            process.standardOutput = output
            // Vendor diagnostics must not fill a second, unread pipe.
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                timeout.cancel()
                try? output.fileHandleForReading.close()
            }
            try input.fileHandleForWriting.write(contentsOf: Data((request + "\nQ\n").utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let replies = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init)
            guard process.terminationReason == .exit, process.terminationStatus == 0,
                  replies?.count == 3, replies?.first == "READY", replies?.last == "BYE" else {
                throw LearningResetError("未收到引擎保存完成的确认。")
            }
            return replies![1]
    }
}

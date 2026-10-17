// Native WeType 2.2.3 adapter. ABI offsets are recovered from the official
// executable's Swift reflection metadata; see docs/macos-native-engine.md.
// Vendor binaries and dictionaries are downloaded locally, never committed.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <csignal>
#include <cctype>
#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <map>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace fs = std::filesystem;
static thread_local std::vector<std::string> *learningLogs = nullptr;

template <size_t Size> struct Record {
    alignas(8) unsigned char data[Size]{};
    template <class T> void set(size_t offset, T value) {
        if (offset + sizeof(T) > Size) throw std::logic_error("ABI field out of bounds");
        std::memcpy(data + offset, &value, sizeof(T));
    }
};

template <class T> static T field(const void *record, size_t offset) {
    T result;
    std::memcpy(&result, static_cast<const char *>(record) + offset, sizeof(T));
    return result;
}

static std::string stringField(const void *record, size_t pointerOffset, size_t lengthOffset) {
    auto pointer = field<const char *>(record, pointerOffset);
    auto length = field<uint32_t>(record, lengthOffset);
    if (length > 65536 || (length && !pointer)) throw std::runtime_error("invalid candidate string");
    return pointer ? std::string(pointer, length) : std::string();
}

struct DictionaryItem {
    const void *fd;
    const char *path;
    uint32_t id, version;
};
static_assert(sizeof(DictionaryItem) == 24);
struct DictionaryConfig {
    DictionaryItem *items;
    uint32_t count;
    const char *userDirectory;
    bool safeMode;
};
static_assert(sizeof(DictionaryConfig) == 32);

struct Candidate { std::string text, id; uint32_t cover; };

struct API {
    const char *(*version)();
    void (*initialize)(void *);
    bool (*configDictionary)(void *);
    uint64_t (*createSession)(void *);
    void (*addListener)(uint64_t, void *, void *);
    bool (*processInput)(uint64_t, const char *, uint32_t, const void *, uint32_t);
    bool (*nextCandidate)(uint64_t, void *);
    void (*deleteIterator)(uint64_t);
    void (*resetSession)(uint64_t);
    void (*destroySession)(uint64_t);
    bool (*selectCandidate)(uint64_t, const char *, uint32_t, const char *, uint32_t,
                            const char *, uint32_t, const char *, uint32_t,
                            void *, uint32_t, const void *);
    void (*finalize)();
    bool (*loadAndExecute)(const char *);

    explicit API(void *handle) {
#define LOAD(member, symbol) \
        member = reinterpret_cast<decltype(member)>(dlsym(handle, symbol)); \
        if (!member) throw std::runtime_error("missing engine symbol: " symbol);
        LOAD(version, "wxime_get_version")
        LOAD(initialize, "wxime_initialize")
        LOAD(configDictionary, "wxime_config_dict")
        LOAD(createSession, "wxime_create_session")
        LOAD(addListener, "wxime_add_session_listener")
        LOAD(processInput, "wxime_process_input")
        LOAD(nextCandidate, "wxime_candidate_next")
        LOAD(deleteIterator, "wxime_delete_candidate_iterator")
        LOAD(resetSession, "wxime_reset_session")
        LOAD(destroySession, "wxime_destroy_session")
        LOAD(selectCandidate, "wxime_select_candidate")
        LOAD(finalize, "wxime_finalize")
        LOAD(loadAndExecute, "wxime_load_and_execute")
#undef LOAD
        if (std::strcmp(version(), "0.45.0.weekly_release/2026.08.05.b95d82518"))
            throw std::runtime_error("unsupported engine version; prepare the pinned WeType 2.2.3 package");
    }
};

class Engine {
    API api;
    std::vector<std::string> dictionaryPaths;
    std::vector<DictionaryItem> dictionaryItems;
    std::string workDirectory;
    Record<208> config;
    Record<312> sessionConfig;
    uint64_t session = 0;
    bool initialized = false;
    std::mutex eventMutex;
    std::vector<uint64_t> iterators;

    static void logger(int level, const char *message) {
        if (learningLogs && message) { learningLogs->emplace_back(message); return; }
        if (level >= 3 && message) std::fprintf(stderr, "[native-engine] %s\n", message);
    }

    static void listener(uint64_t session, int *types, void **data, unsigned count, void *context) {
        auto &engine = *static_cast<Engine *>(context);
        std::lock_guard<std::mutex> lock(engine.eventMutex);
        if (session != engine.session) return;
        for (unsigned i = 0; i < count; i++) {
            if (types[i] != 0 || !data[i]) continue;
            // event 0: local iterator, cloud iterator. Cloud options are disabled.
            for (size_t offset : {size_t(0), size_t(8)}) {
                uint64_t iterator = field<uint64_t>(data[i], offset);
                if (iterator) engine.iterators.push_back(iterator);
            }
        }
    }

    std::vector<uint64_t> takeIterators() {
        std::lock_guard<std::mutex> lock(eventMutex);
        std::vector<uint64_t> result;
        result.swap(iterators);
        return result;
    }

    void deleteIterators(const std::vector<uint64_t> &values) {
        std::unordered_set<uint64_t> seen;
        for (auto value : values) if (seen.insert(value).second) api.deleteIterator(value);
    }

    void loadDictionaries(const fs::path &root) {
        NSData *data = [NSData dataWithContentsOfFile:@((root / "index.json").c_str())];
        NSError *error = nil;
        id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![manifest isKindOfClass:[NSArray class]]) throw std::runtime_error("invalid native dictionary index");
        for (id entry in static_cast<NSArray *>(manifest)) {
            if (![entry isKindOfClass:[NSDictionary class]]) throw std::runtime_error("invalid dictionary entry");
            // The desktop client configures the ordinary and base dictionaries.
            int type = [entry[@"dict_type"] intValue];
            if (type != 0 && type != 6) continue;
            NSString *name = entry[@"name"];
            if (![name isKindOfClass:[NSString class]]) throw std::runtime_error("missing dictionary filename");
            fs::path relative(name.UTF8String);
            if (relative.is_absolute() || relative.has_parent_path()) throw std::runtime_error("invalid dictionary filename");
            auto path = root / relative;
            if (!fs::is_regular_file(path)) throw std::runtime_error("missing native dictionary: " + path.string());
            dictionaryPaths.push_back(path.string());
            dictionaryItems.push_back({nullptr, nullptr, [entry[@"type"] unsignedIntValue], [entry[@"version"] unsignedIntValue]});
        }
        if (dictionaryItems.empty()) throw std::runtime_error("empty dictionary index");
        for (size_t i = 0; i < dictionaryItems.size(); i++) dictionaryItems[i].path = dictionaryPaths[i].c_str();
    }

public:
    Engine(void *handle, const fs::path &bundle, const fs::path &work, int scheme)
        : api(handle), workDirectory(work.string()) {
        loadDictionaries(bundle / "Contents/Resources/imeData.bundle");
        fs::create_directories(work / "userdict/v5");
        fs::create_directories(work / "userdict/user_hot_word");
        config.set(0, &logger);
        config.set<uint8_t>(8, 1); // log_without_time
        config.set(24, workDirectory.c_str());
        config.set(64, "10000001");
        config.set<uint32_t>(72, 8);
        config.set<uint32_t>(76, 3); // warnings/errors only
        config.set<uint32_t>(80, 5); // macOS
        config.set(88, "2.2.3"); config.set<uint32_t>(96, 5);
        config.set(104, "Mac"); config.set<uint32_t>(112, 3);
        config.set(120, "macOS"); config.set<uint32_t>(128, 5);
        config.set<uint32_t>(192, 3); // official Mac package type
        // Synchronous callbacks stay inside this helper, never on the UI thread.
        sessionConfig.set<uint8_t>(1, 1); // search immediately after each input
        sessionConfig.set<uint32_t>(4, 0); // QWERTY pinyin
        for (size_t offset : {size_t(9), size_t(10), size_t(11), size_t(12)})
            sessionConfig.set<uint8_t>(offset, 1); // local correction options
        sessionConfig.set<uint32_t>(32, scheme); // double_pin_solution: 3=Flypy
        sessionConfig.set<uint8_t>(47, 1); // normal text candidates
        sessionConfig.set<uint8_t>(174, 1); // local correction
        // enable_pre_input requires an auxiliary protobuf from the official
        // frontend. Leave it disabled for our direct single-rune C API calls.
        // Cloud/network/login fields remain zero and no network APIs are invoked.
        api.initialize(config.data);
        initialized = true;
        DictionaryConfig dictionaries{dictionaryItems.data(), static_cast<uint32_t>(dictionaryItems.size()),
                                       workDirectory.c_str(), false};
        if (!api.configDictionary(&dictionaries)) throw std::runtime_error("native dictionary configuration failed");
        session = api.createSession(sessionConfig.data);
        if (!session) throw std::runtime_error("native session creation failed");
        api.addListener(session, reinterpret_cast<void *>(&listener), this);
    }

    void discardIterators() { deleteIterators(takeIterators()); }

    std::vector<Candidate> candidates(size_t inputLength, int requestedLimit = 0) {
        auto values = takeIterators();
        std::vector<Candidate> result;
        try {
            if (!values.empty()) {
                Record<112> candidate;
                int limit = 72;
                if (requestedLimit) limit = requestedLimit;
                else if (const char *value = std::getenv("WETYPE_MAX_CAND")) {
                    try { limit = std::clamp(std::stoi(value), 10, 72); } catch (...) {}
                }
                for (int i = 0; i < limit && api.nextCandidate(values.back(), candidate.data); i++) {
                    // These pointers are borrowed and change at the NEXT call.
                    uint32_t cover = field<uint32_t>(candidate.data, 100);
                    // Generated date/time candidates use -1 (UINT32_MAX) for
                    // the whole composition. The line protocol and selection
                    // bookkeeping both require a physical key count.
                    if (cover == UINT32_MAX) cover = static_cast<uint32_t>(inputLength);
                    result.push_back({stringField(candidate.data, 0, 8), stringField(candidate.data, 32, 40),
                                      cover});
                }
            }
        } catch (...) { deleteIterators(values); throw; }
        deleteIterators(values);
        return result;
    }

    bool input(char key) {
        discardIterators();
        // The API expects one UTF-8 rune per call. Whole strings trigger a vendor assertion.
        return api.processInput(session, &key, 1, nullptr, 0);
    }

    bool select(const Candidate &candidate) {
        discardIterators();
        return api.selectCandidate(session, candidate.text.data(), static_cast<uint32_t>(candidate.text.size()),
                                   candidate.id.data(), static_cast<uint32_t>(candidate.id.size()),
                                   nullptr, 0, nullptr, 0, nullptr, 0, nullptr);
    }

    void reset() { discardIterators(); api.resetSession(session); discardIterators(); }

    bool localCommand(NSDictionary *command) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:command options:0 error:nullptr];
        if (!json) return false;
        std::string pattern = (fs::path(workDirectory) / ".maintenance.XXXXXX").string();
        std::vector<char> path(pattern.begin(), pattern.end());
        path.push_back(0);
        int fd = mkstemp(path.data()); // private, unique file; no user-supplied path
        if (fd < 0) return false;
        FILE *file = fdopen(fd, "wb");
        bool written = false;
        if (file) {
            written = std::fwrite(json.bytes, 1, json.length, file) == json.length;
            if (std::fclose(file)) written = false;
        } else { close(fd); }
        bool success = written && api.loadAndExecute(path.data());
        unlink(path.data());
        return success;
    }

    bool forget(const std::string &pinyin, const std::string &word) {
        std::string syllables = pinyin;
        std::replace(syllables.begin(), syllables.end(), '\'', ',');
        bool success = localCommand(@{@"commands": @[@{@"type": @"remove_user_dict_item",
            @"value": @[@{@"syllable": @(syllables.c_str()), @"word": @(word.c_str())}]}]});
        reset();
        return success;
    }

    std::vector<std::string> capture(NSDictionary *command) {
        std::vector<std::string> messages;
        learningLogs = &messages;
        bool success = false;
        try { success = localCommand(command); }
        catch (...) { learningLogs = nullptr; throw; }
        learningLogs = nullptr;
        if (!success) throw std::runtime_error("could not inspect learned words");
        return messages;
    }

    NSData *learnedWords() {
        // These version-pinned diagnostic commands are read-only. Capture only
        // their C logger callback; the maintenance subprocess discards stderr.
        auto scan = capture(@{@"commands": @[@{@"type": @"scan_user_dict_syllables"}]});
        std::unordered_set<std::string> seen;
        NSMutableArray *syllables = [NSMutableArray array];
        for (const auto &line : scan) {
            auto marker = line.find("syllables:");
            if (marker == std::string::npos) continue;
            std::string keys = line.substr(marker + 10);
            size_t start = 0;
            while (start < keys.size()) {
                size_t end = keys.find('$', start);
                std::string key = keys.substr(start, end == std::string::npos ? end : end - start);
                while (!key.empty() && std::isspace(static_cast<unsigned char>(key.back()))) key.pop_back();
                bool valid = !key.empty() && key.size() <= 256;
                for (char c : key) if (!((c >= 'a' && c <= 'z') || c == ',')) valid = false;
                if (valid && seen.insert(key).second) [syllables addObject:@(key.c_str())];
                if (end == std::string::npos) break;
                start = end + 1;
            }
        }
        auto detail = capture(@{@"commands": @[@{@"type": @"lookup_user_dict_syllables", @"value": syllables}]});
        struct Entry { std::string word, pinyin; int count; double time, heat, history; int current = 0, base = 0; };
        std::map<std::string, Entry> entries;
        std::string current;
        for (const auto &line : detail) {
            auto lookup = line.find("LookUp:");
            if (lookup != std::string::npos) {
                current = line.substr(lookup + 7);
                while (!current.empty() && std::isspace(static_cast<unsigned char>(current.back()))) current.pop_back();
            }
            auto word = line.find("word:");
            auto count = line.rfind(", count:");
            auto time = line.rfind(", time:");
            auto heat = line.rfind(", hot val:");
            auto history = line.rfind(", spur_history_hot_val:");
            if (word == std::string::npos || count == std::string::npos || time == std::string::npos ||
                heat == std::string::npos || history == std::string::npos || !seen.count(current)) continue;
            try {
                Entry entry{line.substr(word + 5, count - word - 5), current, std::stoi(line.substr(count + 8)),
                    std::stod(line.substr(time + 7)), std::stod(line.substr(heat + 10)), std::stod(line.substr(history + 23))};
                if (entry.count <= 0 || entry.word.empty()) continue;
                auto key = current + '\t' + entry.word;
                auto found = entries.find(key);
                if (found == entries.end() || entry.time >= found->second.time) entries[key] = entry;
            } catch (const std::exception &) { throw std::runtime_error("unsupported learned-word diagnostic format"); }
        }

        NSMutableArray *result = [NSMutableArray array];
        for (auto &[key, entry] : entries) {
            std::replace(entry.pinyin.begin(), entry.pinyin.end(), ',', '\'');
            [result addObject:@{@"word": @(entry.word.c_str()), @"pinyin": @(entry.pinyin.c_str()),
                @"count": @(entry.count), @"lastUsed": @(entry.time), @"heat": @(entry.heat),
                @"historyHeat": @(entry.history), @"currentRank": @(entry.current), @"baseRank": @(entry.base)}];
        }
        return rankWords(result);
    }

    NSData *rankWords(NSArray *records) {
        if (records.count > 20000) throw std::runtime_error("too many learned words");
        NSMutableArray *result = [NSMutableArray array];
        std::map<std::string, std::vector<NSMutableDictionary *>> groups;
        for (id record in records) {
            if (![record isKindOfClass:[NSDictionary class]]) throw std::runtime_error("invalid learned word");
            NSString *pinyin = record[@"pinyin"], *word = record[@"word"];
            if (![pinyin isKindOfClass:[NSString class]] || ![word isKindOfClass:[NSString class]] ||
                !pinyin.length || pinyin.length > 256 || !word.length || word.length > 256)
                throw std::runtime_error("invalid learned word");
            std::string keys(pinyin.UTF8String);
            for (char c : keys) if (!((c >= 'a' && c <= 'z') || c == '\''))
                throw std::runtime_error("invalid learned-word reading");
            NSMutableDictionary *entry = [record mutableCopy];
            entry[@"currentRank"] = @0;
            [result addObject:entry];
            groups[keys].push_back(entry);
        }
        uint64_t original = session, querySession = 0;
        auto cleanup = [&] {
            discardIterators();
            if (querySession) { session = querySession; api.destroySession(querySession); discardIterators(); }
            session = original;
        };
        try {
            Record<312> options = sessionConfig;
            options.set<uint32_t>(32, 0);
            querySession = api.createSession(options.data);
            if (!querySession) throw std::runtime_error("could not inspect learned-word ranks");
            session = querySession;
            api.addListener(session, reinterpret_cast<void *>(&listener), this);
            for (auto &[keys, words] : groups) {
                reset();
                bool valid = true;
                for (char key : keys) if (!input(key)) { valid = false; break; }
                auto matches = valid ? candidates(keys.size(), 72) : std::vector<Candidate>();
                for (NSMutableDictionary *entry : words) {
                    std::string word([entry[@"word"] UTF8String]);
                    auto match = std::find_if(matches.begin(), matches.end(), [&](const auto &candidate) { return candidate.text == word; });
                    if (match != matches.end()) entry[@"currentRank"] = @(static_cast<int>(match - matches.begin()) + 1);
                }
            }
        } catch (...) { cleanup(); throw; }
        cleanup();
        return [NSJSONSerialization dataWithJSONObject:result options:0 error:nullptr];
    }

    ~Engine() {
        discardIterators();
        if (session) api.destroySession(session);
        discardIterators();
        if (initialized) api.finalize();
    }
};

static void replyCandidates(FILE *output, const std::vector<Candidate> &words, bool spans) {
    if (words.empty()) { std::fprintf(output, "EMPTY\n"); return; }
    std::fprintf(output, "CAND");
    for (const auto &word : words) {
        std::string text = word.text;
        for (char &character : text) if (character == '\t' || character == '\n' || character == '\r') character = ' ';
        if (spans) std::fprintf(output, "\t%u:%s", word.cover, text.c_str());
        else std::fprintf(output, "\t%s", text.c_str());
    }
    std::fputc('\n', output);
}

static int run(FILE *output, int argc, char **argv) {
    if (argc != 4) throw std::runtime_error("usage: WeTypeNativeEngine <WeType.app> <workdir> <flypy|full>");
    int scheme = !std::strcmp(argv[3], "flypy") ? 3 : !std::strcmp(argv[3], "full") ? 0 : -1;
    if (scheme < 0) throw std::runtime_error("invalid input scheme: expected flypy or full");
    const fs::path bundle = fs::absolute(argv[1]);
    void *handle = dlopen((bundle / "Contents/MacOS/WeType").c_str(), RTLD_LAZY | RTLD_LOCAL);
    if (!handle) throw std::runtime_error(dlerror());
    {
        Engine engine(handle, bundle, fs::absolute(argv[2]), scheme);
        bool spans = false;
        std::string keys, line;
        std::vector<Candidate> words;
        std::fprintf(output, "READY\n");
        while (std::getline(std::cin, line)) {
            if (line == "Q") break;
            if (line == "PING") { std::fprintf(output, "PONG\n"); continue; }
            if (line == "OPT spans") { spans = true; std::fprintf(output, "OK\n"); continue; }
            if (line == "SAVE") { std::fprintf(output, "OK\n"); continue; }
            if (line == "C") { engine.reset(); keys.clear(); words.clear(); std::fprintf(output, "OK\n"); continue; }
            if (line.rfind("RANKS\t", 0) == 0) {
                if (!keys.empty()) { std::fprintf(output, "ERR_BUSY\n"); continue; }
                NSData *bytes = [[NSData alloc] initWithBase64EncodedString:@(line.substr(6).c_str()) options:0];
                id records = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nullptr] : nil;
                if (![records isKindOfClass:[NSArray class]]) { std::fprintf(output, "ERR\n"); continue; }
                NSData *data = engine.rankWords(records);
                if (!data) { std::fprintf(output, "ERR\n"); continue; }
                std::fprintf(output, "RANKED\t%s\n", [[data base64EncodedStringWithOptions:0] UTF8String]);
                continue;
            }
            if (line == "LEARNING") {
                if (!keys.empty()) { std::fprintf(output, "ERR_BUSY\n"); continue; }
                NSData *data = engine.learnedWords();
                if (!data) { std::fprintf(output, "ERR\n"); continue; }
                std::fprintf(output, "LEARNED\t%s\n", [[data base64EncodedStringWithOptions:0] UTF8String]);
                continue;
            }
            if (line.rfind("FORGET\t", 0) == 0) {
                size_t separator = line.find('\t', 7);
                std::string pinyin = separator == std::string::npos ? "" : line.substr(7, separator - 7);
                std::string word = separator == std::string::npos ? "" : line.substr(separator + 1);
                bool valid = !pinyin.empty() && pinyin.size() <= 256 && !word.empty() && word.size() <= 512;
                bool previousSeparator = true;
                for (char key : pinyin) {
                    if (key == '\'') { if (previousSeparator) valid = false; previousSeparator = true; }
                    else { if (key < 'a' || key > 'z') valid = false; previousSeparator = false; }
                }
                if (previousSeparator) valid = false;
                NSString *text = [[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding];
                NSMutableCharacterSet *invalid = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
                [invalid formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
                if (!text || [text rangeOfCharacterFromSet:invalid].location != NSNotFound) valid = false;
                if (!valid) { std::fprintf(output, "ERR\n"); continue; }
                if (!keys.empty()) { std::fprintf(output, "ERR_BUSY\n"); continue; }
                bool success = engine.forget(pinyin, word);
                words.clear();
                std::fprintf(output, "%s\n", success ? "OK" : "ERR");
                continue;
            }
            if (line.size() > 2 && (line[0] == 'B' || line[0] == 'L') && line[1] == ' ') {
                std::string added = line.substr(2);
                bool valid = keys.size() + added.size() <= 256;
                for (char key : added) if (!((key >= 'a' && key <= 'z') || key == '\'')) valid = false;
                if (!valid) { std::fprintf(output, "ERR\n"); continue; }
                for (char key : added) {
                    if (!engine.input(key)) { valid = false; break; }
                    keys += key;
                    if (line[0] == 'L') break;
                }
                if (valid) { words = engine.candidates(keys.size()); replyCandidates(output, words, spans); }
                else { engine.reset(); keys.clear(); words.clear(); std::fprintf(output, "ERR\n"); }
                continue;
            }
            if (line.rfind("S ", 0) == 0) {
                size_t end = 0;
                int rank = -1;
                try { rank = std::stoi(line.substr(2), &end); } catch (...) {}
                if (end != line.size() - 2 || rank < 0 || static_cast<size_t>(rank) >= words.size()) {
                    std::fprintf(output, "ERR\n"); continue;
                }
                const Candidate chosen = words[rank];
                if (!chosen.cover || chosen.cover > keys.size() || !engine.select(chosen)) {
                    std::fprintf(output, "ERR\n"); continue;
                }
                keys.erase(0, chosen.cover);
                words = engine.candidates(keys.size());
                if (keys.empty()) { words.clear(); std::fprintf(output, "OK\n"); }
                else replyCandidates(output, words, spans);
                continue;
            }
            std::fprintf(output, "ERR\n");
        }
        // Destruction persists the learned dictionary before acknowledging shutdown.
    }
    std::fprintf(output, "BYE\n");
    return 0;
}

int main(int argc, char **argv) {
    std::signal(SIGPIPE, SIG_IGN);
    FILE *output = fdopen(dup(STDOUT_FILENO), "w");
    if (!output) return 1;
    setvbuf(output, nullptr, _IOLBF, 0);
    // The vendor executable's static initializers log to stdout. Isolate them
    // from the protocol and from our app's Objective-C/Swift runtime.
    dup2(STDERR_FILENO, STDOUT_FILENO);
    int result = 1;
    @autoreleasepool {
        try { result = run(output, argc, argv); }
        catch (const std::exception &error) { std::fprintf(stderr, "[native-engine] %s\n", error.what()); }
    }
    std::fflush(output);
    // finalize() above performs engine cleanup. Do not unload the vendor's main
    // executable or execute its process-global application destructors.
    _Exit(result);
}

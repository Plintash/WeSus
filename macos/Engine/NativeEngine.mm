// Native WeType 2.2.3 adapter. ABI offsets are recovered from the official
// executable's Swift reflection metadata; see docs/macos-native-engine.md.
// Vendor binaries and dictionaries are downloaded locally, never committed.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <csignal>
#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace fs = std::filesystem;

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

    std::vector<Candidate> candidates() {
        auto values = takeIterators();
        std::vector<Candidate> result;
        try {
            if (!values.empty()) {
                Record<112> candidate;
                int limit = 72;
                if (const char *value = std::getenv("WETYPE_MAX_CAND")) {
                    try { limit = std::clamp(std::stoi(value), 10, 72); } catch (...) {}
                }
                for (int i = 0; i < limit && api.nextCandidate(values.back(), candidate.data); i++) {
                    // These pointers are borrowed and change at the NEXT call.
                    result.push_back({stringField(candidate.data, 0, 8), stringField(candidate.data, 32, 40),
                                      field<uint32_t>(candidate.data, 100)});
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
                if (valid) { words = engine.candidates(); replyCandidates(output, words, spans); }
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
                words = engine.candidates();
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

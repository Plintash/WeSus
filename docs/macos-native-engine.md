# macOS 原生引擎调查与实证

调查日期：2026-10-15。测试环境：macOS 26.5.2（25F84），Apple Silicon / arm64。

## 结论

可以直接复用官方 **macOS Mach-O 版本**的 WeType 引擎，无需运行 Android ELF、QEMU、Linux 或虚拟机。已用独立原生 C++ 进程加载官方主程序，取得真实小鹤双拼候选、完成部分选词并验证学习持久化。这是本项目 macOS 版的优先实现路线。

这是对 **WeType 2.2.3 build 657** 的实测结论，不是腾讯公开承诺的 SDK。C 结构 ABI 来自该版本自身的 Swift reflection metadata，并通过实际调用确认。后续版本不能未经验证直接替换。

## 取证来源

- [腾讯官方版本接口](https://z.weixin.qq.com/web/api/app_info)：返回 macOS `InstallInfo`，对应 `2.2.3_657`。
- [腾讯官方原生客户端 ZIP](https://download.weread.qq.com/app/wxkb/mac/2.2.3/WeType_2.2.3_657.zip)：本次静态检查与运行实证的原始制品。
- [Homebrew 官方 cask 源码](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/w/wetype.rb)：独立给出上述下载 URL、版本和 SHA-256，且注明输入法包路径。
- [Apple dyld 的 dlopen 实现](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldAPIs.cpp)：`options.canBeExecutable` 对 macOS 开启，因此当前系统允许 `dlopen` Mach-O 主可执行文件。
- [Apple Mach-O 校验器](https://github.com/apple-oss-distributions/dyld/blob/main/common/MachOFile.cpp)：使用 Mach-O magic 与 Mach-O 加载命令验证输入。
- [AOSP bionic 概览](https://android.googlesource.com/platform/bionic/+/refs/heads/main/README.md)：Android C 库、动态链接器及 Linux 内核 ABI 的来源。
- [Apple Hypervisor 文档](https://developer.apple.com/documentation/hypervisor)：该框架创建 VM / vCPU，属于虚拟化路线。

腾讯文件只下载、解包到 Git 忽略的 `.deps/native-research/`；没有安装或启动官方 App，没有修改系统输入法设置。ZIP 的 SHA-256 与 Homebrew 一致：

```text
8ef48bb21fe9d7b017b8a09fb9496b1b8f960ad960db27872226e08c09db264b
```

## 官方包的实际结构

`WeType.app/Contents/MacOS/WeType` 是含 **arm64 与 x86_64** 两个 slice 的 universal Mach-O executable。`file`、`lipo`、`otool -L`、`nm -gU` 均在本次调查中运行。

引擎静态链接在主可执行文件里，没有发现独立 `libwxhld.dylib`。包中的 `wcwss`、`flurry`、`WXP2PTransferDyn` 是传输相关框架；不需要把它们误认成输入候选引擎。`Resources/imeData.bundle/index.json` 给出 Mac 版本的字典文件、类型 ID 与版本信息，应使用这些字典，不应直接套用 Android 字典表。

主程序导出 48 个 `wxime_*` C API，其中已实际调用并验证的核心 API：

```c
const char *wxime_get_version(void);
void wxime_initialize(void *config);
bool wxime_config_dict(void *dict_config);
uint64_t wxime_create_session(void *session_config);
void wxime_add_session_listener(uint64_t session, void *callback, void *cookie);
bool wxime_process_input(uint64_t session, const char *key,
                         unsigned key_len, const void *aux, unsigned aux_len);
bool wxime_candidate_next(uint64_t iterator, void *candidate);
void wxime_delete_candidate_iterator(uint64_t iterator);
void wxime_reset_session(uint64_t session);
void wxime_destroy_session(uint64_t session);
void wxime_finalize(void);
bool wxime_select_candidate(uint64_t session,
    const char *text, unsigned text_len, const char *id, unsigned id_len,
    const char *suffix, unsigned suffix_len, const char *extra, unsigned extra_len,
    void *display_candidates, unsigned count, const void *source);
```

`wxime_get_version()` 实测返回：

```text
0.45.0.weekly_release/2026.08.05.b95d82518
```

上述声明是本版本的实证 ABI，不是厂商公开头文件。末尾可选参数在测试中全部传空。

## 结构 ABI 与关键配置

通过 `nm` 定位 `_wxime_configVMF` 等 Swift 字段描述，以及相应 value witness / metadata 中的大小与字段偏移。解码的完整本地证据在 `.deps/native-research/layouts.txt`；解码脚本为 `metadata.py` 与 `layouts.py`。

| 类型 | 大小 | 已验证的必要字段与偏移（字节） |
|---|---:|---|
| `_wxime_config` | 208 | logger 0；log_without_time 8；work_dir 24；uin 指针 64 / 长度 72；log_level 76；platform 80；app_ver 88 / 长度 96；package_type 192 |
| `_wxime_session_config` | 312 | async wrapper 0；instant search wrapper 1；keyboard_type 4；input_augment_option 8；local_most_likely 44；enable_local_correction 174 |
| `_wxime_input_augment_option` | 36 | double_pin_solution 24，因此 session 内的绝对偏移为 32 |
| `_wxime_candidate` | 112 | text 指针 0 / 长度 8；comment 指针 16 / 长度 24；candidate_id 指针 32 / 长度 40；cover_input_len 100 |
| `_wxime_dict_item` | 24 | fd 指针 0；path 指针 8；id 16；version 20 |
| `_wxime_fd` | 12 | fd 0；size 4；offset 8 |

实际字典配置包布局为 `{items 指针 @0, count uint32 @8, userdir 指针 @16, safe bool @24}`，调用方反汇编与实测相符。

注意 `dict_item.fd` 是 `_wxime_fd *`，使用文件路径时传 **nullptr**。它不是一个直接的文件描述符，填 `-1` 会造成非法指针访问。

初始化须提供非空日志回调 `void logger(int level, const char *message)`。空日志回调导致引擎断言。测试以 `platform = 5`（Mac）、`package_type = 3`、数字字符串本地用户 ID 初始化，所有写入限定在指定工作目录。

使用同步 wrapper（偏移 0 为 0）与即时候选搜索 wrapper（偏移 1 为 1）使候选回调同步返回。键盘类型 `0` 是本次全键盘拼音路线。每次 `wxime_process_input` 传一个字符；把 `nihc` 当一个键传入会触发音节图断言。

### Mac 小鹤双拼的枚举

Swift `ShuangpinScheme` 的枚举案例 metadata 与实际 C 映射表共同给出：

| UI 方案 | C API `double_pin_solution` |
|---|---:|
| 自然码 | 5 |
| 搜狗 | 1 |
| 微软 | 2 |
| **小鹤** | **3** |
| 拼音加加 | 4 |
| 紫光 | 6 |
| 智能 ABC | 7 |
| 关闭 | 0 |

小鹤 `3` 经候选实测确认。表来自当前 Mac 二进制，不能把未经核对的 Android 枚举假设套用到这里。

## 回调与所有权

已验证 listener ABI：

```c
void listener(uint64_t session, int *event_types, void **payloads,
              unsigned count, void *cookie);
```

- 事件 `0`：候选更新。payload 开头的 `uint64_t` 是本地候选 iterator；第二个 `uint64_t` 是云端 iterator，本次配置下为 0。
- 事件 `2`：上屏。payload 的字符指针位于 0，UTF-8 字节长度 `uint32_t` 位于 8；须在回调内复制。
- 事件 `4` / `5`：分别出现于音节与预编辑更新，本次 helper 不依赖它们。

**候选 text / id 指针由 iterator 借出，下一次 `candidate_next` 会使之前内容失效。** 必须在每次取候选后立即复制文本和候选 ID，不能只复制外层 112 字节结构体。未复制 ID 的 probe 在选词时触发 CandidateIDParser 断言；复制 ID 后正常选词与学习。

callback 创建的 iterator 必须单独通过 `wxime_delete_candidate_iterator` 归还。测试在 `process_input` 返回后删除中间 iterator，在取完最终候选后删除最终 iterator；保留的是自己复制的候选 text / ID。不要将 `process_input` 的 bool 返回值当作 iterator。

测试程序在退出前执行 `destroy_session` 和 `finalize`，之后 `_Exit(0)`。这既完成引擎显式清理和学习落盘，又避免加载的整个官方 App 的静态析构流程。早期只加载后普通退出，在未完整初始化的异常路径上观察到 `recursive_mutex lock failed`。不建议对主程序执行 `dlclose`。

官方主程序的静态构造函数会输出 `LOG Library Init ERROR : Find Module path failed`，但后续候选、选词和学习调用均正常。helper 必须提前复制 stdout 作为协议出口，然后把普通 stdout 重定向 stderr，防止这些打印破坏 `READY` / `CAND` 协议。

## 已通过的原生功能实证

临时研究 helper：`.deps/native-research/native_daemon.cpp`。编译命令为 `clang++ -std=c++17`；只依赖 macOS libc++ / dyld，没有 Linux 组件。

| 验证 | 实际结果 |
|---|---|
| 小鹤 `nihc` | 首候选 `你好`，覆盖 4 个键 |
| 小鹤 `vsgo` | 首候选 `中国`，覆盖 4 个键 |
| `nihcui` 部分选词 | 选择 `你好` 后剩余候选 `是`，覆盖 2 个键；继续选词完成 |
| 选词与重置 | `S rank`、`C`、后续输入均正常 |
| 学习 | 连续选择 `拟好` 5 次，当前 session 中排名上升 |
| 重启持久化 | 显式 finalize 并重启后，`nihc` 首候选成为 `拟好` |
| 协议及退出 | `READY`、`OPT spans`、`B`、`S`、`C`、`Q`；正常退出码 0 |

学习/部分选词测试为 `.deps/native-research/test_daemon.py`，使用新建隔离目录，不改真实用户词库。这些是 helper 与引擎层的验证，不能替代 InputMethodKit 对真实应用上屏的系统集成测试。

## 其他路线判断

Android ARM64 与 Apple Silicon 同为 ARM64 不代表 ELF 可直接运行：仓库当前 harness 依赖 bionic 动态链接器、Android C 库、Linux syscall/TLS ABI；Apple dyld 验证的是 Mach-O 格式。自行实现 Darwin ELF loader 后仍需覆盖这些 ABI 与内核接口。基于 AOSP/Apple 的一手源码，这是明显比现有 Mac 引擎接口更大的兼容层工作；本次未实现、也未证明此路线不可行。

Hypervisor.framework 可以在 macOS 进程里承载 VM / vCPU，但仍然是虚拟化，不能将其称作用户要求的完全原生引擎。OrbStack 适合作为现有 Android 引擎和 Linux reference 的开发验证环境，不需要作为最终运行依赖。

## 后续限制与维护点

1. 首版必须固定 ZIP 版本、SHA-256 与 ABI。用户更新官方 App 不能自动改变 helper 的目标二进制。
2. Apple dyld 当前允许加载主程序，但源码注释提到将来可能禁用；这是未来兼容风险。当前 macOS 26.5.2 已实际验证。
3. 官方 ZIP、字典和引擎保持本地下载，不进入 Git 或项目 release；原生 helper / App 可以独立构建。
4. 本次未验证 Intel Mac、hardened runtime/library validation、签名公证分发或真实 InputMethodKit 系统上屏。
5. 测试未调用登录与云网络 API；这不构成对专有引擎内部行为的网络保证。

## InputMethodKit 注册检查补记

本次首版 App 的旧 bundle ID `io.github.plintash.wetype-ime` 缺少 `.inputmethod.`。对当前 macOS 26.5.2 自带 `InputMethodKit.framework/Resources/imklaunchagent` 进行只读 ARM64e 反汇编发现：程序取得 `CFBundleGetIdentifier` 后，用 `CFStringFindWithOptions` 搜索字面量 `.inputmethod.`；不匹配时，只有存在未公开的 `InputMethodType` plist 键才继续，否则进入失败路径。对应指令地址 `0x100004d14` 至 `0x100004d94`，本地证据 `.deps/native-research/imklaunchagent.asm`。因此采用标准 bundle ID，例如 `io.github.plintash.inputmethod.wetype-ime`，同步更新模式 ID 和注册查询条件，是实际系统检查支持的修正。

[Fcitx 的正式 plist](https://github.com/fcitx/fcitx5-macos/blob/master/cmake/MacOSXBundleInfo.plist.in) 使用 `org.fcitx.inputmethod.Fcitx5`，`LSBackgroundOnly` 为 true；[作者自己的 IMK 示例仓库](https://github.com/ensan-hcl/macOS_IMKitSample_2021) 也明确要求 `.inputmethod.`。Apple [IMKServer 初始化文档](https://developer.apple.com/documentation/inputmethodkit/imkserver/init(name:bundleidentifier:)) 要求 `LSBackgroundOnly` 为 1，首版应遵循。

当前编译后的 Objective-C runtime 类名通过 `otool -ov` 核实是裸名 `WeTypeInputController`，与 `@objc(WeTypeInputController)` 和 plist 一致；这里不应额外添加 Swift 模块前缀。

Apple SDK 的 `TextInputSources.h` 说明 `TISRegisterInputSource` 接受 `~/Library/Input Methods` 中的 App 并重建注册缓存，期望随后可立即查询。`noErr` 本身不能替代枚举结果验证。[Fcitx 的安装说明](https://github.com/fcitx/fcitx5-macos/blob/master/README.md) 仍要求首次安装后注销并重新登录。本次未修改当前用户选中的输入源，也未重启系统输入法服务或执行注销；若修正 metadata 后当前登录会话仍未枚举新输入源，最终系统级验证需等待新的登录会话，不能把 helper 测试称为系统注册成功。

### 系统选择失败的范围

后续检查中，注册后的来源曾被枚举为 enabled / select-capable，但选择返回 `paramErr (-50)`。SDK `TextInputSources.h` 还明确要求：若来源是 input mode，其父 input method 也须启用，不能只检查 mode 本身。

为区分 App 启动与来源状态问题，对当前系统 HIToolbox 做了只读调试反汇编：`TISSelectInputSource` 经 `TSMSelectInputSource`、`_TSMSetInputSourceSelected`，先调用 `TSMSelectInputSource_Internal`。后者验证来源 CF 类型与当前来源列表中的有效索引；再由 `isSetInputSourceSelected` 调用 `CheckIfSelectedStateInvalidated`、`islGetInputSourceList`，检查内部 enabled / selectable 状态。源验证失败、disabled 或不可选择均可在这层返回 -50，发生在 `ActivateNewInputSource` 与 InputMethodKit 客户端创建前。不能将这种早期 -50 直接解释为控制器类名或引擎启动失败。

本地反汇编证据：`.deps/native-research/tsm-internal-select-disasm.txt`、`tsm-validation-disasm.txt`、`tsm-validate-source.txt`。目前“选择期间刷新了临时注册缓存”是符合观察的推断，尚未通过错误路径断点实证。若需要进一步验证，应保存并还原当前来源，然后对现有选择工具断在 `isValidateInputSourceRef` 和 `isSetInputSourceSelected` 的失败分支；本次研究进程未执行选择操作。

### 当前登录会话中的菜单问题

用户截图确认系统设置中已存在 WeType Flypy，但顶部输入菜单仍只有 ABC 和系统双拼。后续独立进程查询 `TISCreateInputSourceList(nil, false)` 已能列出 WeType 父输入法与 flypy 模式，二者均 enabled，模式 select-capable。不能再将这一现象归因于用户未添加输入源。

安装器现在先调用公开 `LSRegisterURL(appURL, true)` 刷新 App 注册，再注册输入源：更新前 Launch Services 仍保存了安装路径的旧版本元数据。该改动已执行成功，但菜单恢复尚未验证。尝试通过 launchctl 重载 TextInputMenuAgent 返回 `Operation not permitted while System Integrity Protection is engaged`，服务未重启；未修改系统保护。仍需在新登录会话中验证菜单发现，以及真实应用的候选窗、上屏；不能将 enabled / select-capable 属性或引擎测试视为系统集成完成。

随后用户重新登录，并明确反馈输入法已能在真实应用中使用。上述注册异常属于首次登录会话的历史排查记录，不再表示当前仍无法输入。后续工作针对候选浮窗的刷新、方向键、展开和视觉对齐；这些前端变化使用原生 AppKit 浮窗，通过 InputMethodKit 处理系统输入。回归脚本现包含真实 NSPanel 的窗口复用、展开锚点、六列排版与收起检查，以及中文、长词、英文的像素居中测量。候选底部保留实际可用的翻页、设置入口，没有将原厂的部首、笔画等未实现功能画成可用按钮。

系统设置中输入源右侧的内嵌选项没有找到公开扩展接口。Apple 的 [showPreferences: 文档](https://developer.apple.com/documentation/inputmethodkit/imkstatesetting/showpreferences(_:)) 和当前 SDK `IMKInputController.h` 描述的是由输入法展示自己的设置窗口，支持指定 `InputMethodServerPreferencesWindowControllerClass`，不构成向该右侧区域注入视图的公开契约。当前设置入口位于输入法菜单和候选窗齿轮，不能宣称已实现用户指定的内嵌位置。

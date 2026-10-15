# WeSus · 巨疑输入法

面向 macOS 的原生中文输入法，默认小鹤双拼，也支持全拼。使用 AppKit / InputMethodKit 接入系统，以 WeType 的原生引擎提供候选与本地学习，自己实现候选浮窗、键盘交互和设置。

日常运行不需要 Linux、Android、QEMU 或虚拟机。

> 开发预览版。已在 Apple Silicon / macOS 26.5.2 上验证输入、部分选词和学习持久化，其他应用与系统版本仍需实测。非官方项目，与腾讯无关，也未获其认可。

## 功能

- 默认小鹤双拼，可切换全拼。
- 紧凑候选条、展开候选网格、方向键导航、数字选词和翻页。
- 数字序号跟随高亮所在的候选行移动。
- macOS 26 使用 Liquid Glass 材质；旧系统回退为原生毛玻璃材质。展开与收起有连续动画，遵守系统“减少动态效果”。
- 本地选词学习，重启后保留；支持部分选词后继续组词。
- 中文标点、Shift 大写直出，以及可选的本地英文释义词表。
- 原生设置窗口，可从输入法菜单或候选窗齿轮打开。

## 构建与安装

需要 Xcode（包含 macOS SDK）和 Python 3。目前在 Apple Silicon 上验证。

```sh
git clone https://github.com/Plintash/WeSus.git
cd WeSus
bash scripts/macos/prepare_native.sh
bash scripts/macos/install_app.sh
```

准备脚本下载并校验固定版本的官方 Mac 安装包，仅在本机解包引擎。安装脚本构建本项目 App，安装到 `~/Library/Input Methods/WeTypeIME.app`，注册输入源并保留当前键盘选择。

安装后从菜单栏切换到 **WeSus**（中文系统显示 **巨疑输入法**）。也可在“系统设置 → 键盘 → 输入法”中查看。首次安装若未出现在菜单中，注销并重新登录一次。

已有官方 ZIP 时可直接指定，仍会验证 SHA-256：

```sh
bash scripts/macos/prepare_native.sh /path/to/WeType_2.2.3_657.zip
```

单独构建、打开测试窗口或设置：

```sh
bash scripts/macos/build_app.sh
open build/macos/WeTypeIME.app --args --demo
open build/macos/WeTypeIME.app --args --settings
```

测试窗口无需切换系统输入法。`WeTypeIME.app` 和现有 Bundle ID、数据目录属于内部标识，改名为 WeSus 后继续沿用，保留已有输入源注册和学习数据。

## 选词操作

| 按键 | 行为 |
|---|---|
| `←` / `→` | 移动高亮 |
| `↓` | 单行时展开；展开后向下一行移动 |
| `↑` | 向上一行移动；在第一页首行收起 |
| `1`–`9`、`0` | 选择带序号行的对应候选，`0` 对应第十项 |
| 空格 | 确认当前高亮候选 |
| `-` / `=`、`[` / `]`、Page Up / Down | 翻页 |
| Esc | 展开时收起；单行时取消组词 |
| Enter | 单行时输出原始按键；展开时确认候选 |
| 退格 | 删除输入 |

展开后保留首行，并增加四行、每行六个候选。序号随高亮行移动；末行的空位数字不会选中其他行。异步更新时复用同一个浮窗，最新候选返回前不会误选旧候选。

## 设置与数据

在输入法菜单中选择“设置…”，或点击展开候选窗底部的齿轮。

| 设置 | 可选项 |
|---|---|
| 拼音方案 | 小鹤双拼 / 全拼 |
| 单行候选数 | 1–10，默认 5 |
| 候选总数上限 | 10 / 20 / 40 / 72 |
| 中文标点 | 开启 / 关闭 |
| 英文释义 | 导入本地 UTF-8 TSV 词表，开关显示 |
| 数据与日志 | 打开对应文件夹；恢复默认设置保留词表和学习数据 |

词表每行格式为 `中文词<Tab>英文释义`，仅影响候选显示，不改变上屏内容。导入后复制到应用数据目录，不依赖原文件。

- 学习数据：`~/Library/Application Support/WeTypeIME/Dictionary`
- 英文词表：`~/Library/Application Support/WeTypeIME/glossary-en.tsv`
- 引擎文件：`~/Library/Application Support/WeTypeIME/Engine/WeType.app`
- 日志：`~/Library/Logs/WeTypeIME/engine.log`

设置在当前这次组词结束后应用。当前提供独立设置窗口，尚未嵌入系统设置的输入源右侧区域。

## 引擎与隐私边界

当前固定使用官方 **macOS WeType 2.2.3 build 657**。原生适配进程加载官方二进制，调用其导出的 `wxime_*` 接口，并读取配套词库；官方界面与正常 App 启动入口不参与输入流程。二进制加载阶段仍会执行静态初始化。

这些是针对固定版本分析并验证的内部接口，不是官方公开 SDK，不能未经验证替换为新版引擎。实现与证据见 [原生引擎记录](docs/macos-native-engine.md)。

本项目未接入账号登录、云候选、云同步、跨设备剪贴板或在线释义。**当前没有强制网络隔离，不能保证专有引擎内部绝不联网。** 独立进程用于隔离运行时和故障，不等同于安全沙箱。

官方引擎、安装包、词库及用户数据均不进入 Git，也不随项目发布包分发。准备脚本会从官方地址下载并校验包，运行时使用本机文件。

## 开发与验证

```sh
bash scripts/macos/test_app.sh
python3 scripts/test_flypy.py --backend native
```

前者验证组词状态、异步选词、按键映射、候选排版和窗口生命周期；后者用隔离词库验证真实引擎的小鹤输入、部分选词及学习持久化。系统输入与具体应用的兼容性仍需人工实测。

| 目录 | 内容 |
|---|---|
| `macos/Sources/` | InputMethodKit 接入、组词状态、候选窗和设置 |
| `macos/Engine/` | 原生引擎适配进程 |
| `macos/Tools/` | 图标生成与输入源注册 |
| `scripts/macos/` | 准备、构建、安装和测试脚本 |
| `assets/wesus-mark.svg` | 原创矢量标记 |

## 上游与许可

本项目 fork 自 [yu1745/wetype-ime-linux](https://github.com/yu1745/wetype-ime-linux)，感谢上游的引擎研究与实现。WeSus 聚焦 macOS；Linux / Fcitx 5 说明单独保留在 [Linux 上游参考](docs/linux.md)，Linux 使用与维护请参考上游。

项目源码使用 **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。WeType 引擎和词库归腾讯所有，不在本项目许可范围内；使用时须遵守相关条款。继承自上游的 JNI 声明来源与许可见 [JNI 说明](licenses/jni/README.md) 和 [Apache-2.0 许可证](licenses/Apache-2.0.txt)。

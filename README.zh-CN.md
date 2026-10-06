<p align="center">
  <img src="docs/hero.jpg" alt="Glancy：把 MacBook 刘海变成实时信息区，显示 Claude Code 会话、会议、音乐、剪贴板和窗口">
</p>

<p align="center">
  <a href="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml"><img src="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift，无依赖">
  <img src="https://img.shields.io/badge/RAM-~19%20MB-2ea44f" alt="约 19 MB 内存">
  <img src="https://img.shields.io/badge/telemetry-none-2ea44f" alt="无遥测">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

<p align="center"><sub><a href="README.md">English</a> · <b>简体中文</b> · <a href="README.ja.md">日本語</a></sub></p>

# Glancy

**让 MacBook 的刘海派上用场。** Glancy 把刘海变成一块小小的实时信息区：哪些 Claude Code 会话正在工作、哪些在等你确认，下一个会议和"加入"按钮，正在播放的音乐，计时器，文件暂存架，剪贴板历史，以及窗口平铺。鼠标悬停预览，点击展开。

**从设计上就很轻。** 空闲时约 19 MB 内存，每分钟 0 CPU 秒；刘海收起时没有任何定时器或轮询，一切都由系统事件驱动。数据不会离开你的 Mac。

<p align="center">
  <img src="docs/screens.jpg" alt="主页、Agents、日历、媒体、剪贴板和窗口标签页">
</p>

<sub>图片使用的是虚构的演示数据。</sub>

## 功能

**刘海本身**
- **收起时**：和硬件刘海完全一致。有事发生时，两侧会长出"翅膀"，显示最重要的实时活动：等你确认的会话、即将开始的会议、计时器、音量提示、正在播放的歌曲。
- **预览**：悬停可以看到提示；有事件时（会话完成、AirPods 连接、切歌）会短暂下拉显示。
- **展开**：点击打开带标签页的完整面板。按 Esc、点击外部或移开鼠标即可收起。
- 翅膀永远不会盖住菜单或状态栏图标。没有刘海的显示器上可以显示一个小胶囊（可选）。
- 默认在截图和屏幕共享中隐藏（可在设置中关闭）。支持英语和意大利语界面。

**Claude Code 会话**
- 每个活跃会话在翅膀中显示为一个圆点：工作中、**等待权限确认**（琥珀色）、已完成、失败。
- Agents 标签页：每个会话的项目、状态、持续时间、最后使用的工具和最后一条提示。
- 点击会话即可把它的终端窗口调到前台（Terminal、iTerm、Ghostty、Warp、VS Code）；⌥-点击则调到前台并平铺。
- **Lay out sessions** 一键平铺所有 Claude 终端，先预览，可撤销。
- 读取一个小型 hook 日志（见 [Claude Code 设置](#claude-code-设置)），Glancy 自己从不与 Claude 通信。

**日历**
- 下一个会议，带倒计时和 **Join** 按钮，支持 Zoom、Google Meet、Teams、Webex、Whereby 和 FaceTime 链接。
- 日历标签页显示今天和明天的日程，使用各日历的颜色；已拒绝的会议会隐藏，可选择要包含哪些日历。

**媒体**
- 显示**任何**播放器正在播放的内容，包括浏览器：封面、进度、播放/暂停、上一首/下一首、输出设备。
- 翅膀使用封面的主色调，切歌时短暂提示。

**HUD、电池和 AirPods**
- 用刘海中的安静提示替代系统的音量、亮度和键盘背光弹窗（按住 ⌥⇧ 可以四分之一步调节）。
- 接通/断开电源、低电量和低电量模式会短暂显示。
- AirPods 等耳机连接时显示左耳、右耳和充电盒电量。

**计时器和番茄钟**
- 5、15、25、50 分钟或自定义，以及 25/5 的番茄钟循环。翅膀中显示进度环，结束时提醒；重启后依然保留。

**暂存架**
- 把文件拖到刘海上暂存，之后再拖到任何地方。可以从暂存架隔空投送、共享和快速查看。最多 24 项，重启后保留。

**剪贴板历史**
- 最近 60 次复制：文本、富文本、链接、图片和文件，支持搜索和置顶。⌥⌘V 打开。
- 跳过密码以及应用标记为隐藏或临时的内容，也跳过密码管理器。可暂停、按应用排除和清空。

**窗口**
- 刘海中显示当前显示器的实时缩略图：悬停单元格会在真实屏幕上预览，点击即可放置。
- 选择网格（2×1 或任意大小），整理整个屏幕、某个应用，或你挑选的窗口（⌘-点击，按顺序）。策略：Balanced、每格一个、按列、按行、主窗口 + 堆叠。
- 把窗口拖进刘海即可放到某个单元格。键盘：⌃⌥Space 打开缩略图，⌃⌥←/→/↑/↓ 左右半屏、最大化和还原，⌃⌥F 适配，⌃⌥B/C/R/M/G 整理（加 ⇧ 只整理前台应用），⌃⌥Z 撤销。所有快捷键都可以修改。
- 每次整理在应用前都会预览，并且可以撤销。

**通知**（需手动开启，实验性）
- 在标签页中按应用分组显示最近的通知，新通知到达时短暂提示，可按应用静音。默认关闭；需要"完全磁盘访问权限"才能（只读）读取。

## 安装

Glancy 需要 macOS 14 或更高版本，支持 Apple 芯片和 Intel，专为带刘海的 MacBook 设计；参见[局限](#局限)。

**下载**

1. 从[最新版本](https://github.com/giacolaiacomo/glancy/releases/latest)下载 `Glancy-x.y.z.zip`，解压后把 **Glancy** 拖到"应用程序"。
2. 打开它。Glancy 没有使用付费的 Apple Developer ID 签名，所以第一次打开时 macOS 会提示无法验证：点击**完成**，然后打开**系统设置 → 隐私与安全性**，点击**仍要打开**。也可以在终端中运行：`xattr -dr com.apple.quarantine /Applications/Glancy.app`。
3. 首次启动时，刘海中会出现一个简短的权限清单。每项权限都是可选的。

发布的 zip 由 [GitHub Actions](.github/workflows/release.yml) 从打了标签的源码构建，你可以确切地查看其中包含了什么。它使用 ad-hoc 签名，有一个小问题：macOS 会把每个新版本当作新应用，所以更新后可能需要重新授予辅助功能等权限。用 Apple Development 证书自行构建可以避免这个问题（见下文）。

**Homebrew**（从源码构建）

```sh
brew install giacolaiacomo/tap/glancy
brew services start glancy     # 立即启动，并在每次登录时启动
```

更新：`brew upgrade glancy`。卸载：`brew services stop glancy && brew uninstall glancy`。

**从源码构建**

```sh
git clone https://github.com/giacolaiacomo/glancy.git
cd glancy
./install.sh
```

这会构建 `~/Applications/Glancy.app`，开启**登录时打开**并启动它。更新：`git pull && ./install.sh`。连同数据、设置和权限一起卸载：`./uninstall.sh`。

构建需要 Swift 6.2 工具链（Xcode 26 或其命令行工具：`xcode-select --install`）和 `cmake`（`brew install cmake`）。如果钥匙串中有 "Apple Development" 证书，`scripts/build-app.sh` 会用第一个证书签名，这样重新构建后权限依然保留；否则使用 ad-hoc 签名。可以通过 `GLANCY_SIGN_IDENTITY` 指定。

## Claude Code 设置

Agents 模块读取一个由小型 Claude Code hook 写入的日志。Glancy 从不修改你的 Claude 设置，所以这一步需要你自己完成：

1. 复制 hook（在本仓库的克隆目录中）：`mkdir -p ~/.claude/hooks && cp hooks/cc-dashboard-event.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/cc-dashboard-event.sh`
2. 在 `~/.claude/settings.json` 中为以下七个事件添加它（与已有的 `hooks` 合并；把 `YOU` 换成你的用户名）：

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "StopFailure":       [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }]
  }
}
```

hook 每个事件向 `~/.claude/hooks/data/cc-dashboard/events.jsonl` 追加一行：时间、事件、会话 ID、工作目录、工具名称和提示的前 200 个字符。它不输出任何内容，总是以 0 退出，不会阻塞 Claude Code。它需要 `jq`，macOS 15 及以上已自带（macOS 14 上请 `brew install jq`）。新会话一开始就会出现在刘海中。

## 权限

所有权限都是可选的：缺少某项权限时，对应模块只是功能少一些。设置 → 权限中会显示每项的状态和授权按钮。

| 权限 | 用途 | 没有它时 |
|---|---|---|
| **日历** | 下一个会议、Join 按钮、日历标签页 | 不显示日历 |
| **辅助功能** | 拦截 HUD 按键；窗口平铺；跳转到会话的终端；剪贴板捕获 ⌘C 以及选择后粘贴；测量菜单宽度，让左侧翅膀不遮住菜单 | 保留系统 HUD；不能平铺；剪贴板在切换应用或打开刘海时才记录复制；左侧翅膀保持隐藏 |
| **蓝牙** | AirPods 和耳机连接提示及电量 | 没有耳机提示 |
| **通知** | 计时结束时的提醒 | 计时只在刘海中结束 |
| **自动化**（音乐、Spotify） | 针对这两个应用的备用读取方式，仅在主读取方式在你的 macOS 上不可用时使用 | 媒体功能仍通过主读取方式工作 |
| **完全磁盘访问权限** | 读取 macOS 的通知数据库，仅在你开启通知模块时 | 通知模块保持关闭 |

## 隐私

Glancy 没有遥测、没有账户。唯一的常规网络请求是更新检查（Sparkle）：启动时，以及打开面板时最多每天一次，从 GitHub 最新发布下载 `appcast.xml`（可在 设置 → 通用 中关闭）。它只在本地读取：

- **Claude Code**：上面的 hook 日志，只读，从末尾读取。Glancy 从不写入它，也从不运行 Claude。
- **日历**：通过 EventKit 读取你的日程，只保存在内存中。
- **媒体**：通过 [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)（一个随应用打包、用系统 Perl 运行的小程序）读取系统的正在播放信息；备用方案是对音乐和 Spotify 使用 AppleScript。
- **剪贴板**：你复制的内容，保存在 `~/Library/Application Support/Glancy/clipboard/`（仅限本人访问），跳过隐藏内容和密码管理器。随时可以清空。
- **通知**：仅在你开启该模块时，以只读方式打开 macOS 的通知数据库。
- **窗口**：通过辅助功能读取窗口标题和位置，用于绘制缩略图。除了网格、布局和快捷键外不保存任何内容。

设置保存在 `~/Library/Preferences/ai.glancy.app.plist`；数据（剪贴板、暂存架、计时器、窗口布局）保存在 `~/Library/Application Support/Glancy/`。`./uninstall.sh` 会全部删除。详见 [SECURITY.md](SECURITY.md)。

## 系统要求

- macOS 14 Sonoma 或更高版本。开发环境为 macOS 26、14 英寸 MacBook Pro 和一台外接带鱼屏。
- 带刘海的 MacBook 才能获得完整体验；其他显示器可以显示可选的小胶囊。
- Agents 功能需要 Claude Code 和上面的 hook。

## 局限

- **为刘海而生。** 在没有刘海的 Mac 或显示器上，Glancy 会在顶部中央显示一个小胶囊（默认关闭）；能用，但这不是它的重点。
- **部分功能需要辅助功能权限**，见[权限](#权限)。
- **窗口平铺取决于各个应用。** 有些应用拒绝缩小到最小尺寸以下，或会自己调整窗口；Glancy 会把这类窗口对齐到单元格边缘，并告诉你哪些没能精确放置。平铺是 Glancy 最新的部分，实际使用的检验比其他部分少。
- **ad-hoc 签名的版本**（发布的 zip，或没有证书时自行构建）每次更新都会丢失权限，因为 macOS 把它当作新应用。请在系统设置中重新授权。
- **通知功能是实验性的。** macOS 的通知数据库是私有且无文档的；读取器会检查数据库结构，不认识时会自动关闭。目前只在测试数据上验证过，尚未在各个 macOS 版本上验证。
- **媒体功能**通过 mediaremote-adapter 依赖 macOS 的一个私有框架。如果未来的 macOS 让它失效，Glancy 会退回到只支持音乐和 Spotify。
- 正在播放信息的辅助进程是一个单独的进程，约 5 MB，另计于 Glancy 的约 19 MB。

## 开发

```sh
swift build && swift test                      # 应当 0 警告
scripts/lint.sh                                # 收起时不允许定时器、轮询或鼠标移动监听
.build/debug/Glancy --self-test                # 对每个模块做无界面检查（CI 中也会运行）
scripts/render.sh                              # 把每个界面状态渲染成 PNG 到 render-out/（使用你的真实数据；--it 为意大利语）
scripts/screenshots.sh                         # 重新生成 README 图片（虚构的演示数据）
scripts/build-app.sh build/Glancy.app          # 构建应用包（UNIVERSAL=1 同时支持 Apple 芯片和 Intel）
scripts/footprint.sh                           # 空闲运行时的内存和 CPU
Glancy --diagnose                              # 正在运行的应用状态（模块、显示器、资源）
```

每个模块位于 `Sources/GlancyKit/<Module>/`，实现 `GlancyModule`（启动、停止、可见性、标签页、主页卡片），在 `Modules.swift` 中注册。让 Glancy 保持轻量的规则是：刘海收起时不运行任何定时器、动画或轮询，只有系统事件监听。`scripts/lint.sh` 会强制检查。详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。发布：在 GitHub 上发布 release 会运行 [release.yml](.github/workflows/release.yml)，构建通用版本应用并附上 zip。

## 致谢

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)，作者 Jonas van den Berg 及贡献者（BSD 3-Clause），收录在 `Vendor/` 中，用于读取正在播放的信息。
- [MacroVisionKit](https://github.com/TheBoredTeam/MacroVisionKit)（MIT）：检测全屏空间的方法。
- [Tessera](https://github.com/giacolaiacomo/tessera)（MIT）：平铺引擎最初的网格、整理和快捷键逻辑。Rectangle（MIT）为窗口放置的细节提供了参考。

完整声明见 [NOTICE](NOTICE) 和 [Sources/GlancyKit/Tiling/NOTICE.md](Sources/GlancyKit/Tiling/NOTICE.md)。不包含任何 GPL 代码；其他刘海应用仅作为参考阅读。

## 免责声明

Glancy 是一个独立项目，与 Apple 或 Anthropic 无关，也未获得其认可。Claude 和 Claude Code 是 Anthropic, PBC 的商标。

## 许可证

[MIT](LICENSE)

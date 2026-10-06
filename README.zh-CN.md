<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="Glancy 图标">

# Glancy

**让 MacBook 的刘海派上用场。**<br>
编程 Agent、下一个会议、音乐、笔记、剪贴板和窗口，一眼就能看到。

<a href="https://github.com/giacolaiacomo/glancy/releases/latest/download/Glancy.dmg"><img src="docs/download.svg" width="280" height="60" alt="下载 macOS 版"></a>

<sub>macOS 14+ · Apple 芯片和 Intel · 已签名并经过公证 · 自动更新</sub><br>
<sub>或使用 Homebrew：<code>brew install --cask giacolaiacomo/tap/glancy</code>（<a href="#homebrew">详情</a>）</sub>

<br>

<a href="https://github.com/giacolaiacomo/glancy/releases/latest"><img src="https://img.shields.io/github/v/release/giacolaiacomo/glancy?label=release&color=1F9AA6" alt="最新版本"></a>
<a href="https://github.com/giacolaiacomo/glancy/releases"><img src="https://img.shields.io/github/downloads/giacolaiacomo/glancy/total?color=1F9AA6" alt="下载次数"></a>
<a href="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml"><img src="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml/badge.svg" alt="Build"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
<img src="https://img.shields.io/badge/Swift-1%20dependency%20(Sparkle)-F05138?logo=swift&logoColor=white" alt="Swift，一个依赖（Sparkle）">
<img src="https://img.shields.io/badge/RAM-~18%20MB-2ea44f" alt="约 18 MB 内存">
<img src="https://img.shields.io/badge/telemetry-none-2ea44f" alt="无遥测">
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>

<sub><a href="README.md">English</a> · <b>简体中文</b> · <a href="README.ja.md">日本語</a></sub>

</div>

<br>

<p align="center">
  <img src="docs/screens.jpg" alt="Glancy 的标签页：主页、Agents、日历、媒体、笔记、命令栏、控制、监视器、剪贴板和窗口">
</p>
<p align="center"><sub>图片均为虚构的演示数据。</sub></p>

Glancy 把刘海变成一块小小的实时信息区。收起时，它就是硬件刘海本身；有事情发生时，两侧会伸出"翅膀"。鼠标悬停预览，点击打开完整面板。

**从设计上就很轻：** 空闲时约 18 MB 内存，每分钟 0 CPU 秒。刘海收起时不运行任何定时器或轮询，一切都由系统事件驱动。数据不会离开你的 Mac。

## 亮点

| 模块 | 功能 |
|---|---|
| **Agents** | Claude Code、Codex 和 OpenCode 的会话集中在一个面板：工作中、**等你处理**、已完成。点击即可跳到对应的终端或编辑器。 |
| **日历** | 下一个会议的倒计时和 **Join** 按钮（Zoom、Meet、Teams、Webex、Whereby、FaceTime）。 |
| **媒体** | 任何播放器（包括浏览器）正在播放的内容，附带控制按钮和输出设备。 |
| **笔记** | 纯文本 `.md` 笔记，支持复选框；**语音笔记**在本机转写成文字。 |
| **命令栏** | ⌃⌥K：应用、计算器、单位和货币换算，以及每个模块的命令。 |
| **剪贴板** | 最近 60 条复制内容，支持搜索和置顶（⌥⌘V）；跳过密码。 |
| **窗口** | 刘海中的实时网格缩略图、自动整理、工作区；每次移动都先预览，并可撤销。 |
| **更多** | 控制开关、系统监视器、计时器和番茄钟、文件暂存架、安静的音量/亮度 HUD、电池和 AirPods。 |

**适配你的屏幕：** 设置 → 通用 → **大小**（Size：Normal、Large、Extra large）可整体缩放面板，适合大屏或高分辨率显示器。**保持最新：** Glancy 在应用内自动更新。

## 功能

点击模块展开详情。

<details>
<summary><b>刘海本身</b>：收起、预览、展开</summary>

- **收起：** 就是硬件刘海本身。有事情发生时，两侧会伸出翅膀，显示最重要的实时活动：等你处理的 Agent、即将开始的会议、计时器、音量 HUD、正在播放的音乐。
- **预览：** 悬停显示提示；有事情发生时（会话结束、AirPods 连接、切换曲目）会短暂下拉显示。
- **展开：** 点击打开带标签页的完整面板。按 Esc、点击外部或移开鼠标即可关闭。
- 翅膀从不遮挡菜单或状态栏项目。没有刘海时（没有刘海的 Mac，或合盖接外接显示器的 MacBook），在顶部中央显示一个小胶囊；其他显示器上可选。
- **大小**（Size）：在设置 → 通用中选择 Normal、Large 或 Extra large；某个大小放不下屏幕时 Glancy 会提示你。
- 不出现在截图和屏幕共享中（可在设置中更改，默认开启）。支持英语和意大利语。

</details>

<details>
<summary><b>Agents</b>：Claude Code、Codex 和 OpenCode</summary>

- Claude Code（终端、VS Code、Cursor、Claude 应用）、Codex（CLI、VS Code、Codex 应用）和 OpenCode 集中在一个面板。
- 每个活动会话在翅膀中显示为一个圆点：工作中、**等待权限确认**（琥珀色）、已完成、失败。
- Agents 标签页：每个会话的项目、状态、处于该状态的时间、最后使用的工具和最后一条提示。
- 点击会话即可将其调到前台：它的终端（Terminal、iTerm、Ghostty、Warp）、编辑器窗口（VS Code、Cursor）或 Codex 应用。⌥-点击可调到前台并平铺。
- **Lay out sessions** 一次平铺所有 Claude 终端，应用前先预览，并可撤销。
- Claude Code 需要一个小 hook（[设置](#claude-code)）；Codex 和 OpenCode 无需设置（[设置](#codex-和-opencode)）。Glancy 只读取：从不与任何 Agent 通信。

</details>

<details>
<summary><b>日历</b>：下一个会议和 Join</summary>

- 下一个会议，带倒计时，并为 Zoom、Google Meet、Teams、Webex、Whereby 和 FaceTime 链接提供 **Join** 按钮。
- 日历标签页按日历颜色显示今天和明天的日程。已拒绝的日程会隐藏；可选择计入哪些日历。

</details>

<details>
<summary><b>媒体、HUD、电池和 AirPods</b></summary>

- **任何**播放器（包括浏览器）正在播放的内容：封面、进度、播放/暂停、上一首/下一首、输出设备。翅膀会带上封面的色调，切歌时短暂提示。
- 用刘海中一个安静的提示替代系统的音量、亮度和键盘背光叠加层（⌥⇧ 以四分之一格调节）。
- 充电、拔掉电源、电量低和低电量模式会作为简短活动显示。
- AirPods 和其他耳机连接时显示，附带左耳、右耳和充电盒电量。

</details>

<details>
<summary><b>计时器、番茄钟和暂存架</b></summary>

- 5、15、25、50 分钟或自定义，以及 25/5 番茄钟循环。翅膀中显示圆环，结束时提醒；重新启动后仍会继续。
- 把文件拖到刘海上暂存，之后再拖到任何地方。可从暂存架使用隔空投送、共享和快速查看。最多 24 项，重新启动后保留。

</details>

<details>
<summary><b>笔记和语音笔记</b></summary>

- 纯文本 `.md` 笔记，存放在可以在访达中打开的文件夹里，边输入边保存；`- [ ] ` 会变成复选框，笔记可以置顶到主页。⌃⌥N 打开笔记。
- **语音笔记：** 在任何应用中按 ⌃⌥V 开始和停止录音（5、15、30 或 60 分钟后自动停止，默认 30 分钟）。以 `.m4a` 保存在笔记旁边，支持播放和拖出。
- **转写**默认开启，完全在本机进行（设备端语音识别）；不会发送到任何地方。

</details>

<details>
<summary><b>命令栏</b></summary>

- ⌃⌥K 打开一个覆盖一切的搜索框：应用、计算器、单位和货币换算（汇率来自欧洲央行，仅在你输入货币查询时获取）、网页搜索兜底，以及每个模块的命令（加入下一个会议、保持唤醒一小时、保存工作区、CPU 占用最高的进程……）。⏎ 执行，⌘⏎ 执行次要操作。
- 会学习你的使用习惯。每个来源都可以在设置 → 命令栏中关闭。

</details>

<details>
<summary><b>剪贴板历史</b></summary>

- 最近 60 次复制：文本、富文本、链接、图片和文件，支持搜索和置顶。⌥⌘V 打开。
- 跳过密码、应用标记为隐藏或临时的内容，以及密码管理器。支持暂停、按应用排除和清空。

</details>

<details>
<summary><b>窗口</b>：网格缩略图、自动整理、工作区</summary>

- 刘海中显示当前显示器的实时缩略图：悬停在单元格上会在真实屏幕上预览，点击即可放置。
- 选择网格（从 2×1 到任意大小），整理整个屏幕、某个应用，或你挑选的窗口（按 ⌘-点击的顺序）。策略：均衡、每格一个、按列、按行、主窗口 + 堆叠。
- 把窗口拖进刘海，放到某个单元格上。键盘：⌃⌥Space 打开缩略图，⌃⌥←/→/↑/↓ 左右半屏、最大化和还原，⌃⌥F 适配，⌃⌥B/C/R/M/G 整理（加 ⇧ 只作用于最前面的应用），⌃⌥Z 撤销。所有快捷键都可配置。
- **自动整理**（⌃⌥A）：为指针所在显示器上的窗口挑选布局并立即应用（⇧ 只作用于最前面的应用）；用 ⌃⌥Z 撤销。
- **工作区：** 保存每个窗口在每个显示器上的位置，一键恢复，每个工作区还可设置快捷键。恢复时会打开缺失的应用；某个工作区可以在对应的显示器组合连接时自动应用。
- 每次整理在应用前都会预览，并且可以撤销。

</details>

<details>
<summary><b>控制和监视器</b></summary>

- **控制：** 开关（保持唤醒、深色模式、Wi-Fi、桌面图标、隐藏文件）和一次性工具（锁定、关闭显示器、屏幕保护程序、截图、取色器、镜子（摄像头）、清倒废纸篓、推出全部）。保持唤醒可设置时长并显示结束时间；清倒废纸篓前会先询问。
- **监视器：** 左侧以指标显示 CPU、内存、GPU、磁盘、网络和能耗；右侧显示所选指标占用最高的应用（或进程）。可以从列表中退出或强制退出（强制退出前会询问）。仅在标签页打开时采样（每 1 或 2 秒，由你选择）。

</details>

<details>
<summary><b>通知</b>（需手动开启，实验性）</summary>

- 在标签页中按应用分组显示最近的通知，到达时短暂提示，可按应用静音。默认关闭；需要完全磁盘访问权限才能读取（只读）。

</details>

## 安装

Glancy 需要 **macOS 14 Sonoma 或更高版本**，支持 Apple 芯片和 Intel，专为带刘海的 MacBook 设计（没有刘海也能用；见[局限](#局限)）。

### 下载

1. **[下载 Glancy.dmg](https://github.com/giacolaiacomo/glancy/releases/latest/download/Glancy.dmg)**（始终是最新版本），打开后把 **Glancy** 拖到"应用程序"。
2. 打开它。它使用 Developer ID 签名并经过 Apple 公证，所以可以正常打开，更新后权限依然保留。
3. 首次启动时，刘海中会出现一个简短的**权限清单**。每项权限都是可选的：只授予你需要的（[每项权限的用途](#权限)）。

在设置 → 通用中开启**登录时打开**（Launch at login），即可随 Mac 启动。

### Homebrew

```sh
brew trust giacolaiacomo/tap        # 只需一次：新版 Homebrew 在加载第三方 tap 的 cask 之前会先询问
brew install --cask giacolaiacomo/tap/glancy
```

安装的是同一个经过公证的应用。卸载：`brew uninstall --cask glancy`（加上 `--zap` 会同时删除数据和设置）。如果你安装过旧的从源码构建的 formula，请先运行 `brew uninstall glancy`。

### 从源码构建

```sh
git clone https://github.com/giacolaiacomo/glancy.git
cd glancy
./install.sh
```

这会构建 `~/Applications/Glancy.app`，开启**登录时打开**并启动它。更新：`git pull && ./install.sh`。连同数据、设置和权限一起卸载：`./uninstall.sh`。

构建需要 Swift 6.2 工具链（Xcode 26 或其命令行工具：`xcode-select --install`）和 `cmake`（`brew install cmake`）。如果钥匙串中有 "Apple Development" 证书，`scripts/build-app.sh` 会用第一个证书签名，这样重新构建后权限依然保留；否则使用 ad-hoc 签名。可以通过 `GLANCY_SIGN_IDENTITY` 指定。

### 更新

Glancy 使用 [Sparkle](https://sparkle-project.org) 自动更新。有新版本时，面板顶部一行的齿轮旁会出现一个绿色箭头：点击即可查看更新内容并安装（Glancy 会自行重新启动）。**立即检查**（Check now）和**自动检查更新**（Check for updates automatically）开关在设置 → 通用中，命令栏中也有 **Check for Updates**。更新经过签名（EdDSA，由 Sparkle 校验）和公证。Homebrew 知道该应用会自行更新，所以 `brew upgrade` 不会动它；`brew upgrade --cask glancy` 也可以用。

## Agents 设置

### Claude Code

Agents 模块读取一个由小型 Claude Code hook 写入的日志。Glancy 从不修改你的 Claude 设置，所以这一步需要你自己完成：

1. 复制 hook（在本仓库的克隆目录中）：`mkdir -p ~/.claude/hooks && cp hooks/cc-dashboard-event.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/cc-dashboard-event.sh`
2. 在 `~/.claude/settings.json` 中为以下七个事件添加它（与已有的 `hooks` 合并；把 `YOU` 换成你的用户名）：

<details>
<summary><code>settings.json</code></summary>

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

</details>

hook 每个事件向 `~/.claude/hooks/data/cc-dashboard/events.jsonl` 追加一行：时间、事件、会话 ID、工作目录、工具名称、提示的前 200 个字符，以及会话运行在哪个应用中（应用的 bundle id、`TERM_PROGRAM` 和 Claude Code 的入口，这样 VS Code 中的会话会打开 VS Code，终端中的会话会打开终端）。它不输出任何内容，总是以 0 退出，不会阻塞 Claude Code。它需要 `jq`，macOS 15 及以上已自带（macOS 14 上请 `brew install jq`）。同一个 hook 在终端、VS Code 和 Cursor 扩展以及 Claude 应用中都会触发。旧版本的 hook 仍然可用：此时会在你打开刘海时从进程树中找到对应的应用。

### Codex 和 OpenCode

无需设置；每个来源都可以在设置 → Agents 中关闭。

- **Codex**（CLI、Codex 应用、VS Code 扩展）：Glancy 以只读方式跟踪 Codex 已经写在 `~/.codex/sessions/` 中的会话文件。它能看到一轮对话何时运行、完成、失败，或在等待你的回答或批准。点击会在 Codex 应用或 VS Code 中打开会话，或把它的终端调到前台。你的 `config.toml`（及其 `notify` 命令）从不会被改动。
- **OpenCode：** Glancy 以只读方式读取 OpenCode 自己的数据库（`~/.local/share/opencode/opencode.db`），获取工作中 / 已完成 / 失败状态。若还想看到它何时在等待权限确认，在设置 → Agents → OpenCode 中点击 **Install**：它会把 [`hooks/glancy-opencode.js`](hooks/glancy-opencode.js) 复制到 `~/.config/opencode/plugins/glancy.js`（不会编辑你的 `opencode.json`；已有的不同文件会保留为备份）。**Uninstall** 会将其删除。

## 权限

所有权限都是可选的：缺少某项权限时，对应模块只是功能少一些。设置 → 权限中会显示每项的状态和授权按钮。

| 权限 | 用途 | 没有它时 |
|---|---|---|
| **日历** | 下一个会议、Join 按钮、日历标签页 | 不显示日历 |
| **辅助功能** | 拦截 HUD 按键；窗口平铺；跳转到会话的终端；剪贴板捕获 ⌘C 以及选择后粘贴；测量菜单宽度，让左侧翅膀不遮住菜单 | 保留系统 HUD；不能平铺；剪贴板在切换应用或打开刘海时才记录复制；左侧翅膀保持隐藏 |
| **蓝牙** | AirPods 和耳机连接提示及电量 | 没有耳机提示 |
| **通知** | 计时结束时的提醒 | 计时只在刘海中结束 |
| **自动化**（音乐、Spotify） | 针对这两个应用的备用读取方式，仅在主读取方式在你的 macOS 上不可用时使用 | 媒体功能仍通过主读取方式工作 |
| **麦克风** | 语音笔记和麦克风静音快捷键 | 没有语音笔记，不能静音麦克风 |
| **语音识别** | 在本机把语音笔记转写成文字 | 录音只保留音频 |
| **摄像头** | 控制标签页中的镜子 | 没有镜子 |
| **完全磁盘访问权限** | 读取 macOS 的通知数据库，仅在你开启通知模块时 | 通知模块保持关闭 |

## 常见问题

<details>
<summary><b>系统设置里辅助功能已经打开，但 Glancy 说没有权限</b></summary>

这个开关属于一条旧记录（签名不同的早期版本或构建），macOS 已经不再把它和当前应用对应起来。在 Glancy 的设置 → 权限中点击辅助功能旁的 **Allow…**：Glancy 会清除自己的旧记录并重新请求，这样打开开关就能生效。也可以手动处理：在系统设置 → 隐私与安全性 → 辅助功能中选中 Glancy，用 **−** 删除，再用 **+** 重新添加。

</details>

<details>
<summary><b>我看不到 Glancy</b></summary>

它住在刘海里，没有程序坞图标。把指针移到刘海上即可预览，点击打开。在没有刘海的 Mac 上，或合盖接外接显示器的 MacBook 上，它会在主显示器顶部中央显示一个小胶囊；设置 → 通用中的 **Pill on external displays** 会把它加到其他显示器上。

</details>

<details>
<summary><b>在大显示器上文字太小</b></summary>

设置 → 通用 → **大小**（Size）：Normal、Large 或 Extra large。整个面板会随之缩放；如果某个大小放不下屏幕，Glancy 会在该设置下方提示。

</details>

<details>
<summary><b>怎么更新？</b></summary>

什么都不用做：有新版本时，面板中齿轮旁会出现绿色箭头，点击即可安装。想马上检查：设置 → 通用 → **立即检查**（Check now），或命令栏中的 **Check for Updates**。使用 Homebrew 时，`brew upgrade --cask glancy` 也可以。见[更新](#更新)。

</details>

## 隐私

Glancy 没有遥测、没有账户。唯一的常规网络请求是**更新检查**：从本仓库最新的 GitHub release 下载 `appcast.xml`（启动时，之后打开面板时最多每天一次；可在设置 → 通用中关闭）。汇率仅在你于命令栏中输入货币时从欧洲央行获取。其他一切都在本地读取：

- **Claude Code：** 上面的 hook 日志，只读，从末尾读取。Glancy 从不写入它，也从不运行 Claude。
- **Codex：** `~/.codex/sessions/` 中的会话文件，只读（只在内存中保留会话的目录、状态、第一条提示、最后使用的工具和最后一条回复）。
- **OpenCode：** 以只读方式打开它的数据库；如果安装了插件，还有插件写入 `~/Library/Application Support/Glancy/agents/` 的事件日志。
- **日历：** 通过 EventKit 读取你的日程，只保存在内存中。
- **媒体：** 通过 [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)（一个随应用打包、用系统 Perl 运行的小程序）读取系统的正在播放信息；备用方案是对音乐和 Spotify 使用 AppleScript。
- **剪贴板：** 你复制的内容，保存在 `~/Library/Application Support/Glancy/clipboard/`（仅限本人访问），跳过隐藏内容和密码管理器。随时可以清空。
- **笔记和语音笔记：** `~/Library/Application Support/Glancy/notes/` 中的 `.md` 和 `.m4a` 文件；转写在本机进行。
- **通知：** 仅在你开启该模块时，以只读方式打开 macOS 的通知数据库。
- **窗口：** 通过辅助功能读取窗口标题和位置，用于绘制缩略图。除了网格、布局和快捷键外不保存任何内容。

设置保存在 `~/Library/Preferences/ai.glancy.app.plist`；数据（剪贴板、暂存架、笔记、计时器、窗口布局）保存在 `~/Library/Application Support/Glancy/`。`./uninstall.sh` 会全部删除。详见 [SECURITY.md](SECURITY.md)。

## 局限

- **为刘海而生。** 没有刘海时，顶部中央的小胶囊也能用，但这不是它的重点。
- **部分功能需要辅助功能权限**，见[权限](#权限)。
- **窗口平铺取决于各个应用。** 有些应用拒绝缩小到最小尺寸以下，或会自己调整窗口；Glancy 会把这类窗口对齐到单元格边缘，并告诉你哪些没能精确放置。平铺是 Glancy 最新的部分，实际使用的检验比其他部分少。
- **自行构建且没有证书的版本**使用 ad-hoc 签名，每次重新构建都会丢失权限，因为 macOS 把它当作新应用。请在系统设置中重新授权。
- **通知功能是实验性的。** macOS 的通知数据库是私有且无文档的；读取器会检查数据库结构，不认识时会自动关闭。目前只在测试数据上验证过，尚未在各个 macOS 版本上验证。
- **媒体功能**通过 mediaremote-adapter 依赖 macOS 的一个私有框架。如果未来的 macOS 让它失效，Glancy 会退回到只支持音乐和 Spotify。正在播放信息的辅助进程是一个单独的进程，约 5 MB，另计于 Glancy 的约 18 MB。

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

每个模块位于 `Sources/GlancyKit/<Module>/`，实现 `GlancyModule`（启动、停止、可见性、标签页、主页卡片），在 `Modules.swift` 中注册。让 Glancy 保持轻量的规则是：刘海收起时不运行任何定时器、动画或轮询，只有系统事件监听；`scripts/lint.sh` 会强制检查。详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

发布：经过公证的 DMG 由维护者在自己的 Mac 上用 `scripts/make-dmg.sh` 制作，它会生成 `Glancy-x.y.z.dmg`、一个字节完全相同、用于固定下载链接的 `Glancy.dmg`，以及 Sparkle 的 `appcast.xml`；三个文件都会附加到 release。发布 release 还会运行 [release.yml](.github/workflows/release.yml)，从标签构建并检查通用版本应用。

## 参与贡献

欢迎在 [Issues](https://github.com/giacolaiacomo/glancy/issues) 中报告问题和提出想法；附上 `Glancy --diagnose` 的输出会很有帮助。提交 pull request 时，请遵守上面的刘海收起规则，并运行 `swift test` 和 `scripts/lint.sh`。安全问题：见 [SECURITY.md](SECURITY.md)。

## 致谢

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)，作者 Jonas van den Berg 及贡献者（BSD 3-Clause），收录在 `Vendor/` 中，用于读取正在播放的信息。
- [Sparkle](https://sparkle-project.org)（MIT）：应用内更新。
- [MacroVisionKit](https://github.com/TheBoredTeam/MacroVisionKit)（MIT）：检测全屏空间的方法。
- [Tessera](https://github.com/giacolaiacomo/tessera)（MIT）：平铺引擎最初的网格、整理和快捷键逻辑。Rectangle（MIT）为窗口放置的细节提供了参考。

完整声明见 [NOTICE](NOTICE) 和 [Sources/GlancyKit/Tiling/NOTICE.md](Sources/GlancyKit/Tiling/NOTICE.md)。不包含任何 GPL 代码；其他刘海应用仅作为参考阅读。

## 免责声明

Glancy 是一个独立项目，与 Apple 或 Anthropic 无关，也未获得其认可。Claude 和 Claude Code 是 Anthropic, PBC 的商标。

## 许可证

[MIT](LICENSE)

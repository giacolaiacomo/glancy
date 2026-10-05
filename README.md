<p align="center">
  <img src="docs/hero.jpg" alt="Glancy: the MacBook notch as a live surface for Claude Code agents, meetings, music, clipboard and windows">
</p>

<p align="center">
  <a href="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml"><img src="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, no dependencies">
  <img src="https://img.shields.io/badge/RAM-~19%20MB-2ea44f" alt="~19 MB RAM">
  <img src="https://img.shields.io/badge/telemetry-none-2ea44f" alt="No telemetry">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

<p align="center"><sub><b>English</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a></sub></p>

# Glancy

**Your MacBook's notch, put to work.** Glancy turns the notch into a small live surface: which Claude Code sessions are working or waiting for you, your next meeting with a Join button, what's playing, a timer, a file shelf, your clipboard history and a window tiler. Hover to peek, click to open.

**Light by design.** About 19 MB of RAM and 0 CPU-seconds a minute at idle, with no timers or polling while the notch is closed: everything is driven by system events. Nothing leaves your Mac.

<p align="center">
  <img src="docs/screens.jpg" alt="Home, Agents, Calendar, Media, Clipboard and Windows tabs">
</p>

<sub>Images use made-up demo data.</sub>

## Features

**The notch**
- **Closed:** exactly the hardware notch. When something is happening, "wings" grow either side with the most important live activity: an agent waiting for you, a meeting about to start, a timer, the volume HUD, what's playing.
- **Peek:** hover for a hint, or a short drop-down when something happens (a session finished, AirPods connected, a new track).
- **Open:** click for the full panel with tabs. Esc, a click outside or moving away closes it.
- Wings never sit on top of your menus or status items. On displays without a notch, an optional small pill.
- Hidden from screenshots and screen sharing (a setting, on by default). English and Italian.

**Claude Code agents**
- Every live session as a dot in the wings: working, **waiting for permission** (amber), done, failed.
- The Agents tab: project, state, time in that state, last tool and the last prompt, for every session.
- Click a session to bring its terminal forward (Terminal, iTerm, Ghostty, Warp, VS Code). ⌥-click to bring it forward and tile it.
- **Lay out sessions** tiles all your Claude terminals at once, previewed first and undoable.
- Reads a small hook log (see [Claude Code setup](#claude-code-setup)); Glancy never talks to Claude itself.

**Calendar**
- Your next meeting, with a countdown and a **Join** button for Zoom, Google Meet, Teams, Webex, Whereby and FaceTime links.
- Today and tomorrow in the Calendar tab, in your calendars' colours. Declined events hidden; pick which calendars count.

**Media**
- What's playing in **any** player, browsers included: artwork, progress, play/pause, previous/next, the output device.
- Artwork tint in the wings, a peek on track change.

**HUD, battery and AirPods**
- Replaces the volume, brightness and keyboard-backlight overlays with a quiet one in the notch (⌥⇧ for quarter steps).
- Charging, unplugging, low battery and Low Power Mode as a brief activity.
- AirPods and other headphones as they connect, with left, right and case battery.

**Timer and Pomodoro**
- 5, 15, 25, 50 minutes or custom, and a 25/5 Pomodoro cycle. A ring in the wings, an alert at the end; survives a relaunch.

**Shelf**
- Drag files onto the notch to park them, drag them out anywhere later. AirDrop, Share and Quick Look from the shelf. Up to 24 items, kept across relaunches.

**Clipboard history**
- The last 60 copies: text, rich text, links, images and files, with search and pins. ⌥⌘V opens it.
- Skips passwords and anything apps mark as concealed or transient, plus password managers. Pause, per-app exclusions and Clear.

**Windows**
- A live map of the display in the notch: hover cells to preview on the real screen, click to place.
- Pick a grid (2×1 up to anything), arrange the whole screen, one app, or exactly the windows you pick (⌘-click, in order). Strategies: Balanced, one per cell, columns, rows, master + stack.
- Drag a window into the notch to drop it on a cell. Keyboard: ⌃⌥Space opens the map, ⌃⌥←/→/↑/↓ halves, maximise and restore, ⌃⌥F fit, ⌃⌥B/C/R/M/G arrange (add ⇧ for the front app only), ⌃⌥Z undo. Every shortcut is configurable.
- Every arrangement is previewed before it's applied and can be undone.

**Notifications** (opt-in, experimental)
- The last notifications in a tab, grouped by app, with a peek as they arrive and a per-app mute list. Off by default; needs Full Disk Access to read them (read-only).

## Install

Glancy needs macOS 14 or later. It runs on Apple Silicon and Intel and is made for MacBooks with a notch; see [Limitations](#limitations).

**Download**

1. Download `Glancy-x.y.z.zip` from the [latest release](https://github.com/giacolaiacomo/glancy/releases/latest), unzip it and drag **Glancy** to Applications.
2. Open it. Glancy isn't signed with a paid Apple Developer ID, so the first time macOS says it can't verify it: click **Done**, then open **System Settings → Privacy & Security** and click **Open Anyway**. Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Glancy.app`.
3. The first launch opens a short permission checklist in the notch. Every permission is optional.

The release zip is built from the tagged source by [GitHub Actions](.github/workflows/release.yml), so you can check exactly what went into it. It is ad-hoc signed, which has one catch: macOS treats each new version as a new app, so after an update you may have to allow Accessibility and the others again. Building it yourself with an Apple Development certificate avoids that (see below).

**Homebrew** (builds from source)

```sh
brew install giacolaiacomo/tap/glancy
brew services start glancy     # start now and at every login
```

To update: `brew upgrade glancy`. To remove it: `brew services stop glancy && brew uninstall glancy`.

**From source**

```sh
git clone https://github.com/giacolaiacomo/glancy.git
cd glancy
./install.sh
```

This builds `~/Applications/Glancy.app`, turns on **Open at login** and starts it. To update: `git pull && ./install.sh`. To remove it, with its data, settings and permissions: `./uninstall.sh`.

Building needs the Swift 6.2 toolchain (Xcode 26 or its Command Line Tools: `xcode-select --install`) and `cmake` (`brew install cmake`). `scripts/build-app.sh` signs with the first "Apple Development" certificate in your keychain if you have one, which keeps your permissions across rebuilds; otherwise it signs ad-hoc. Set `GLANCY_SIGN_IDENTITY` to choose.

## Claude Code setup

The Agents module reads a log written by a tiny Claude Code hook. Glancy never edits your Claude settings, so this step is yours:

1. Copy the hook: `mkdir -p ~/.claude/hooks && cp hooks/cc-dashboard-event.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/cc-dashboard-event.sh` (from a clone of this repo).
2. Add it to `~/.claude/settings.json` for these seven events (merge with any `hooks` you already have; replace `YOU` with your user name):

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

The hook appends one line per event to `~/.claude/hooks/data/cc-dashboard/events.jsonl`: time, event, session id, working folder, tool name, the first 200 characters of your prompt, and which app the session runs in (the app's bundle id, `TERM_PROGRAM` and Claude Code's entry point, so a session in VS Code opens VS Code and one in Terminal opens Terminal). It prints nothing, always exits 0 and can't block Claude Code. It needs `jq`, which macOS 15 and later include (`brew install jq` on macOS 14). New sessions show up in the notch as soon as they start. The same hook fires in the terminal, in the VS Code and Cursor extensions and in the Claude app. An older copy of the hook still works: the app is then found from the process tree when you open the notch.

### Codex and OpenCode

Nothing to set up; each source can be turned off in Settings → Agents.

- **Codex** (CLI, Codex app, VS Code extension): Glancy follows the session files Codex already writes in `~/.codex/sessions/`, read-only. It sees when a turn runs, finishes, fails, or waits for your answer or approval. A click opens the session in the Codex app, in VS Code, or brings its terminal forward. Your `config.toml` (and its `notify` command) is never touched.
- **OpenCode**: Glancy reads OpenCode's own database (`~/.local/share/opencode/opencode.db`, read-only) for working / done / failed. To also see when it waits for a permission, click **Install** in Settings → Agents → OpenCode: it copies [`hooks/glancy-opencode.js`](hooks/glancy-opencode.js) to `~/.config/opencode/plugins/glancy.js` (your `opencode.json` is not edited; a different file already there is kept as a backup). **Uninstall** removes it.

## Permissions

Every permission is optional: without one, its module just does less. Settings → Permissions shows each one's state with a button to grant it.

| Permission | What it enables | Without it |
|---|---|---|
| **Calendar** | Next meeting, Join button, Calendar tab | No calendar |
| **Accessibility** | HUD key interception; window tiling; jumping to a session's terminal; ⌘C capture for the clipboard and paste-after-choosing; measuring the menus so the left wing never covers them | System HUD stays; no tiling; clipboard catches copies when you switch apps or open the notch; the left wing stays hidden |
| **Bluetooth** | AirPods and headphones connecting, with battery | No headphone peeks |
| **Notifications** | The alert when a timer ends | Timer ends silently in the notch |
| **Automation** (Music, Spotify) | A fallback reader for those two apps, used only if the main now-playing reader doesn't work on your macOS | Media still works through the main reader |
| **Full Disk Access** | Reading macOS's notification database, only if you turn on the Notifications module | Notifications module stays off |

## Privacy

Glancy makes **no network requests**, has no telemetry, no account and no update check. What it reads, all locally:

- **Claude Code:** the hook log above, read-only, from the end. Glancy never writes to it and never runs Claude.
- **Codex:** the session files in `~/.codex/sessions/`, read-only (only the session's folder, state, first prompt, last tool and last reply are kept, in memory).
- **OpenCode:** its database, opened read-only; and, if you install the plugin, the event log it writes to `~/Library/Application Support/Glancy/agents/`.
- **Calendar:** your events through EventKit, in memory.
- **Media:** the system's now-playing information through [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), a small helper (bundled, run with the system Perl) that prints what's playing; or AppleScript for Music and Spotify as a fallback.
- **Clipboard:** what you copy, kept in `~/Library/Application Support/Glancy/clipboard/` (owner-only permissions), skipping concealed items and password managers. Clear it any time.
- **Notifications:** only if you turn the module on, macOS's notification database, opened read-only.
- **Windows:** window titles and frames through Accessibility, to draw the map. Nothing is stored except your grids, layouts and shortcuts.

Settings live in `~/Library/Preferences/ai.glancy.app.plist`; data (clipboard, shelf, timer, window layouts) in `~/Library/Application Support/Glancy/`. `./uninstall.sh` removes all of it. See [SECURITY.md](SECURITY.md).

## Requirements

- macOS 14 Sonoma or later. Developed on macOS 26 with a 14" MacBook Pro and an external ultrawide.
- A MacBook with a notch for the full experience; other displays get an optional pill.
- For Agents: Claude Code with the hook above.

## Limitations

- **Made for the notch.** On Macs and displays without one, Glancy shows a small pill at the top centre instead (off by default); it works, but it's not the point.
- **Some features need Accessibility,** see [Permissions](#permissions).
- **Window tiling depends on each app.** Some apps refuse sizes below their minimum or animate their own frames; Glancy re-anchors such windows to the cell's edges and tells you which ones didn't fit exactly. Tiling is the newest part of Glancy and has seen less real-world use than the rest.
- **Ad-hoc signed builds** (the release zip, or building without a certificate) lose their permissions on every update: macOS sees a new app. Allow them again in System Settings.
- **Notifications are experimental.** macOS's notification database is private and undocumented; the reader checks the schema and turns itself off if it doesn't recognise it. It has only been checked against fixtures, not across macOS versions.
- **Media** relies on a private macOS framework through mediaremote-adapter. If a future macOS breaks it, Glancy falls back to Music and Spotify only.
- The now-playing helper is a separate process of about 5 MB, on top of Glancy's ~19 MB.

## Development

```sh
swift build && swift test                      # 0 warnings expected
scripts/lint.sh                                # no timers, polling or mouse-moved monitors while collapsed
.build/debug/Glancy --self-test                # headless checks of every module (also run in CI)
scripts/render.sh                              # every surface state to PNG in render-out/ (your real data; --it for Italian)
scripts/screenshots.sh                         # regenerate the README images (made-up demo data)
scripts/build-app.sh build/Glancy.app          # the app bundle (UNIVERSAL=1 for Apple Silicon + Intel)
scripts/footprint.sh                           # memory and CPU of an idle run
Glancy --diagnose                              # state of the running app (modules, displays, resources)
```

Each module lives in `Sources/GlancyKit/<Module>/` and implements `GlancyModule` (start, stop, visibility, tab, Home card); `Modules.swift` registers them. The rule that keeps Glancy light: a closed notch runs no timers, animations or polling, only system event observers. `scripts/lint.sh` enforces it. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Releases: publishing a GitHub release runs [release.yml](.github/workflows/release.yml), which builds the universal app and attaches the zip.

## Credits

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg and contributors (BSD 3-Clause), vendored in `Vendor/`: the now-playing reader.
- [MacroVisionKit](https://github.com/TheBoredTeam/MacroVisionKit) (MIT): the technique for detecting full-screen spaces.
- [Tessera](https://github.com/giacolaiacomo/tessera) (MIT): the grid, arrangement and hotkey logic the tiling engine started from. Rectangle (MIT) informed the window-placement details.

Full notices in [NOTICE](NOTICE) and [Sources/GlancyKit/Tiling/NOTICE.md](Sources/GlancyKit/Tiling/NOTICE.md). No GPL code is included; other notch apps were read as reference only.

## Disclaimer

Glancy is an independent project, not affiliated with or endorsed by Apple or Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.

## License

[MIT](LICENSE)

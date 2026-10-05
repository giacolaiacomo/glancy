# Security & privacy

Glancy is a notch app that sees a fair amount of what happens on your Mac: your calendar, what you
copy, what's playing, your window titles and, if you let it, your notifications. It is built so that
none of that leaves your Mac or ends up anywhere you didn't expect.

## No network

Glancy makes no network requests at all: no telemetry, no crash reporting, no update check, no
account. Meeting links open in your browser or meeting app only when you click **Join**.

## What it reads, and how

| Source | How | Stored |
|---|---|---|
| Claude Code hook log | `~/.claude/hooks/data/cc-dashboard/events.jsonl`, read-only from the end with a file-system event source. Glancy never writes to it, never edits `~/.claude/settings.json` and never runs Claude. | Nothing; sessions live in memory |
| Calendar | EventKit, after you allow it. | Nothing; only which calendars to include |
| Now playing | The bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3), run with `/usr/bin/perl`, prints the system's now-playing information; playback commands go to the same system service. Fallback for Music and Spotify: AppleScript, after you allow Automation. | Nothing |
| Clipboard | The pasteboard, checked only after ⌘C/⌘X (a listen-only event tap, with Accessibility), when you switch apps, or when you open the notch. No polling. Items marked concealed, transient or auto-generated, and copies from password managers (1Password, Bitwarden, Keychain Access, Passwords, LastPass, Dashlane) are never read. | `~/Library/Application Support/Glancy/clipboard/`, folder readable by your user only; images downsampled. Pause, per-app exclusions and Clear in Settings |
| Shelf | Files you drop on the notch, as bookmarks. | `~/Library/Application Support/Glancy/` |
| Windows | Window titles and frames through Accessibility, to draw the map and move windows you ask it to move. | Grids, saved layouts and shortcuts only |
| HUD | Volume, brightness and keyboard-backlight keys through an event tap (Accessibility), which only handles those keys. | Nothing |
| Battery, Bluetooth | IOKit power sources; Bluetooth connect events; `system_profiler SPBluetoothDataType` once when headphones connect, for their battery. | Nothing |
| Notifications (opt-in, off by default) | macOS's notification database, opened read-only (`SQLITE_OPEN_READONLY`), only with Full Disk Access and only while the module is on. | Nothing; the last 20 in memory |

Settings are in `~/Library/Preferences/ai.glancy.app.plist`. `./uninstall.sh` removes the app, its
login item, `~/Library/Application Support/Glancy`, its logs and caches, its settings, and resets the
permissions you granted it.

## Builds

The release zip is built by GitHub Actions ([release.yml](.github/workflows/release.yml)) from the
tagged source, with the same `scripts/build-app.sh` that Homebrew and `install.sh` use, and checked
with `--self-test` before it's attached. It is ad-hoc signed, not notarized. If you'd rather not run
a binary you didn't build, use Homebrew or `./install.sh`, which build from source on your Mac.

## Reporting a problem

Please open an issue. For something you'd rather not post publicly, open an issue asking for a
private contact and it will be arranged.

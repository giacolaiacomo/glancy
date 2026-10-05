# Changelog

## 0.1.0 — 2026-10-05

First public release.

- **The notch as a live surface:** closed, it is exactly the hardware notch; wings show the most important live activity; hover peeks, click opens a tabbed panel. Wings stay clear of menus and status items. Optional pill on displays without a notch. Hidden from screen recordings by default.
- **Claude Code agents:** every session's state from a hook log (working, waiting for permission, done, failed), a board with the last tool and prompt, jump to a session's terminal, and "Lay out sessions" to tile them all (previewed, undoable). The hook is in `hooks/`.
- **Calendar:** next meeting with a countdown and a Join button (Zoom, Meet, Teams, Webex, Whereby, FaceTime); today and tomorrow.
- **Media:** any player, browsers included, through the bundled mediaremote-adapter; artwork, progress, controls, output device. Music and Spotify fallback.
- **HUD:** volume, brightness and keyboard backlight in the notch. **Battery and AirPods:** charging, low battery, headphones with battery.
- **Timer and Pomodoro**, **Shelf** (drag files to the notch), **Clipboard history** (60 items, search, pins, ⌥⌘V, skips concealed items and password managers).
- **Windows:** a live map of the display, grids, arrange strategies (Balanced, one per cell, columns, rows, master + stack) for the screen, one app or the windows you pick, drag-to-notch, keyboard shortcuts, preview before every change, undo.
- **Notifications** (opt-in, experimental): the last notifications from macOS's database, read-only, with Full Disk Access.
- Settings inside the panel, a first-run permission checklist, English and Italian.
- About 19 MB of RAM and 0 CPU-seconds a minute at idle; no network requests, no telemetry.
- `Glancy --self-test` (headless checks, run in CI), `--diagnose`, `--login-item on|off|status`; `install.sh` / `uninstall.sh`; Homebrew formula; universal release zip built by GitHub Actions.

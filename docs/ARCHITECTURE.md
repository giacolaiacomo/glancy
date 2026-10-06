# Architecture

A short map for contributors. Glancy is one SwiftPM package. Its only third-party dependency is [Sparkle 2](https://sparkle-project.org)
(in-app updates), embedded by `scripts/build-app.sh` in `Contents/Frameworks`.

```
Sources/Glancy/            the executable: calls GlancyApp.run()
Sources/GlancyKit/         everything else
  App/                     entry point, AppDelegate, module registry, --self-test, demo data
  Surface/                 the notch: geometry, panel, shape, states, gestures, multi-display manager
  Settings/                settings pages (inside the panel), permissions, launch at login
  Support/                 theme, diagnostics (--diagnose), child-process registry, watchdog
  Updates/                 Sparkle behind a small driver: when to check (launch, panel open ≤ 1/day), found update
  Agents/ Calendar/ Media/ HUD/ Power/ Timer/ Shelf/ Clipboard/ Windows/ Notifications/
                           one folder per module
  Tiling/                  the window engine used by Windows: registry, placer, planner, history
Sources/glancy-render/     renders every surface state to PNG off-screen (--demo: made-up data)
Vendor/mediaremote-adapter BSD-3 now-playing helper, built with cmake and bundled in the app
hooks/                     the Claude Code hook the Agents module reads
scripts/                   build-app.sh, make-dmg.sh (+ make-appcast.sh), update-e2e.sh, lint.sh, render.sh,
                           screenshots.sh, footprint.sh, ram-lab.sh, soak.sh, leaks.sh
```

## Modules

Each module implements `GlancyModule` (`App/Contracts.swift`):

- `start(hub:)` / `stop()`: begin and end event-driven observation. `stop()` must leave nothing
  running; tests and `--self-test` check this with `ResourceCensus`.
- `visibilityChanged(_:)`: collapsed, peeking, expanded on a tab, or hidden (sleep, lock, full screen).
  Periodic work (a progress bar, a pulse) runs only while visible.
- `tab` and `homeCard()`: SwiftUI views, built only while the panel is open.

Modules publish to the `ActivityHub`: a `LiveActivity` for the wings (highest priority wins), a
`PeekEvent` for the short drop-down, or a request to open the panel on their tab.

## The zero-idle rule

A closed notch must cost nothing: no `Timer`, `TimelineView`, polling loop, repeating animation or
mouse-moved monitor. Everything starts from a system event: file-system sources, EventKit change
notifications, IOKit power sources, CoreAudio listeners, distributed notifications, Accessibility
observers. `scripts/lint.sh` fails the build on the usual offenders; `scripts/footprint.sh` measures
memory, CPU and wake-ups of an idle run.

## Windows

The tiling engine keeps one thread per app for Accessibility calls, so the main thread never waits
on a slow app. Every action is planned first (`ArrangePlanner`), drawn as a preview, then committed;
each placement reports whether the window landed exactly, sized itself, or refused. `TilingHistory`
makes every commit undoable. A commit that places chosen windows (a layout, a strategy, a
workspace you restore) then raises the ones that landed above every other window, in plan order
with the first one frontmost and its app activated (`TilingEngine.raise`); undo, the frontmost-window
hotkeys and the automatic display-connect workspace never raise. Tests run against `SampleWindowsBackend`, a synthetic two-display desk,
so no real window is ever moved by a test.

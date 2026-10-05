# Tiling — third-party notices

Code in this folder adapts the following MIT-licensed projects. Each is used under the MIT
License; their copyright notices are reproduced here as that license requires.

| Project | What was adapted | Where |
|---|---|---|
| **Tessera** — Copyright (c) 2026 Gianluca Colaiacomo (MIT) | `GridSpec`, `CellRect`, `Geometry`, partition strategies, minimum-travel pairing, `largestRect`, `bestGrid`, lenient decoding, Carbon hotkey manager, GeometryTests | `Grid.swift`, `Arrange.swift`, `TilingConfig.swift`, `Hotkeys.swift`, `Tests/GlancyKitTests/TilingGeometryTests.swift` |
| **AeroSpace** — Copyright (c) 2023 Nikita Bobko (MIT) | One thread + run loop per app; size→position→size with the EUI toggle; window classification heuristics (`isWindowHeuristic`, `isDialogHeuristic`) and the bundle IDs they special-case; reconcile-on-notification; global left-mouse-up refresh | `AppHandle.swift`, `WindowClassifier.swift`, `WindowRegistry.swift` |
| **Rectangle** — Copyright (c) 2019-2026 Ryan Hanson, based on Spectacle, Copyright (c) 2017 Eric Czarny (MIT) | Enhanced-UI restore policy and the Chromium-family bundle list; `_AXUIElementGetWindow` and its fallbacks; Stage Manager strip detection (`StageUtil`) and the 190 pt default | `Placer.swift`, `AXSupport.swift`, `AppHandle.swift`, `ScreenSpace.swift` |
| **Amethyst** — Copyright (c) 2015 Ian Ynda-Hummel (MIT) | Quadratic backoff when registering observers on apps that are not ready; nil-title windows treated as provisional | `WindowRegistry.swift`, `WindowClassifier.swift` |

**Loop** (GPL-3.0) was read for technique only — edge re-anchoring (`anchoredFrame`), push-inside,
one cancellable job per window, the preview-then-commit flow. No Loop code was copied;
`PlacementMath.swift` is an independent implementation.

---

MIT License (applies to each project above, with its own copyright line)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

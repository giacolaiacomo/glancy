# mediaremote-adapter (vendored)

- Upstream: https://github.com/ungive/mediaremote-adapter
- Commit: `29718252613a5b0e210bdc64de0bd944ab379706` (2026-09-30, "Add convenience script for development")
- License: BSD 3-Clause, see `LICENSE` (Copyright (c) 2025, Jonas van den Berg and contributors).
- Vendored: `CMakeLists.txt`, `LICENSE`, `README.md`, `bin/`, `include/`, `src/` — unmodified.
  Not vendored: `.vscode/`, `scripts/` (dev helpers), `Makefile` (badge tooling).

Built by `scripts/build-app.sh` with CMake (`brew install cmake`) into `build/mediaremote-adapter/`
and bundled, not linked:

- `Contents/Resources/mediaremote-adapter.pl` — run by Apple-signed `/usr/bin/perl` (entitled to MediaRemote)
- `Contents/Frameworks/MediaRemoteAdapter.framework` — loaded by perl, never by Glancy
- `Contents/MacOS/MediaRemoteAdapterTestClient` — health check (`… test` exits 0 when the adapter works)

All three are signed with the app's identity before the app itself (boring.notch #998).
To update: replace these files with a newer upstream checkout and update the commit above.

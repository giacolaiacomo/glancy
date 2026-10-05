#!/bin/bash
# Renders every surface state to PNG at 2× into render-out/ (off-screen, no live notch involved).
# Usage: scripts/render.sh [--it]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product glancy-render
mkdir -p render-out
"$(swift build --show-bin-path)/glancy-render" render-out "$@"
echo "→ $ROOT/render-out"

#!/bin/bash
# Prints CFBundleVersion for a marketing version: MAJOR*1000000 + MINOR*1000 + PATCH
# (0.2.2 → 2002, 0.3.0 → 3000, 1.0.0 → 1000000). A plain integer that grows with every release, so
# Sparkle (sparkle:version) and Launch Services always see the newer build as newer. Releases before
# 0.3 used the commit count (≤ 51), which every derived number exceeds.
#
#   scripts/build-number.sh 0.3.0      → 3000
set -euo pipefail
v="${1:?usage: build-number.sh MAJOR.MINOR.PATCH}"
if ! [[ "$v" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
  echo "build-number: '$v' is not MAJOR.MINOR[.PATCH]" >&2; exit 2
fi
major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]})); patch=$((10#${BASH_REMATCH[4]:-0}))
if (( minor > 999 || patch > 999 )); then
  echo "build-number: minor and patch must be ≤ 999 ($v)" >&2; exit 2
fi
echo $(( major * 1000000 + minor * 1000 + patch ))

#!/bin/bash
# Takes the screenshots of the README, into docs/images.
#
#   scripts/screenshots.sh
#
# The pictures are staged with the app's demo mode (see OpenClipboard/Support/Demo.swift):
# sample clips in a throwaway history, in front of the default macOS wallpaper. Nothing
# of what is on the screen or the pasteboard of the Mac that takes them can get in.
# While it runs, the wallpaper covers the main display for a few seconds at a time.
#
# Needs a built app (APP, by default the Release build in build/DerivedData) and the
# Screen Recording permission for the terminal it is run from.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${APP:-build/DerivedData/Build/Products/Release/OpenClipboard.app}
BINARY="$APP/Contents/MacOS/OpenClipboard"
OUT=docs/images
[[ -x "$BINARY" ]] || { echo "!! build the app first: $APP is missing" >&2; exit 1; }
mkdir -p "$OUT"

# The size of the main display in points, which is what screencapture measures in.
read -r WIDTH HEIGHT < <(swift -e 'import AppKit; let f = NSScreen.main!.frame; print(Int(f.width), Int(f.height))')

# shot NAME SECONDS HEIGHT ARGUMENTS…: stages a scene with the demo's arguments, waits,
# and saves the bottom HEIGHT points of the screen as docs/images/NAME.jpg.
shot() {
    local name=$1 seconds=$2 height=$3
    shift 3
    "$BINARY" --demo --passive --trusted --backdrop --show "$@" > /dev/null 2>&1 &
    local pid=$!
    sleep "$seconds"
    screencapture -x -R "0,$((HEIGHT - height)),$WIDTH,$height" "$OUT/$name.png"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sips -s format jpeg -s formatOptions 86 -Z 2600 "$OUT/$name.png" --out "$OUT/$name.jpg" > /dev/null
    rm "$OUT/$name.png"
    echo "==> $OUT/$name.jpg"
}

shot hero-dark 3.4 560 --appearance dark
shot hero-light 3.4 560 --appearance light
shot preview-dark 4.0 720 --appearance dark --keys "right right right space"
shot preview-light 4.0 720 --appearance light --keys "right right right space"
shot search-light 3.8 560 --appearance light --search "launch"
shot quick-paste-dark 3.8 560 --appearance dark --keys "cmd"
shot pinned-light 3.8 560 --appearance light --filter pinned

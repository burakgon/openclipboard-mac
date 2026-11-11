#!/bin/bash
# Tries out updating, from finding a new version to running it, without publishing anything.
#
#   scripts/test-update.sh          the default: updates install themselves
#   scripts/test-update.sh --ask    as with "Download and install them automatically" off
#
# Makes a throwaway copy of the built app that has a bundle identifier, an update key and
# an update feed of its own, serves a version 9.9.9 of it from this Mac, and opens the
# copy. The copy shares nothing with an installed OpenClipboard: it has its own settings
# and its own, empty history, it records nothing, and its shortcut is ⌃⌥⌘V.
#
# What to look for is printed while it runs. Everything is removed again at the end.
#
# Needs a built app (APP, by default the Release build in build/DerivedData).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${APP:-build/DerivedData/Build/Products/Release/OpenClipboard.app}
PORT=${PORT:-18733}
ID=com.burakgon.OpenClipboard.updatetest
SIGN_UPDATE=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$APP" ]] || { echo "!! build the app first: $APP is missing" >&2; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "!! $SIGN_UPDATE is missing: build with -derivedDataPath build/DerivedData" >&2; exit 1; }

ASK=false
[[ "${1:-}" == "--ask" ]] && ASK=true

WORK=$(mktemp -d)
COPY="$WORK/OpenClipboard.app"
SERVER=

version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$COPY/Contents/Info.plist" 2> /dev/null || true; }
is_updated() { [[ "$(version)" == 9.9.9 ]]; }
is_running() { pgrep -f "$COPY/Contents/MacOS/OpenClipboard" > /dev/null; }
is_gone() { ! pgrep -f "$COPY/Contents" > /dev/null; }

# waits SECONDS COMMAND…: until the command succeeds, for at most that long.
waits() {
    local tries=$(($1 * 2))
    shift
    for ((i = 0; i < tries; i++)); do
        "$@" > /dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

cleanup() {
    # Asked to quit the way macOS asks, so that Sparkle's installer finishes and goes too.
    if is_running; then
        osascript -e "tell application id \"$ID\" to quit" > /dev/null 2>&1 || true
        waits 10 is_gone || pkill -f "$COPY/Contents" || true
    fi
    [[ -n "$SERVER" ]] && kill "$SERVER" 2> /dev/null || true
    "$LSREGISTER" -u "$COPY" > /dev/null 2>&1 || true
    defaults delete "$ID" > /dev/null 2>&1 || true
    rm -rf "$WORK" "$HOME/Library/Application Support/$ID" "$HOME/Library/Caches/$ID" \
        "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/Preferences/$ID.plist"
    echo "==> Removed the copy and everything it kept"
}
trap cleanup EXIT

# A key pair for this run only: the copy trusts updates signed with it, and nothing else does.
read -r PRIVATE_KEY PUBLIC_KEY < <(swift -e '
    import CryptoKit
    import Foundation
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
')
echo "$PRIVATE_KEY" > "$WORK/private.key"

# make_copy DESTINATION VERSION BUILD
make_copy() {
    ditto "$APP" "$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" \
        -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" \
        -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" \
        -c "Set :SUPublicEDKey $PUBLIC_KEY" \
        -c "Add :NSAppTransportSecurity dict" \
        -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$1/Contents/Info.plist"
    codesign --force --deep --sign - "$1" 2> /dev/null
}

echo "==> Making the copy and the update for it"
OLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p "$WORK/feed" "$WORK/new"
make_copy "$COPY" "$OLD" 1
make_copy "$WORK/new/OpenClipboard.app" 9.9.9 999
ditto -c -k --sequesterRsrc --keepParent "$WORK/new/OpenClipboard.app" "$WORK/feed/OpenClipboard-9.9.9.zip"
rm -rf "$WORK/new"
SIGNATURE=$("$SIGN_UPDATE" --ed-key-file "$WORK/private.key" "$WORK/feed/OpenClipboard-9.9.9.zip")
cat > "$WORK/feed/appcast.xml" << EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>OpenClipboard</title>
        <item>
            <title>9.9.9</title>
            <sparkle:version>999</sparkle:version>
            <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
            <enclosure url="http://127.0.0.1:$PORT/OpenClipboard-9.9.9.zip" type="application/octet-stream" $SIGNATURE/>
        </item>
    </channel>
</rss>
EOF

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/feed" > "$WORK/server.log" 2>&1 &
SERVER=$!
disown "$SERVER"
# Asking for the folder, not for the appcast: the log is later read for the copy's own requests.
waits 5 curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" || { echo "!! could not serve the feed on port $PORT" >&2; exit 1; }

# The copy's settings: no welcome window, nothing recorded, a shortcut of its own (⌃⌥⌘V).
defaults delete "$ID" > /dev/null 2>&1 || true
defaults write "$ID" hasCompletedOnboarding -bool true
defaults write "$ID" isPaused -bool true
defaults write "$ID" hotKey -data "$(printf '{"keyCode":9,"modifiers":1835008}' | xxd -p | tr -d '\n')"
if $ASK; then
    defaults write "$ID" SUAutomaticallyUpdate -bool false
    # A check that is due 20 seconds from now. One at the very moment the app opens would
    # make Sparkle show its window by itself, which is not what an app that has been
    # running for days does.
    defaults write "$ID" SUHasLaunchedBefore -bool true
    defaults write "$ID" SULastCheckTime -date "$(date -u -v-86380S '+%Y-%m-%d %H:%M:%S +0000')"
fi

open -n -g "$COPY"
waits 10 is_running || { echo "!! the copy did not start" >&2; exit 1; }
echo "==> The copy of $OLD is running. Its icon is in the menu bar, dimmed: it records nothing."

if $ASK; then
    echo "    Waiting for its check for updates, due in about 20 seconds…"
    waits 90 grep -q "appcast.xml" "$WORK/server.log" || { echo "!! it never asked for the feed" >&2; exit 1; }
    sleep 2
    if grep -q "OpenClipboard-9.9.9.zip" "$WORK/server.log"; then
        echo "!! it downloaded the update, which it should not do before being told to" >&2
        exit 1
    fi
    echo "==> It found 9.9.9 and did not download it. No window may have opened."
    echo "    The icon carries a dot. Press ⌃⌥⌘V and click Update Available, then install."
else
    waits 60 grep -q "OpenClipboard-9.9.9.zip" "$WORK/server.log" || { echo "!! it did not download the update" >&2; exit 1; }
    echo "==> It found 9.9.9 and downloaded it by itself. The icon carries a dot."
    echo "    Press ⌃⌥⌘V and click Restart to Update, or quit the copy from its menu:"
    echo "    either way 9.9.9 is installed."
fi

echo "    Waiting for the new version, for up to ten minutes (⌃C gives up)…"
waits 600 is_updated || { echo "!! still $(version)" >&2; exit 1; }
codesign --verify --deep --strict "$COPY" || { echo "!! the installed update is damaged" >&2; exit 1; }
sleep 2
if is_running; then
    echo "==> Updated: the copy is 9.9.9 and running again"
else
    echo "==> Updated: the copy is 9.9.9 and not running, as after quitting it"
fi
if [[ -t 0 ]]; then
    read -r -p "    Press Return to remove the copy. " _
fi

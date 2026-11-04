#!/usr/bin/env bash
# Build Orbit, assemble Orbit.app, ad-hoc sign it, and relaunch it.
# Usage: scripts/run.sh [debug|release]   (default: debug)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="${1:-debug}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "usage: scripts/run.sh [debug|release]" >&2; exit 2 ;;
esac

echo "==> Building ($CONFIG)"
if ! swift build -c "$CONFIG"; then
    echo "==> Build failed; existing Orbit.app left untouched." >&2
    exit 1
fi

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXE="$BIN_DIR/Orbit"
[[ -x "$EXE" ]] || { echo "==> Executable not found at $EXE" >&2; exit 1; }

# The bundle lives inside .build so it is only ever rebuilt, never anywhere else.
APP="$ROOT/.build/Orbit.app"
APP_EXE="$APP/Contents/MacOS/Orbit"

echo "==> Stopping running Orbit (this build only)"
# Match on the full bundle path so no unrelated process named "Orbit" is touched.
# Orbit handles SIGTERM by running normal NSApplication termination.
if pkill -TERM -f "^$APP_EXE" 2>/dev/null; then
    for _ in {1..50}; do
        pgrep -f "^$APP_EXE" >/dev/null || break
        sleep 0.1
    done
    if pgrep -f "^$APP_EXE" >/dev/null; then
        echo "==> Orbit did not quit within 5s; forcing it." >&2
        pkill -KILL -f "^$APP_EXE" || true
        sleep 0.5
    fi
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP_EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify "$APP"

echo "==> Launching"
open "$APP"

#!/usr/bin/env bash
# Installs Orbit's Brave native messaging helper for the current user, or
# removes it with --uninstall. Orbit never runs this itself. Safe to run again.
#
# Where Brave looks (macOS): Brave overrides Chromium's per-user native
# messaging folder at startup (brave_main_delegate) to Chrome's:
#   ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/
# It does not read BraveSoftware/Brave-Browser/NativeMessagingHosts/ (an
# earlier install wrote there; that copy is removed). Chrome reads that folder
# too, but allowed_origins admits only Orbit's extension ID.
#
# It writes only:
#   ~/Library/Application Support/Orbit/BraveHelper/OrbitBraveHelper
#   ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.awaneeshgupta.orbit.brave.json
# The extension itself is loaded by hand from BraveExtension/ (see PROJECT_SPEC.md).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="com.awaneeshgupta.orbit.brave"
EXTENSION_ID="iejmobaapejgfmjnecdgnmclnkpilpaf"  # fixed by the "key" in BraveExtension/manifest.json
ORIGIN="chrome-extension://$EXTENSION_ID/"
HOSTS="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST="$HOSTS/$NAME.json"
OLD_MANIFEST="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/$NAME.json"
HELPER_DIR="$HOME/Library/Application Support/Orbit/BraveHelper"
HELPER="$HELPER_DIR/OrbitBraveHelper"

fail() { echo "error: $*" >&2; exit 1; }

# Only ever removes a manifest whose "name" is Orbit's.
remove_ours() {
    [[ -e "$1" ]] || return 0
    if /usr/bin/python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("name") != sys.argv[2])' "$1" "$NAME" 2>/dev/null; then
        rm -f "$1" && echo "==> Removed $1"
    else
        echo "==> Left $1 alone: it isn't Orbit's." >&2
    fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
    remove_ours "$MANIFEST"
    remove_ours "$OLD_MANIFEST"
    rm -f "$HELPER"
    rmdir "$HELPER_DIR" 2>/dev/null || true
    echo "==> Removed Orbit's helper and its registration."
    exit 0
fi
[[ $# -eq 0 ]] || { echo "usage: scripts/install-brave-helper.sh [--uninstall]" >&2; exit 2; }

[[ -d "/Applications/Brave Browser.app" ]] || fail "Brave isn't in /Applications."
[[ -d "$HOSTS" ]] || fail "$HOSTS doesn't exist. Brave creates it when it starts: open Brave once, then run this again."
if [[ -e "$MANIFEST" ]] && ! grep -q "\"name\": \"$NAME\"" "$MANIFEST"; then
    fail "$MANIFEST exists and isn't Orbit's; left alone."
fi

echo "==> Building the helper (release)"
swift build -c release --product OrbitBraveHelper
BIN="$(swift build -c release --show-bin-path)/OrbitBraveHelper"

echo "==> Installing $HELPER"
mkdir -p "$HELPER_DIR"
install -m 0755 "$BIN" "$HELPER.new"
codesign --force --sign - --timestamp=none "$HELPER.new"
mv -f "$HELPER.new" "$HELPER"

echo "==> Registering $NAME"
cat > "$MANIFEST.new" <<EOF
{
  "name": "$NAME",
  "description": "Orbit: what's playing on YouTube in Brave",
  "path": "$HELPER",
  "type": "stdio",
  "allowed_origins": ["$ORIGIN"]
}
EOF
chmod 0644 "$MANIFEST.new"
mv -f "$MANIFEST.new" "$MANIFEST"
remove_ours "$OLD_MANIFEST"

echo "==> Validating"
/usr/bin/python3 -I - "$MANIFEST" "$NAME" "$HELPER" "$ORIGIN" <<'PY' || fail "the registration at $MANIFEST didn't validate."
import json, os, sys
path, name, helper, origin = sys.argv[1:]
m = json.load(open(path))
checks = {
    "file name matches host name": os.path.basename(path) == name + ".json",
    "name": m.get("name") == name,
    "description": isinstance(m.get("description"), str) and m["description"] != "",
    "type is stdio": m.get("type") == "stdio",
    "path is the absolute helper path": m.get("path") == helper and os.path.isabs(helper),
    "helper exists and is executable": os.path.isfile(helper) and os.access(helper, os.X_OK),
    "allowed_origins is exactly Orbit's extension": m.get("allowed_origins") == [origin],
    "manifest is readable": os.access(path, os.R_OK),
}
for label, ok in checks.items():
    print(("   ok  " if ok else "   BAD ") + label)
sys.exit(0 if all(checks.values()) else 1)
PY
lipo -archs "$HELPER" | grep -qw "$(uname -m)" || fail "the helper isn't built for $(uname -m)."
codesign --verify "$HELPER" || fail "the helper's signature doesn't verify."
echo "   ok  helper is $(lipo -archs "$HELPER") and signed"

echo "==> Registered: $MANIFEST"
echo "    Helper:     $HELPER"
echo "    Next: brave://extensions › Orbit for YouTube › reload (↻). The ID must read $EXTENSION_ID."

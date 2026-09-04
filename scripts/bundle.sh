#!/usr/bin/env bash
# Build whisper.app: a proper menu-bar (agent) app bundle, signed with a STABLE
# identity so the Accessibility grant for the hold-to-talk hotkey survives rebuilds.
#
# Usage:  scripts/bundle.sh            # release build -> build/whisper.app
#         CONFIG=debug scripts/bundle.sh
#
# Run scripts/make-signing-cert.sh once first for the persistent-grant fix. Without
# that identity this falls back to ad-hoc signing (works, but the grant resets on the
# next rebuild — the very thing the bundle is meant to avoid).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="whisper"
BUNDLE_ID="com.wbfrancis.whisper"
CERT_NAME="whisper-dev"
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"

OUT="build"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "error: built binary not found at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/$APP_NAME"
cp Resources/whisper-menu-bar-icon.png "$RESOURCES/"
cp Resources/whisper-menu-bar-icon@2x.png "$RESOURCES/"
cp Resources/recording-start.wav "$RESOURCES/"
cp Resources/recording-stop.wav "$RESOURCES/"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.6</string>
    <!-- Menu-bar agent: no Dock icon, no main window. -->
    <key>LSUIElement</key>             <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>whisper listens while you hold the dictation key and transcribes on-device.</string>
</dict>
</plist>
EOF

echo "==> signing"
# Documents can add file-provider metadata that `xattr -cr` cannot remove in place.
# Sign a clean temporary copy, then copy the signed bundle back to the requested path.
SIGN_DIR="$(mktemp -d)"
trap 'rm -rf "$SIGN_DIR"' EXIT
SIGN_APP="$SIGN_DIR/$APP_NAME.app"
ditto "$APP" "$SIGN_APP"
xattr -cr "$SIGN_APP"
# Match without -v: a self-signed identity is untrusted (CSSMERR_TP_NOT_TRUSTED) and so
# absent from the valid-only list, but it still signs fine and — because the cert is
# stable — gives a stable designated requirement, which is all TCC needs to persist.
if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
    # No --options runtime: the hardened runtime enforces library validation, which
    # refuses the ad-hoc-signed Homebrew whisper/ggml dylibs (different Team ID). We
    # aren't notarizing a personal tool, and TCC persistence needs only the stable DR.
    codesign --force --sign "$CERT_NAME" --identifier "$BUNDLE_ID" \
        --timestamp=none "$SIGN_APP"
    echo "    signed with stable identity '$CERT_NAME' — Accessibility grant will persist across rebuilds."
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$SIGN_APP"
    echo "    WARNING: no '$CERT_NAME' identity found — signed ad-hoc." >&2
    echo "    The Accessibility grant will reset on the next rebuild." >&2
    echo "    Run scripts/make-signing-cert.sh once to fix that." >&2
fi

codesign --verify --deep --strict --verbose=2 "$SIGN_APP" 2>&1 | sed 's/^/    /'

rm -rf "$APP"
ditto "$SIGN_APP" "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo
echo "Built $APP  ($(codesign -dv "$APP" 2>&1 | grep -m1 Signature | sed 's/^.*=//'))"
echo "Launch:  open $APP     (or drag it to /Applications)"
echo "First launch: grant Accessibility + Microphone when asked, then it's persistent."

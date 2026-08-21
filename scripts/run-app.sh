#!/bin/bash
# Builds Recall and starts it from a macOS .app bundle.
# Local notification authorization requires this bundle identity; do not launch
# the raw SwiftPM executable when manually testing reminder delivery.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 64
fi

cd "$ROOT_DIR"
swift build --configuration "$CONFIGURATION" --jobs 1
BIN_DIR="$(swift build --show-bin-path -c "$CONFIGURATION")"
EXECUTABLE="$BIN_DIR/RecallApp"
APP_BUNDLE="$ROOT_DIR/.build/Recall.app"
CONTENTS="$APP_BUNDLE/Contents"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "RecallApp executable was not produced at: $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$EXECUTABLE" "$CONTENTS/MacOS/RecallApp"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>Recall</string>
    <key>CFBundleExecutable</key>
    <string>RecallApp</string>
    <key>CFBundleIdentifier</key>
    <string>im.recall.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Recall</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null
# ScreenCaptureKit, TCC and UserNotifications associate consent with the app's
# designated requirement. A default ad hoc signature uses a changing code hash,
# so make the requirement depend only on Recall's stable Bundle identifier.
STABLE_REQUIREMENT='=designated => identifier "im.recall.app"'
/usr/bin/codesign --force --sign - --identifier im.recall.app --requirements="$STABLE_REQUIREMENT" "$CONTENTS/MacOS/RecallApp"
/usr/bin/codesign --force --sign - --identifier im.recall.app --requirements="$STABLE_REQUIREMENT" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
open "$APP_BUNDLE"

echo "Started $APP_BUNDLE"

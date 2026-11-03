#!/bin/bash
# Xcode 26+ uses an explicit system-masked icon, avoiding legacy auto-scaling.
# Older development toolchains keep the clean multi-resolution ICNS fallback.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:?Usage: compile-app-icon.sh OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$OUTPUT_DIR/AppIcon.icns"
XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | awk '/^Xcode / {split($2, version, "."); print version[1]}')"
if [[ -z "$XCODE_MAJOR" || "$XCODE_MAJOR" -lt 26 ]]; then
    echo "Using legacy ICNS icon (Xcode 26+ enables the system-masked icon)."
    exit 0
fi
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recall-icon.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
xcrun actool "$ROOT_DIR/Resources/AppIcon.icon" \
    --compile "$STAGING_DIR" --platform macosx --target-device mac \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$STAGING_DIR/IconInfo.plist"
test -s "$STAGING_DIR/Assets.car"
cp "$STAGING_DIR/Assets.car" "$OUTPUT_DIR/Assets.car"
echo "Compiled system-masked Recall app icon."

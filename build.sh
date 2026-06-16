#!/bin/bash
# Builds SpeakUp.app directly with swiftc (no Xcode / SwiftPM manifest needed —
# this machine only has Command Line Tools, whose SwiftPM manifest support
# ("no such module 'PackageDescription'") is broken).
set -euo pipefail

cd "$(dirname "$0")"

APP="SpeakUp.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> Compiling Swift sources..."
mkdir -p "$BIN_DIR" "$RES_DIR" .build

swiftc -O Sources/SpeakUp/*.swift \
    -o ".build/SpeakUp" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework Speech

echo "==> Assembling $APP ..."
cp ".build/SpeakUp" "$BIN_DIR/SpeakUp"
cp "Info.plist" "$APP/Contents/Info.plist"

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$APP"

echo "==> Done. Built $APP"
echo ""
echo "Next steps:"
echo "  1. Run:  open \"$APP\""
echo "  2. A menu-bar icon (mic emoji) should appear."
echo "  3. Click it -> 'Check Permissions' to grant Accessibility + Microphone."
echo "     (macOS will prompt you to add SpeakUp.app in System Settings.)"
echo "  4. Re-run 'Check Permissions' after granting, to confirm."
echo "  5. Focus a text field in Notes/TextEdit/Mail/Messages, then press"
echo "     Cmd+Shift+I (or use the menu 'Inspect Focused Element Now')."
echo "  6. Use 'Show Last Inspection' or: tail -f ~/speakup-poc-log.txt"

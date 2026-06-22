#!/bin/bash
# SpeakUp Installer — double-click this file to install.

echo ""
echo "  Installing SpeakUp..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/SpeakUp.app"
DEST="/Applications/SpeakUp.app"

if [ ! -d "$APP_PATH" ]; then
    echo "  Error: SpeakUp.app not found next to this installer."
    echo "  Make sure you unzipped the full folder first."
    echo ""
    read -p "  Press Enter to close..."
    exit 1
fi

if [ -d "$DEST" ]; then
    echo "  Removing old version..."
    rm -rf "$DEST"
fi

echo "  Moving SpeakUp.app to Applications..."
cp -R "$APP_PATH" "$DEST"

echo "  Removing quarantine flag..."
xattr -cr "$DEST" 2>/dev/null

echo "  Launching SpeakUp..."
open "$DEST"

echo ""
echo "  Done! SpeakUp is running."
echo "  Click the microphone in your menu bar to check permissions."
echo ""
read -p "  Press Enter to close this window..."

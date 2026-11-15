#!/bin/bash
#
# build.sh — build xcode-chat into one standalone executable (Python interpreter included),
# so it runs on a Mac without Python installed: dist/xcode-chat
#
# The app embeds dist/xcode-chat (Build Phases → Copy Files → Executables, Code Sign On Copy), so Xcode re-signs it
# with the app's identity and keeps the hardened runtime and entitlements set here.
#
# Needs python3 on the BUILD machine only (Xcode's command line tools provide it).
# CODESIGN_IDENTITY: identity to sign with (default: ad-hoc "-").
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.build/venv"
PYTHON="${PYTHON:-/usr/bin/python3}"
IDENTITY="${CODESIGN_IDENTITY:--}"
BIN="$SCRIPT_DIR/dist/xcode-chat"

cd "$SCRIPT_DIR"
if [ ! -x "$VENV/bin/pyinstaller" ]; then
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet pyinstaller
fi

"$VENV/bin/pyinstaller" --onefile --clean --noconfirm --log-level WARN \
  --name xcode-chat \
  --distpath "$SCRIPT_DIR/dist" \
  --workpath "$SCRIPT_DIR/.build/pyinstaller" \
  --specpath "$SCRIPT_DIR/.build" \
  --paths "$SCRIPT_DIR" \
  "$SCRIPT_DIR/entry.py"

# Hardened runtime (required for notarization) + the entitlement in entitlements.plist.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$SCRIPT_DIR/entitlements.plist" "$BIN"

echo "Built: $BIN"

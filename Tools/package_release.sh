#!/bin/bash
#
# package_release.sh — Build, sign, notarize, and package a new
# XcodeAgentRemote release: a DMG with the GUI app. The xcode-chat CLI is inside the app
# (Contents/MacOS/xcode-chat), for the app's own use only. Output goes to ~/Desktop/XcodeAgentRemote_<version>.dmg.
#
# Prerequisites:
# Run the following command to add /update A "Developer ID Application" certificate in the keychain.
#
#   xcrun notarytool store-credentials "notarytool-profile" \
#     --apple-id "your@apple.id" --team-id "NLTYK5T6U3" \
#     --password "<app-specific-password>"
#
#  - Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com) → Security → App-Specific Passwords
#
#
#
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
# This project's packages require the Swift 6.4 toolchain (Xcode 27 / beta).
# Plain xcodebuild (Xcode 26.x, Swift 6.3.3) fails package resolution.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

GUI_SCHEME="XcodeAgentRemote"
CLI_NAME="xcode-chat"                    # embedded at Contents/MacOS/xcode-chat
NOTARYTOOL_PROFILE="notarytool-profile"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/XcodeAgentRemote.xcodeproj"
CLI_DIR="$SCRIPT_DIR/xcode-chat"         # Python sources; build.sh bundles them into one executable
ARCHIVE_PATH="/tmp/XcodeAgentRemote.xcarchive"
EXPORT_PATH="/tmp/XcodeAgentRemoteExport"
STAGING_DIR="/tmp/XcodeAgentRemoteDMG"
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "▶ $*"; }

# ── 0. Team id (used for signing during export) ───────────────────────────────
# This project uses Xcode 27's project.xcproj format: "DEVELOPMENT_TEAM": "XXXXXXXXXX"
TEAM_ID=$(grep -m1 -o '"DEVELOPMENT_TEAM"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT/project.xcproj" \
  | sed -E 's/.*"([^"]*)"$/\1/')

# ── 1. Build the CLI first: the app embeds Tools/xcode-chat/dist/xcode-chat ────
# (Build Phases → Copy Files → Executables, Code Sign On Copy), so the archive must copy the latest build.
log "Building $CLI_NAME..."
"$CLI_DIR/build.sh"

# ── 2. Archive & export the GUI (Developer ID) ────────────────────────────────
log "Archiving $GUI_SCHEME..."
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$GUI_SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  -allowProvisioningUpdates

log "Exporting archive..."
cat > /tmp/ExportOptions.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  -allowProvisioningUpdates

APP_PATH="$EXPORT_PATH/$GUI_SCHEME.app"
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion)
log "Version: $VERSION ($BUILD)"

CLI_IN_APP="$APP_PATH/Contents/MacOS/$CLI_NAME"
if [ ! -x "$CLI_IN_APP" ]; then
  echo "error: $CLI_IN_APP missing; check the app's Copy Files build phase" >&2
  exit 1
fi
"$CLI_IN_APP" --help > /dev/null   # the embedded CLI starts under the app's signature

# ── 3. Notarize & staple the app (the embedded CLI is notarized with it) ─────
log "Notarizing app..."
APP_ZIP="/tmp/XcodeAgentRemote-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait
log "Stapling ticket..."
xcrun stapler staple "$APP_PATH"
rm -f "$APP_ZIP"

# ── 4. Assemble the DMG staging folder (app only) ─────────────────────────────
log "Staging DMG contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/$GUI_SCHEME.app"

# ── 5. Build the DMG (built-in hdiutil, no styling) ──────────────────────────
DMG_NAME="XcodeAgentRemote_${VERSION}.dmg"
DMG_PATH="/tmp/$DMG_NAME"
log "Building $DMG_NAME..."
rm -f "$DMG_PATH"
hdiutil create \
  -volname "XcodeAgentRemote" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

# ── 6. Place the DMG on the Desktop ──────────────────────────────────────────
DMG_DEST="$HOME/Desktop/$DMG_NAME"
log "Writing $DMG_DEST..."
mv "$DMG_PATH" "$DMG_DEST"

# ── 7. Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$STAGING_DIR" "$ARCHIVE_PATH" "$EXPORT_PATH"

log "Done. Packaged v${VERSION} (${BUILD}) → $DMG_DEST"

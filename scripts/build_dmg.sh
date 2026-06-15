#!/usr/bin/env bash
# Build Autoscreener.app in Release config and wrap it into a drag-to-Applications DMG.
#
# Usage:  ./scripts/build_dmg.sh
# Output: build/Autoscreener.dmg
#
# Env knobs (all optional):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   # enables codesign
#   NOTARY_PROFILE="AC_PASSWORD"                                   # `xcrun notarytool store-credentials` profile name; enables notarisation + stapling
#   CONFIGURATION=Release
#   SCHEME=Autoscreener
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-Autoscreener}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="Autoscreener"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
STAGE_DIR="$BUILD_DIR/dmg-stage"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_DIR"

echo "▶︎ Archiving ($CONFIGURATION)…"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -skipPackagePluginValidation \
  archive

# Export options (developer-id if SIGN_IDENTITY set, otherwise development-style copy-out).
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▶︎ Writing developer-id ExportOptions.plist"
  cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${SIGN_IDENTITY}</string>
</dict></plist>
EOF
else
  echo "▶︎ No SIGN_IDENTITY — exporting copy (unsigned/ad-hoc)"
  cat > "$EXPORT_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>mac-application</string>
</dict></plist>
EOF
fi

echo "▶︎ Exporting .app to $EXPORT_DIR"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "✗ Exported .app not found at $APP_PATH"; exit 1; }

# Optional notarisation
if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▶︎ Notarising $APP_PATH (profile=$NOTARY_PROFILE)…"
  ZIP_FOR_NOTARY="$BUILD_DIR/$APP_NAME-notary.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
  xcrun notarytool submit "$ZIP_FOR_NOTARY" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
fi

# Stage a drag-to-Applications layout
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "▶︎ Creating DMG → $DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Sign + staple the DMG too if we have credentials
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
  fi
fi

echo "✓ Done: $DMG_PATH"

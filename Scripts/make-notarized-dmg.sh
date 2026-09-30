#!/usr/bin/env bash
# Katana's distribution mechanism: universal archive, Developer ID export,
# notarize/staple app, compressed DMG with Applications link, notarize/staple DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="USB Prober"
TEAM_ID="Q3Z639YB49"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Matt Sephton ($TEAM_ID)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-password}"
BUILD_DIR="$ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
STAGE="$BUILD_DIR/dmg-root"

step() { printf '\n▶ %s\n' "$1"; }
cd "$ROOT"
mkdir -p "$BUILD_DIR"

step 'Checking Developer ID and notarization credentials'
security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY"
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" > "$BUILD_DIR/notary-history.log"

step 'Archiving universal Deployment build'
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$STAGE"
xcodebuild archive \
    -project "$ROOT/USBProber.xcodeproj" -scheme "$APP_NAME" \
    -configuration Deployment -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$BUILD_DIR/DerivedData" -destination 'generic/platform=macOS' \
    ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES \
    INSTALL_PATH=/Applications SKIP_INSTALL=NO \
    > "$BUILD_DIR/archive.log" 2>&1

step 'Exporting Developer ID app'
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" -exportOptionsPlist "$ROOT/ExportOptions.plist" \
    > "$BUILD_DIR/export.log" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1
lipo "$APP_PATH/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64

step 'Notarizing and stapling app'
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

step 'Creating compressed DMG with Applications link'
mkdir -p "$STAGE"
ditto --hfsCompression "$APP_PATH" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"

step 'Signing, notarizing and stapling DMG'
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

step 'Verifying Gatekeeper acceptance'
spctl -a -vv "$APP_PATH"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"
mkdir -p "$ROOT/dist"
cp -f "$DMG_PATH" "$ROOT/dist/$APP_NAME.dmg"
(cd "$ROOT/dist" && shasum -a 256 "$APP_NAME.dmg" > SHA256SUMS.txt)
printf '\nDMG: %s\n' "$ROOT/dist/$APP_NAME.dmg"

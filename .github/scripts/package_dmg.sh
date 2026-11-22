#!/bin/bash
# Package the Xcode-signed app; notarize and staple only the disk image.
set -euo pipefail

VERSION_SUFFIX="${1:?Usage: package_dmg.sh <build-suffix> [app-path]}"
APP_PATH="${2:-build/DerivedData/Build/Products/Release/Quatuor.app}"
: "${APPLE_DEVID_APP_CERT_NAME:?Signing identity is required}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found at $APP_PATH" >&2
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --entitlements - --xml "$APP_PATH" > "$WORK_DIR/entitlements.plist" 2>/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$WORK_DIR/entitlements.plist" 2>/dev/null || true)" == true ]]; then
    echo "The app has get-task-allow enabled; build with CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO." >&2
    exit 1
fi
TEAM_ID=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "The app must be signed with a Developer ID before packaging." >&2
    exit 1
fi
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
APP_NAME=$(basename "$APP_PATH")
BUILD_NAME="${APP_NAME%.app}-${VERSION_SUFFIX}"
DMG_PATH="dist/${BUILD_NAME}-macOS.dmg"
mkdir -p dist "$WORK_DIR/image"
ditto "$APP_PATH" "$WORK_DIR/image/$APP_NAME"
ln -s /Applications "$WORK_DIR/image/Applications"
hdiutil create -ov -srcfolder "$WORK_DIR/image" -volname "$BUILD_NAME" -format UDZO "$DMG_PATH"
codesign --sign "$APPLE_DEVID_APP_CERT_NAME" --timestamp --identifier "$APP_IDENTIFIER.dmg" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

# A Keychain profile is convenient for running this same script locally.
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    : "${APPLE_ID_USER:?Apple ID is required}"
    : "${APPLE_ID_PASS:?App-specific password is required}"
    NOTARY_AUTH=(--apple-id "$APPLE_ID_USER" --password "$APPLE_ID_PASS" --team-id "$TEAM_ID")
fi
xcrun notarytool submit "$DMG_PATH" "${NOTARY_AUTH[@]}" --wait --output-format json | tee "$WORK_DIR/notary-result.json"
if [[ "$(plutil -extract status raw -o - "$WORK_DIR/notary-result.json")" != Accepted ]]; then
    SUBMISSION_ID=$(plutil -extract id raw -o - "$WORK_DIR/notary-result.json")
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" >&2
    exit 1
fi
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

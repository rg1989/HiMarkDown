#!/usr/bin/env bash
# tools/release.sh
#
# Build, sign, and package HiMarkDown.app for distribution from a single
# machine (your laptop) or from CI (GitHub Actions). Produces three files
# in `dist/`:
#
#   HiMarkDown-<version>.app.zip          ← double-clickable
#   HiMarkDown-<version>.dmg              ← drag-to-Applications installer
#   HiMarkDown-<version>.sha256           ← checksums for both
#
# Signing strategy is auto-detected:
#   • If the env var DEVELOPER_ID_APPLICATION is set (e.g. "Developer ID
#     Application: Jane Doe (TEAMID12345)"), we sign with that identity and,
#     when notarization secrets are present, submit + staple.
#   • Otherwise we ad-hoc sign (-) so the binary at least has a stable code
#     signature. Users will hit Gatekeeper once and have to right-click → Open.
#
# Requires: Xcode (xcodebuild, codesign, hdiutil, notarytool).
#
# Usage:
#   ./tools/release.sh                    # version comes from Info.plist
#   VERSION=1.2.3 ./tools/release.sh      # override
#
set -euo pipefail

# ── Resolve repo root no matter where this script is invoked from ─────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="HiMarkDown"
CONFIG="Release"
APP_NAME="HiMarkDown"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

# ── Version: env override > Info.plist marketing version ──────────────────
INFO_PLIST="$REPO_ROOT/HiMarkDown/Info.plist"
DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
VERSION="${VERSION:-$DEFAULT_VERSION}"
echo "▶︎ Building $APP_NAME $VERSION"

# ── Clean previous artifacts only (don't blow away DerivedData) ───────────
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ── 1. Archive ─────────────────────────────────────────────────────────────
echo "▶︎ xcodebuild archive"
xcodebuild \
    -project "$REPO_ROOT/HiMarkDown.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    | xcbeautify || xcodebuild \
        -project "$REPO_ROOT/HiMarkDown.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        archive

# ── 2. Decide signing identity ────────────────────────────────────────────
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    EXPORT_METHOD="developer-id"
    echo "▶︎ Signing with Developer ID: $SIGN_IDENTITY"
else
    SIGN_IDENTITY="-"
    EXPORT_METHOD="developer-id"   # still 'developer-id' export type, just ad-hoc signed
    echo "▶︎ No DEVELOPER_ID_APPLICATION env var — using ad-hoc signature ('-')"
fi

# ── 3. Export the .app from the archive ───────────────────────────────────
EXPORT_OPTS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$EXPORT_METHOD</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGN_IDENTITY</string>
</dict>
</plist>
EOF

# When ad-hoc signing, xcodebuild -exportArchive refuses to use a "manual"
# Developer ID export profile. So for the unsigned/ad-hoc path we copy the
# .app out of the archive and re-sign it ourselves.
APP_OUT="$EXPORT_DIR/$APP_NAME.app"
mkdir -p "$EXPORT_DIR"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "▶︎ Copying $APP_NAME.app out of archive (ad-hoc path)"
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_OUT"
    echo "▶︎ codesign --deep --force --sign -"
    codesign --force --deep --sign - --options runtime --timestamp=none "$APP_OUT"
else
    echo "▶︎ xcodebuild -exportArchive"
    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTS_PLIST"
fi

# ── 4. Optional: notarize ──────────────────────────────────────────────────
# Activated only if all three secrets are present. Without them we silently
# skip — the .app is still distributable, just with the Gatekeeper prompt.
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    echo "▶︎ Submitting to notarytool"
    NOTARY_ZIP="$BUILD_DIR/notary.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_OUT" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
    echo "▶︎ Stapling ticket"
    xcrun stapler staple "$APP_OUT"
else
    echo "▶︎ Skipping notarization (no Apple credentials in env)"
fi

# ── 5. Package — .zip ──────────────────────────────────────────────────────
ZIP_OUT="$DIST_DIR/$APP_NAME-$VERSION.app.zip"
echo "▶︎ ditto → $ZIP_OUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_OUT" "$ZIP_OUT"

# ── 6. Package — .dmg (drag-to-Applications) ──────────────────────────────
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_OUT="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -rf "$DMG_STAGING" "$DMG_OUT"
mkdir -p "$DMG_STAGING"
cp -R "$APP_OUT" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "▶︎ hdiutil create → $DMG_OUT"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

# ── 7. Checksums ───────────────────────────────────────────────────────────
SUMS_OUT="$DIST_DIR/$APP_NAME-$VERSION.sha256"
( cd "$DIST_DIR" && shasum -a 256 "$APP_NAME-$VERSION.app.zip" "$APP_NAME-$VERSION.dmg" > "$(basename "$SUMS_OUT")" )

echo
echo "✅ Release artifacts in dist/:"
ls -lh "$DIST_DIR"
echo
echo "Tag and upload with:"
echo "    git tag v$VERSION && git push origin v$VERSION"
echo "    # CI will pick up the tag and create a GitHub Release."

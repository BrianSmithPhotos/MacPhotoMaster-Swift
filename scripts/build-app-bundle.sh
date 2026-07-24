#!/bin/bash
# Wraps the SPM release executable in a real .app bundle — see scripts/README.md
# "build-app-bundle.sh" for why this exists.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacPhotoMaster"
BUNDLE_ID="photos.briansmith.macphotomaster"
ICON_SOURCE="icons/purplegreenswallow1024x1024.png"
DERIVED_DATA_DIR=".build/xcodebuild-release"
BUILD_DIR="$DERIVED_DATA_DIR/Build/Products/Release"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="0.1"
BUILD_NUMBER="$(git rev-list --count HEAD)"

# `swift build -c release` cannot compile mlx-swift's Metal shaders (its own README says so
# explicitly) — a plain SPM release build has no default.metallib, so MLXModelManager aborts the
# whole process the instant it touches Metal. xcodebuild runs the same shader-compile step Xcode's
# own build does, so it's required here even though it's slower than `swift build`.
echo "Building release binary via xcodebuild (required for mlx-swift's Metal shaders)..."
xcodebuild -scheme "$APP_NAME" -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_DIR" build

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SPM's Bundle.module accessor looks for each dependency's own resource bundle
# next to the executable (or, inside an .app, under Contents/Resources) — copy
# all of them, not just this target's, since GRDB/swift-transformers/swift-crypto
# each ship their own.
for bundle in "$BUILD_DIR"/*.bundle; do
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

echo "Generating app icon from $ICON_SOURCE..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_SOURCE" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" --output "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# The `cp -R` of each resource bundle above preserves the read-only permissions
# SPM's checkout cache stores them with, which blocks `xattr -c` below (removing
# an attribute needs write access to the file) — reassert owner-write on our copy.
chmod -R u+w "$APP_BUNDLE"

# codesign rejects any resource fork / Finder-info extended attributes (e.g. a
# stray com.apple.FinderInfo picked up from a source PNG) as "detritus" — strip
# everything before signing.
xattr -cr "$APP_BUNDLE"

# Signed with a certificate-backed identity rather than ad-hoc, so privacy
# grants survive a rebuild. TCC keys its grants to the code signature, and an
# ad-hoc signature is just the binary's own hash — it changes every time the
# binary does, so macOS sees a brand-new app on each rebuild and silently stops
# applying anything previously granted. That churn is what pushes you toward
# Full Disk Access; a stable signature is what lets the narrow grants the app
# actually needs (removable volumes for the SD card, CloudStorage for
# Timeline.json) stick instead. Still a development identity, so it's for this
# machine, not for distribution. Override for a machine without the
# certificate; `-` restores ad-hoc signing.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: BRIAN SMITH (M8V275SX93)}"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Drag it into /Applications (or straight onto the Dock) to pin it."

#!/bin/bash
# Build vitterm.app: release binary, precompiled Metal shaders, resources, icon, ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="${APP:-build/vitterm.app}"
# TEST_HOOKS=1 enables the VITTERM_DEBUG_* / VITTERM_SNAPSHOT test hooks (for end-to-end tests).
# Built in a separate build directory so it never mixes with the normal release build.
BUILD_ARGS=()
BUNDLE_ID="dev.vitterm.vitterm"
DISPLAY_NAME="vitterm"
if [ "${TEST_HOOKS:-0}" = 1 ]; then
    BUILD_ARGS=(--build-path .build/test-hooks -Xswiftc -DVITTERM_TEST_HOOKS)
    # A distinct identity, so macOS never launches the test build in place of the real app and
    # test runs don't touch the real app's preferences.
    BUNDLE_ID="dev.vitterm.vitterm.e2e"
    DISPLAY_NAME="vitterm (test build)"
fi
VERSION="0.1.0"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product vitterm ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --show-bin-path)/vitterm"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/vitterm"

# SwiftPM records the deployment target as the SDK version (e.g. "sdk 14.0"). AppKit uses the SDK
# version to decide whether an app gets the current design (Liquid Glass, modern traffic lights)
# or runs in compatibility mode, so stamp the SDK we actually built against.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="14.0"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
    -output "$APP/Contents/MacOS/vitterm" "$APP/Contents/MacOS/vitterm"

echo "==> compiling Metal shaders"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if xcrun -sdk macosx metal -O3 -c Sources/VitRender/Shaders.metal -o "$TMP/shaders.air" 2>"$TMP/metal.log"; then
    xcrun -sdk macosx metallib "$TMP/shaders.air" -o "$APP/Contents/Resources/default.metallib"
else
    cat "$TMP/metal.log"
    echo "warning: offline Metal compile failed; the app will compile shaders at launch" >&2
fi
cp Sources/VitRender/Shaders.metal "$APP/Contents/Resources/"

echo "==> resources"
cp -R Sources/VitConfig/Themes "$APP/Contents/Resources/Themes"
cp -R Sources/vitterm/ShellIntegration "$APP/Contents/Resources/ShellIntegration"

echo "==> icon"
swiftc -O scripts/make_icon.swift -o "$TMP/make_icon" 2>/dev/null
"$TMP/make_icon" Resources/AppIcon-source.jpg "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>vitterm</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Hardened runtime: blocks library injection (DYLD_INSERT_LIBRARIES) and debugger attachment by
# other processes, which matters for an app that sees everything typed into it.
echo "==> codesign (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime --timestamp=none "$APP"
echo "Built $APP"

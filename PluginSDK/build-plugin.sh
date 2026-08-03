#!/bin/bash
#
# build-plugin.sh — assemble a 4DSTEM Explorer plugin bundle.
#
#   ./build-plugin.sh Examples/RadialProfile [output-dir]
#
# The source directory must contain a plugin.conf and one or more .swift files.
# FourDSTEMPluginAPI.swift is compiled in automatically. With no output
# directory the bundle is installed straight into the app's plugins folder.
#
set -euo pipefail

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_SOURCE="$SDK_DIR/FourDSTEMPluginAPI.swift"

INSTALL_DIR="$HOME/Library/Containers/lebeaugroup.stemexplorer/Data/Library/Application Support/4DSTEM Explorer/PlugIns"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <source-directory> [output-directory]" >&2
    exit 2
fi

SOURCE_DIR="$(cd "$1" && pwd)"
OUTPUT_DIR="${2:-$INSTALL_DIR}"

if [ ! -f "$SOURCE_DIR/plugin.conf" ]; then
    echo "error: $SOURCE_DIR/plugin.conf not found" >&2
    exit 1
fi
if [ ! -f "$API_SOURCE" ]; then
    echo "error: $API_SOURCE not found" >&2
    exit 1
fi

# NAME, PRINCIPAL_CLASS, IDENTIFIER, VERSION
# shellcheck disable=SC1091
source "$SOURCE_DIR/plugin.conf"
: "${NAME:?plugin.conf must set NAME}"
: "${PRINCIPAL_CLASS:?plugin.conf must set PRINCIPAL_CLASS}"
: "${IDENTIFIER:?plugin.conf must set IDENTIFIER}"
VERSION="${VERSION:-1.0}"

SOURCES=("$API_SOURCE")
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$SOURCE_DIR" -maxdepth 1 -name '*.swift' -print0 | sort -z)

if [ ${#SOURCES[@]} -lt 2 ]; then
    echo "error: no .swift files in $SOURCE_DIR" >&2
    exit 1
fi

BUNDLE="$OUTPUT_DIR/$NAME.bundle"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

MACOS_SDK="$(xcrun --show-sdk-path --sdk macosx)"

echo "Building $NAME.bundle"
echo "  principal class : $PRINCIPAL_CLASS"
echo "  sources         : ${#SOURCES[@]} file(s)"

# Build each architecture separately so the result loads on both Apple silicon
# and Intel, then lipo them together. An architecture whose toolchain is
# unavailable is skipped rather than failing the build.
SLICES=()
for ARCH in arm64 x86_64; do
    SLICE="$BUILD_DIR/$NAME-$ARCH"
    if xcrun swiftc \
        -emit-library \
        -module-name "$NAME" \
        -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
        -sdk "$MACOS_SDK" \
        -swift-version 5 \
        -O \
        -o "$SLICE" \
        "${SOURCES[@]}" 2> "$BUILD_DIR/$ARCH.log"; then
        SLICES+=("$SLICE")
        echo "  built           : $ARCH"
    else
        echo "  skipped         : $ARCH"
        sed 's/^/      /' "$BUILD_DIR/$ARCH.log" >&2
    fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
    echo "error: no architecture built successfully" >&2
    exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

if [ ${#SLICES[@]} -eq 1 ]; then
    cp "${SLICES[0]}" "$BUNDLE/Contents/MacOS/$NAME"
else
    xcrun lipo -create "${SLICES[@]}" -output "$BUNDLE/Contents/MacOS/$NAME"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$IDENTIFIER</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>NSPrincipalClass</key>
	<string>$PRINCIPAL_CLASS</string>
</dict>
</plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist" > /dev/null

# Apple silicon refuses to load unsigned code, so ad-hoc signing is mandatory,
# not optional. Set PLUGIN_SIGN_IDENTITY to sign with a real identity instead.
SIGN_IDENTITY="${PLUGIN_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLE" 2>/dev/null \
    || codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE"

echo "  signed          : $SIGN_IDENTITY"
echo "Installed to $BUNDLE"
echo
echo "Reload it from the app's Plugins ▸ Reload Plugins menu."

#!/bin/bash
# Build Taction.app: a universal (or --native) release binary wrapped in an app bundle and signed.
#
#   scripts/bundle.sh             -> dist/Taction.app (universal, hardened runtime)
#   scripts/bundle.sh --native    -> same, current architecture only (faster; for local testing)
#
# Version comes from the VERSION file. Build number is the commit count when in git, else a timestamp.
# Signing identity: $TACTION_SIGN_IDENTITY, else the first Developer ID Application identity,
# else Apple Development, else ad hoc (with a warning: privacy grants are tied to the signature).
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG_DIR"
NATIVE=0
[ "${1:-}" = "--native" ] && NATIVE=1

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || true)"
if [ -z "$BUILD" ] || [ "$BUILD" = "0" ]; then
    BUILD="$(date +%Y%m%d%H%M)"       # not in a git history yet: use a timestamp
fi
MIN_MACOS="13.0"
APP="$PKG_DIR/dist/Taction.app"
STAGE="$PKG_DIR/.build/universal"
ICON_PNG="$PKG_DIR/.build/AppIcon-1024.png"
ICNS="$PKG_DIR/Resources/AppIcon.icns"

# Keep the CLI's fallback version string in step with VERSION.
if ! grep -q "fallback = \"$VERSION\"" Sources/TactionDaemon/Version.swift; then
    sed -i '' "s/fallback = \"[^\"]*\"/fallback = \"$VERSION\"/" Sources/TactionDaemon/Version.swift
    echo "updated Version.swift fallback to $VERSION"
fi

pick_identity() {
    if [ -n "${TACTION_SIGN_IDENTITY:-}" ]; then echo "$TACTION_SIGN_IDENTITY"; return; fi
    local ids dev
    ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    dev="$(echo "$ids" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
    if [ -n "$dev" ]; then echo "$dev"; return; fi
    dev="$(echo "$ids" | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
    if [ -n "$dev" ]; then echo "$dev"; return; fi
    echo "-"
}

# 1. Binary
mkdir -p "$STAGE" dist
if [ "$NATIVE" = "1" ]; then
    echo "building Taction (release, native)..."
    swift build -c release --product Taction 2>&1 | tail -1
    cp -f "$(swift build -c release --show-bin-path)/Taction" "$STAGE/Taction"
else
    for arch in arm64 x86_64; do
        echo "building Taction (release, $arch)..."
        swift build -c release --product Taction --triple "$arch-apple-macosx$MIN_MACOS" 2>&1 | tail -1
    done
    lipo -create \
        "$(swift build -c release --triple "arm64-apple-macosx$MIN_MACOS" --show-bin-path)/Taction" \
        "$(swift build -c release --triple "x86_64-apple-macosx$MIN_MACOS" --show-bin-path)/Taction" \
        -output "$STAGE/Taction"
fi
echo "architectures: $(lipo -archs "$STAGE/Taction")"

# 2. Icon (generated once; delete Resources/AppIcon.icns to regenerate)
if [ ! -f "$ICNS" ]; then
    echo "rendering app icon..."
    swift scripts/make-icon.swift "$ICON_PNG" Resources/hand-source.png >/dev/null
    ICONSET="$PKG_DIR/.build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
    echo "wrote $ICNS"
fi

# 3. Bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$STAGE/Taction" "$APP/Contents/MacOS/Taction"
cp -f "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Taction-Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 4. Sign
IDENTITY="$(pick_identity)"
if [ "$IDENTITY" = "-" ]; then
    echo "WARNING: no signing identity; signing ad hoc. Privacy grants will not survive rebuilds and the updater will refuse to run."
    codesign --force --sign - --identifier org.jorj.Taction "$APP"
else
    echo "signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier org.jorj.Taction --options runtime --timestamp "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "built $APP (version $VERSION, build $BUILD)"

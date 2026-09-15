#!/bin/bash
# Build, sign, and install tactiond as a per-user LaunchAgent. No sudo required.
#
#   scripts/install.sh            build a universal release, sign, install binaries and plist, start the agent
#   scripts/install.sh --no-start install but do not bootstrap the agent (first run should be in the foreground)
#   scripts/install.sh --native   build only for this Mac's architecture (faster)
#
# Universal builds: SwiftPM's single-command multi-arch build needs Xcode's build system, so this
# builds arm64 and x86_64 separately and joins them with lipo, which works with the Command Line
# Tools alone.
#
# Signing identity: $TACTION_SIGN_IDENTITY if set, else the first "Developer ID Application"
# identity in the keychain, else the first "Apple Development" identity, else ad hoc (with a warning:
# ad hoc signatures change every build, so TCC will ask for permission again after each rebuild).
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Application Support/Taction"
BIN="$DEST/bin"
LABEL="org.jorj.tactiond"
PLIST_SRC="$PKG_DIR/Resources/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
TOOLS="tactiond taction-probe taction-replay"
MIN_MACOS="13.0"
START=1
NATIVE=0
for arg in "$@"; do
    case "$arg" in
        --no-start) START=0 ;;
        --native) NATIVE=1 ;;
        *) echo "unknown option $arg" >&2; exit 1 ;;
    esac
done

pick_identity() {
    if [ -n "${TACTION_SIGN_IDENTITY:-}" ]; then echo "$TACTION_SIGN_IDENTITY"; return; fi
    local ids
    ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local dev
    dev="$(echo "$ids" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
    if [ -n "$dev" ]; then echo "$dev"; return; fi
    dev="$(echo "$ids" | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
    if [ -n "$dev" ]; then echo "$dev"; return; fi
    echo "-"
}

cd "$PKG_DIR"
STAGE="$PKG_DIR/.build/universal"
mkdir -p "$STAGE"

if [ "$NATIVE" = "1" ]; then
    echo "building release for this architecture..."
    swift build -c release 2>&1 | tail -1
    BUILD="$(swift build -c release --show-bin-path)"
    for tool in $TOOLS; do cp -f "$BUILD/$tool" "$STAGE/$tool"; done
else
    for arch in arm64 x86_64; do
        echo "building release for $arch..."
        swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" 2>&1 | tail -1
    done
    ARM="$(swift build -c release --triple "arm64-apple-macosx$MIN_MACOS" --show-bin-path)"
    X86="$(swift build -c release --triple "x86_64-apple-macosx$MIN_MACOS" --show-bin-path)"
    for tool in $TOOLS; do
        lipo -create "$ARM/$tool" "$X86/$tool" -output "$STAGE/$tool"
    done
    echo "universal: $(lipo -archs "$STAGE/tactiond")"
fi

IDENTITY="$(pick_identity)"
if [ "$IDENTITY" = "-" ]; then
    echo "WARNING: no signing identity found; signing ad hoc. Permission prompts will recur after every rebuild."
else
    echo "signing with: $IDENTITY"
fi

mkdir -p "$BIN" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
for tool in $TOOLS; do
    cp -f "$STAGE/$tool" "$BIN/$tool"
    codesign --force --sign "$IDENTITY" --identifier "org.jorj.$tool" --options runtime "$BIN/$tool" 2>&1 | grep -v "replacing existing signature" || true
done
echo "installed binaries in $BIN"

sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
echo "installed $PLIST_DST"

if [ "$START" = "1" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    echo "agent started. Check with: \"$BIN/tactiond\" --status"
else
    echo "not started. For the first run, grant permissions interactively with:"
    echo "  \"$BIN/tactiond\" --foreground --debug"
    echo "then: launchctl bootstrap gui/$(id -u) \"$PLIST_DST\""
fi

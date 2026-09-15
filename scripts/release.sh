#!/bin/bash
# Produce the release artifacts for GitHub:
#   dist/Taction-<version>.zip   what the in-app updater downloads (must be named exactly like this)
#   dist/Taction-<version>.dmg   drag-to-Applications installer for people
#
# Notarization is applied when TACTION_NOTARY_PROFILE names a keychain profile created with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id AGP3P87P9R --password <app-specific>
# Without it the artifacts are signed but not notarized; Gatekeeper will warn on first open.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG_DIR"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="dist/Taction.app"
ZIP="dist/Taction-$VERSION.zip"
DMG="dist/Taction-$VERSION.dmg"
PROFILE="${TACTION_NOTARY_PROFILE:-}"

scripts/bundle.sh

notarize() {
    local file="$1"
    if [ -z "$PROFILE" ]; then echo "not notarizing $file (TACTION_NOTARY_PROFILE unset)"; return; fi
    echo "notarizing $file..."
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait
}

# 1. App notarization goes through a zip, then the ticket is stapled to the bundle.
rm -f "$ZIP" "$DMG"
if [ -n "$PROFILE" ]; then
    ditto -c -k --keepParent "$APP" dist/notarize-upload.zip
    notarize dist/notarize-upload.zip
    rm -f dist/notarize-upload.zip
    xcrun stapler staple "$APP"
fi

# 2. The updater asset: a zip containing Taction.app at the top level.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "wrote $ZIP"

# 3. The installer: a DMG with the app and an Applications shortcut.
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/.README.txt" <<EOF
Drag Taction to the Applications folder, then open it. It lives in the menu bar.
EOF
hdiutil create -volname "Taction $VERSION" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
# Authority lines only appear at verbosity 2; with pipefail a non-match must not abort the script.
IDENTITY="$( { codesign -dvv "$APP" 2>&1 | grep -o 'Authority=Developer ID Application: [^)]*)' | head -1 | sed 's/Authority=//'; } || true)"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if [ -n "$PROFILE" ]; then notarize "$DMG"; xcrun stapler staple "$DMG"; fi
fi
echo "wrote $DMG"

echo
echo "Release checklist:"
echo "  git tag v$VERSION && git push --tags"
echo "  create the GitHub release for tag v$VERSION on $(plutil -extract TactionUpdateRepo raw "$APP/Contents/Info.plist")"
echo "  upload $ZIP (the updater looks for Taction-*.zip) and $DMG"

#!/bin/bash
# Run the unit tests. The Command Line Tools ship Swift Testing but SwiftPM cannot find it
# from there, so tests need Xcode's toolchain. This selects it for this process only.
set -euo pipefail
cd "$(dirname "$0")/.."
XCODE="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$XCODE" ]; then
    echo "Xcode not found at $XCODE; set DEVELOPER_DIR or install Xcode to run tests" >&2
    exit 1
fi
DEVELOPER_DIR="$XCODE" exec swift test "$@"

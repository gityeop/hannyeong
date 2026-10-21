#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "usage: $0 <notarized Hannyeong.app> <new output directory>" >&2; exit 2; fi
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_APP="$1"
TASK_OUT="$2"
TASK_TOOLS="$TASK_ROOT/.build/artifacts/sparkle/Sparkle/bin"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
[[ ! -e "$TASK_OUT" ]] || { echo "output already exists: $TASK_OUT" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$TASK_APP"
xcrun stapler validate "$TASK_APP"
mkdir -p "$TASK_OUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TASK_APP" "$TASK_OUT/Hannyeong-$TASK_VERSION-arm64.zip"
"$TASK_TOOLS/generate_appcast" --account com.yeop.inputmethod.Hannyeong \
    --download-url-prefix "https://github.com/gityeop/hannyeong/releases/download/v$TASK_VERSION/" \
    --link https://gityeop.github.io/hannyeong/ "$TASK_OUT"
echo "Signed update archive and appcast prepared in: $TASK_OUT"

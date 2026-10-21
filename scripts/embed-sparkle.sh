#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "usage: $0 <app> <Sparkle.framework>" >&2; exit 2; fi
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_APP="$1"
TASK_FRAMEWORK="$TASK_APP/Contents/Frameworks/Sparkle.framework"
TASK_IDENTITY="${HANNYEONG_SIGN_IDENTITY:-Developer ID Application: Sang Yeop Lim (79Q5RV23F9)}"
mkdir -p "$TASK_APP/Contents/Frameworks" "$TASK_APP/Contents/Resources/ThirdParty"
/usr/bin/ditto "$2" "$TASK_FRAMEWORK"
cp "$TASK_ROOT/Resources/Hannyeong/Sparkle-LICENSE" "$TASK_APP/Contents/Resources/ThirdParty/Sparkle-LICENSE"
for TASK_CODE in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    /usr/bin/codesign --force --sign "$TASK_IDENTITY" --options runtime --timestamp \
        --preserve-metadata=entitlements "$TASK_FRAMEWORK/Versions/B/$TASK_CODE"
done
/usr/bin/codesign --force --sign "$TASK_IDENTITY" --options runtime --timestamp "$TASK_FRAMEWORK"
/usr/bin/codesign --verify --deep --strict "$TASK_FRAMEWORK"

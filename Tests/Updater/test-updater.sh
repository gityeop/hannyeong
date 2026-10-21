#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
export PKG_CONFIG_PATH="$TASK_ROOT/.build/dependencies/libhangul/lib/pkgconfig"
swift build --product Hannyeong
TASK_PRODUCTS="$(swift build --show-bin-path)"
TASK_QA="$(mktemp -d /private/tmp/hannyeong-updater-qa.XXXXXX)"
trap 'rm -rf "$TASK_QA"' EXIT
TASK_APP="$TASK_QA/UpdaterQA.app"
mkdir -p "$TASK_APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 \
    -F "$TASK_PRODUCTS" -framework Sparkle -framework AppKit -framework SwiftUI \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Hannyeong/AppUpdater.swift Sources/Hannyeong/UpdateSettingsView.swift \
    Sources/Hannyeong/SettingsAppearance.swift Tests/Updater/UpdaterQA.swift \
    -o "$TASK_APP/Contents/MacOS/UpdaterQA"
xcrun swiftc -parse-as-library -swift-version 5 \
    -F "$TASK_PRODUCTS" -framework Sparkle -framework AppKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Hannyeong/AppUpdater.swift Tests/Updater/InstallQA.swift -o "$TASK_QA/InstallQA"
xcrun swiftc Tests/Updater/FixtureSigner.swift -o "$TASK_QA/FixtureSigner"
python3 Tests/Updater/run-fixture.py "$TASK_ROOT" "$TASK_QA" "$TASK_PRODUCTS"

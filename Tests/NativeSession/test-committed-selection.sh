#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
TASK_QA="$TASK_ROOT/.build/committed-selection-qa"
TASK_HOST="$TASK_QA/CommittedSelectionHost.app"
mkdir -p "$TASK_HOST/Contents/MacOS"
cat > "$TASK_HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.yeop.hannyeong.tests.committedselection</string>
<key>CFBundleExecutable</key><string>CommittedSelectionHost</string>
<key>CFBundleName</key><string>Hannyeong Committed Selection QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang -dynamiclib Tests/NativeSession/DelayedAXRange.c -framework ApplicationServices \
    -install_name @rpath/libDelayedAXRange.dylib -o "$TASK_QA/libDelayedAXRange.dylib"
xcrun swiftc -parse-as-library -swift-version 5 Tests/NativeSession/CommittedSelectionHost.swift \
    -o "$TASK_HOST/Contents/MacOS/CommittedSelectionHost"
xcrun swiftc -parse-as-library -swift-version 5 Sources/Hannyeong/CommittedTextSelection.swift \
    Tests/NativeSession/CommittedSelectionQA.swift -L "$TASK_QA" -lDelayedAXRange \
    -Xlinker -rpath -Xlinker "$TASK_QA" -o "$TASK_QA/CommittedSelectionQA"
"$TASK_QA/CommittedSelectionQA" "$TASK_HOST/Contents/MacOS/CommittedSelectionHost"

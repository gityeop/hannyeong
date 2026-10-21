#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
TASK_APP="$TASK_ROOT/.build/secure-input-qa/SecureInputQA.app"
mkdir -p "$TASK_APP/Contents/MacOS"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.yeop.HannyeongSecureInputQA</string>
<key>CFBundleExecutable</key><string>SecureInputQA</string>
<key>CFBundleName</key><string>SecureInputQA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun swiftc Tests/NativeSession/SecureInputSourceQA.swift -o "$TASK_APP/Contents/MacOS/SecureInputQA"
"$TASK_APP/Contents/MacOS/SecureInputQA"

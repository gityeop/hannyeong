#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_QA="$TASK_ROOT/.build/direct-secure-input"
mkdir -p "$TASK_QA"
xcrun swiftc -parse-as-library -swift-version 5 \
    "$TASK_ROOT/Sources/HannyeongInputRuntime/DirectSecureInputSource.swift" \
    "$TASK_ROOT/Tests/DirectInput/DirectSecureInputQA.swift" \
    -framework AppKit -framework Carbon -o "$TASK_QA/DirectSecureInputQA"
"$TASK_QA/DirectSecureInputQA"
xcrun swiftc -parse-as-library -swift-version 5 \
    "$TASK_ROOT/Sources/HannyeongInputRuntime/SudoPasswordProbe.swift" \
    "$TASK_ROOT/Tests/DirectInput/SudoPasswordProbeQA.swift" \
    -o "$TASK_QA/SudoPasswordProbeQA"
"$TASK_QA/SudoPasswordProbeQA"

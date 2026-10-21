#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
TASK_OUT="$TASK_ROOT/.build/browser-session-qa"
mkdir -p "$TASK_OUT"
xcrun swiftc -parse-as-library TypingLab/Sources/TypingLabCore/Keyboard.swift \
    Tests/BrowserSession/BrowserQA.swift -o "$TASK_OUT/BrowserQA"
open -a 'Google Chrome' "$TASK_ROOT/Tests/BrowserSession/fixture.html"
"$TASK_OUT/BrowserQA" "$TASK_OUT/textarea-results.json" "$@"
open -a 'Google Chrome' "$TASK_ROOT/Tests/BrowserSession/fixture-rich.html"
"$TASK_OUT/BrowserQA" "$TASK_OUT/rich-text-results.json" "$@"

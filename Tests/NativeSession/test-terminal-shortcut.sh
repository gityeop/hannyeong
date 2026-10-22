#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <absolute local-runtime.json>" >&2; exit 2; }
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
export PKG_CONFIG_PATH="$TASK_ROOT/.build/dependencies/libhangul/lib/pkgconfig"
swift build --product Hannyeong
TASK_PRODUCTS="$(swift build --show-bin-path)"
TASK_QA="$TASK_ROOT/.build/terminal-shortcut-qa"
mkdir -p "$TASK_QA"
xcrun clang -c Tests/NativeSession/NativeTextView.m -o "$TASK_QA/NativeTextView.o" -Wno-protocol
TASK_SOURCES=()
for TASK_SOURCE in Sources/Hannyeong/*.swift; do
    [[ "$TASK_SOURCE" == */Application.swift ]] || TASK_SOURCES+=("$TASK_SOURCE")
done
for TASK_TEST in TerminalShortcutQA RightCommandQA; do
    xcrun swiftc -parse-as-library -swift-version 5 -O \
        -I "$TASK_PRODUCTS" -I Sources/CLibHangul -I .build/dependencies/libhangul/include \
        -L "$TASK_PRODUCTS" -lHannyeongCore -L .build/dependencies/libhangul/lib -lhangul \
        -F "$TASK_PRODUCTS" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_PRODUCTS" \
        -framework AppKit -framework InputMethodKit -framework Carbon \
        -import-objc-header Tests/NativeSession/NativeTextView.h \
        "${TASK_SOURCES[@]}" "Tests/NativeSession/$TASK_TEST.swift" \
        "$TASK_QA/NativeTextView.o" -o "$TASK_QA/$TASK_TEST"
    "$TASK_QA/$TASK_TEST" "$1"
done

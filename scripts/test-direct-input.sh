#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_QA="$TASK_ROOT/.build/direct-input-qa"
cd "$TASK_ROOT"
mkdir -p "$TASK_QA/source" "$TASK_QA/products"
git archive HEAD Sources/HannyeongCore | tar -x -C "$TASK_QA/source"
xcrun swiftc -parse-as-library -swift-version 5 -O -emit-library -static -emit-module -module-name HannyeongCore \
    -I Sources/CLibHangul -I .build/dependencies/libhangul/include/hangul-1.0 \
    -L .build/dependencies/libhangul/lib -lhangul \
    "$TASK_QA/source/Sources/HannyeongCore/"*.swift \
    -emit-module-path "$TASK_QA/products/HannyeongCore.swiftmodule" -o "$TASK_QA/products/libHannyeongCore.a"
TASK_SOURCES=()
for TASK_SOURCE in Sources/HannyeongInputRuntime/*.swift; do
    TASK_SOURCES+=("$TASK_SOURCE")
done
xcrun swiftc -parse-as-library -swift-version 5 -D DIRECT_INPUT_QA \
    -I "$TASK_QA/products" -I Sources/CLibHangul -I .build/dependencies/libhangul/include/hangul-1.0 \
    -L "$TASK_QA/products" -lHannyeongCore -L .build/dependencies/libhangul/lib -lhangul \
    -framework AppKit -framework Carbon \
    "${TASK_SOURCES[@]}" Sources/Hannyeong/CorrectionStore.swift Tests/DirectInput/DirectInputQA.swift -o "$TASK_QA/DirectInputQA"
"$TASK_QA/DirectInputQA" "$HOME/Library/Input Methods/Hannyeong.app/Contents/Resources"

#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <bundle ID> <expected suffix> <panel|active>" >&2; exit 2; }
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
export PKG_CONFIG_PATH="$TASK_ROOT/.build/dependencies/libhangul/lib/pkgconfig"
swift build --product Hannyeong
TASK_PRODUCTS="$(swift build --show-bin-path)"
TASK_QA="$TASK_ROOT/.build/oncast-input-qa"
mkdir -p "$TASK_QA"
TASK_SOURCES=()
for TASK_SOURCE in Sources/Hannyeong/*.swift; do
    [[ "$TASK_SOURCE" == */Application.swift ]] || TASK_SOURCES+=("$TASK_SOURCE")
done
xcrun swiftc -parse-as-library -swift-version 5 -O \
    -I "$TASK_PRODUCTS" -I Sources/CLibHangul -I .build/dependencies/libhangul/include \
    -L "$TASK_PRODUCTS" -lHannyeongCore -L .build/dependencies/libhangul/lib -lhangul \
    -F "$TASK_PRODUCTS" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_PRODUCTS" \
    -framework AppKit -framework InputMethodKit -framework Carbon \
    "${TASK_SOURCES[@]}" Tests/NativeSession/InputTargetQA.swift -o "$TASK_QA/InputTargetQA"
"$TASK_QA/InputTargetQA" "$@"

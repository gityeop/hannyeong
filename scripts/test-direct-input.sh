#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_QA="$TASK_ROOT/.build/direct-input-qa"
cd "$TASK_ROOT"
mkdir -p "$TASK_QA/products"
products="$TASK_QA/products"
hangul=.build/dependencies/libhangul
module_flags=(-parse-as-library -swift-version 5 -I Sources/CLibHangul -I "$hangul/include/hangul-1.0" -I "$products" -L "$products" -L "$hangul/lib")
xcrun swiftc "${module_flags[@]}" -O -emit-library -static -emit-module -module-name HannyeongCore \
    Sources/HannyeongCore/*.swift -emit-module-path "$products/HannyeongCore.swiftmodule" -o "$products/libHannyeongCore.a"
xcrun swiftc "${module_flags[@]}" -D DIRECT_INPUT_QA -enable-testing -emit-library -static -emit-module -module-name HannyeongInputRuntime \
    Sources/HannyeongInputRuntime/*.swift -emit-module-path "$products/HannyeongInputRuntime.swiftmodule" -o "$products/libHannyeongInputRuntime.a"
xcrun clang -fobjc-arc -Wno-protocol -c Tests/NativeSession/NativeTextView.m -o "$TASK_QA/NativeTextView.o"
xcrun swiftc "${module_flags[@]}" -import-objc-header Tests/NativeSession/NativeTextView.h \
    -lHannyeongInputRuntime -lHannyeongCore -lhangul -framework AppKit -framework Carbon -framework InputMethodKit \
    Sources/Hannyeong/{CorrectionStore,NativeNotionOutput}.swift Tests/NativeSession/CachedSelectionTextView.swift \
    Tests/DirectInput/DirectInputQA.swift "$TASK_QA/NativeTextView.o" -o "$TASK_QA/DirectInputQA"
if [[ $# == 0 ]]; then
    set -- "$HOME/Library/Input Methods/Hannyeong.app/Contents/Resources"
fi
"$TASK_QA/DirectInputQA" "$@"

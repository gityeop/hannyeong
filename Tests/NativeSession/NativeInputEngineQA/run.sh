#!/bin/bash
set -euo pipefail
qa_root="$(cd "$(dirname "$0")" && pwd -P)"
source_root="$(cd "$qa_root/../../.." && pwd -P)"
qa_build="$source_root/.build/native-input-engine-qa"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
mkdir -p "$qa_build"
xcrun swiftc -emit-library -emit-module -module-name HannyeongCore \
    "$qa_root/CoreStub.swift" -o "$qa_build/libHannyeongCore.dylib" \
    -emit-module-path "$qa_build/HannyeongCore.swiftmodule"
xcrun swiftc -emit-library -emit-module -module-name HannyeongInputRuntime \
    "$qa_root/RuntimeStub.swift" -o "$qa_build/libHannyeongInputRuntime.dylib" \
    -emit-module-path "$qa_build/HannyeongInputRuntime.swiftmodule"
xcrun clang -fobjc-arc -c -I "$source_root/Tests/NativeSession" \
    "$source_root/Tests/NativeSession/NativeTextView.m" -o "$qa_build/NativeTextView.o"
xcrun clang -fobjc-arc -c -I "$source_root/Tests/NativeSession" \
    "$qa_root/CoordinatorView.m" -o "$qa_build/CoordinatorView.o"
xcrun swiftc -parse-as-library -swift-version 5 \
    -I "$qa_build" -I "$source_root/Tests/NativeSession" \
    -L "$qa_build" -lHannyeongCore -lHannyeongInputRuntime \
    -Xlinker -rpath -Xlinker "$qa_build" \
    -import-objc-header "$qa_root/CoordinatorView.h" \
    "$source_root/Sources/Hannyeong/NativeInputEngine.swift" \
    "$source_root/Sources/Hannyeong/NativeNotionOutput.swift" \
    "$qa_root/AppStubs.swift" "$qa_root/CoordinatorQA.swift" \
    "$qa_build/NativeTextView.o" "$qa_build/CoordinatorView.o" \
    -framework AppKit -framework InputMethodKit -framework Carbon \
    -o "$qa_build/CoordinatorQA"
"$qa_build/CoordinatorQA"

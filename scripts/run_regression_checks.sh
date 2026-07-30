#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

MODULE_CACHE="$PROJECT_DIR/.build/$(uname -m)-apple-macosx/debug/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

TTS_DEVELOPER_ROOT="$(xcode-select -p)"
TTS_TESTING_FRAMEWORKS="$TTS_DEVELOPER_ROOT/Library/Developer/Frameworks"
TTS_TESTING_LIBRARIES="$TTS_DEVELOPER_ROOT/Library/Developer/usr/lib"

swift test \
    --disable-sandbox \
    -Xswiftc -F \
    -Xswiftc "$TTS_TESTING_FRAMEWORKS" \
    -Xlinker -F \
    -Xlinker "$TTS_TESTING_FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$TTS_TESTING_FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$TTS_TESTING_LIBRARIES"

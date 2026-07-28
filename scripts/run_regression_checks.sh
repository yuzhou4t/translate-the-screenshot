#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

MODULE_CACHE="$PROJECT_DIR/.build/$(uname -m)-apple-macosx/debug/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swift test --disable-sandbox

BIN_DIR="$(swift build --show-bin-path)"
TEST_BINARY="$BIN_DIR/ttsPackageTests.xctest/Contents/MacOS/ttsPackageTests"

if [[ ! -f "$TEST_BINARY" ]]; then
    echo "Regression test bundle not found: $TEST_BINARY" >&2
    exit 1
fi

python3 -c 'import ctypes, sys; library = ctypes.CDLL(sys.argv[1]); run = library.runTTSPackageRegressionChecks; run.argtypes = []; run.restype = None; run()' "$TEST_BINARY"

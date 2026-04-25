#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/build/Release/TTS.app"
EXECUTABLE="${ROOT_DIR}/.build/release/tts"

cd "${ROOT_DIR}"

swift build -c release

rm -rf "${APP_DIR}" "${ROOT_DIR}/build/Release/tts.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/TTS"
chmod +x "${APP_DIR}/Contents/MacOS/TTS"
cp "${ROOT_DIR}/App/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp "${ROOT_DIR}/App/Resources/MenuBarIconTemplate.png" "${APP_DIR}/Contents/Resources/MenuBarIconTemplate.png"

sed \
  -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
  -e 's/$(EXECUTABLE_NAME)/TTS/g' \
  -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.yuzhou4tc.tts/g' \
  "${ROOT_DIR}/App/Info.plist" > "${APP_DIR}/Contents/Info.plist"

/usr/bin/codesign --force --sign - "${APP_DIR}" >/dev/null

echo "${APP_DIR}"

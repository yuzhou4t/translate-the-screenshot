#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/build/Release/TTS.app"
EXECUTABLE="${ROOT_DIR}/.build/release/tts"
DEFAULT_LOCAL_IDENTITY="TTS Local Code Signing"
CODESIGN_IDENTITY="${TTS_CODESIGN_IDENTITY:-}"

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

if [[ -z "${CODESIGN_IDENTITY}" ]]; then
  if /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "\"${DEFAULT_LOCAL_IDENTITY}\"" >/dev/null 2>&1; then
    CODESIGN_IDENTITY="${DEFAULT_LOCAL_IDENTITY}"
  else
    CODESIGN_IDENTITY="-"
  fi
fi

/usr/bin/codesign --force --sign "${CODESIGN_IDENTITY}" "${APP_DIR}" >/dev/null

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "warning: signed with adhoc identity; run scripts/create_local_codesign_identity.sh to keep macOS permissions stable." >&2
else
  echo "signed with ${CODESIGN_IDENTITY}" >&2
fi

echo "${APP_DIR}"

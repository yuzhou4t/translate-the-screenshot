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
    echo "error: no stable code signing identity found." >&2
    echo "run scripts/create_local_codesign_identity.sh, or explicitly set TTS_CODESIGN_IDENTITY=- for a disposable build." >&2
    exit 1
  fi
fi

/usr/bin/codesign --force --sign "${CODESIGN_IDENTITY}" "${APP_DIR}" >/dev/null

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "warning: explicitly signed with an adhoc identity; macOS permissions will not persist across rebuilds." >&2
else
  echo "signed with ${CODESIGN_IDENTITY}" >&2
fi

echo "${APP_DIR}"

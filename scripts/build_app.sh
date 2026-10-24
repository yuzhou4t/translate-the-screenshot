#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/build/Release/TTS.app"
DEFAULT_LOCAL_IDENTITY="TTS Local Code Signing"
CODESIGN_IDENTITY="${TTS_CODESIGN_IDENTITY:-}"

cd "${ROOT_DIR}"

# Keep compiler caches inside the project, including in restricted environments.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${ROOT_DIR}/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${CLANG_MODULE_CACHE_PATH}}"

if [[ -z "${CODESIGN_IDENTITY}" ]]; then
  if /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "\"${DEFAULT_LOCAL_IDENTITY}\"" >/dev/null 2>&1; then
    CODESIGN_IDENTITY="${DEFAULT_LOCAL_IDENTITY}"
  else
    echo "error: no stable code signing identity found." >&2
    echo "run scripts/create_local_codesign_identity.sh, or explicitly set TTS_CODESIGN_IDENTITY=- for a disposable build." >&2
    exit 1
  fi
fi

BUILD_ARGS=(-c release --disable-sandbox -debug-info-format none)
if [[ "${TTS_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64 --scratch-path "${ROOT_DIR}/build/universal")
fi
swift build "${BUILD_ARGS[@]}"
EXECUTABLE="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/tts"

rm -rf "${APP_DIR}" "${ROOT_DIR}/build/Release/tts.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/TTS"
chmod +x "${APP_DIR}/Contents/MacOS/TTS"
cp "${ROOT_DIR}/App/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp "${ROOT_DIR}/App/Resources/MenuBarIconTemplate.png" "${APP_DIR}/Contents/Resources/MenuBarIconTemplate.png"
cp "${ROOT_DIR}/App/Resources/ProviderIcon-codex.svg" "${APP_DIR}/Contents/Resources/ProviderIcon-codex.svg"
cp "${ROOT_DIR}/App/Resources/ProviderIcon-grok.svg" "${APP_DIR}/Contents/Resources/ProviderIcon-grok.svg"
cp "${ROOT_DIR}/App/Resources/ProviderIcon-deepseek.svg" "${APP_DIR}/Contents/Resources/ProviderIcon-deepseek.svg"
cp "${ROOT_DIR}/App/Resources/ProviderIcon-minimax.svg" "${APP_DIR}/Contents/Resources/ProviderIcon-minimax.svg"
cp "${ROOT_DIR}/App/Resources/ProviderIcon-antigravity.svg" "${APP_DIR}/Contents/Resources/ProviderIcon-antigravity.svg"
cp "${ROOT_DIR}/App/Resources/ProviderIcons-NOTICE.txt" "${APP_DIR}/Contents/Resources/ProviderIcons-NOTICE.txt"
cp "${ROOT_DIR}/App/Resources/CodexAccountSwitcher-NOTICE.txt" "${APP_DIR}/Contents/Resources/CodexAccountSwitcher-NOTICE.txt"

sed \
  -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
  -e 's/$(EXECUTABLE_NAME)/TTS/g' \
  -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.yuzhou4tc.tts/g' \
  "${ROOT_DIR}/App/Info.plist" > "${APP_DIR}/Contents/Info.plist"

/usr/bin/codesign --force --sign "${CODESIGN_IDENTITY}" "${APP_DIR}" >/dev/null

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "warning: ad hoc signature; not Developer ID signed or notarized. Permissions may need to be granted again after updates." >&2
else
  echo "signed with ${CODESIGN_IDENTITY}" >&2
fi

echo "${APP_DIR}"

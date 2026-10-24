#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/App/Info.plist")"
OUTPUT_DIR="${ROOT_DIR}/build/releases/v${VERSION}"
APP_DIR="${ROOT_DIR}/build/Release/TTS.app"
ASSET_NAME="TTS-${VERSION}-macOS-universal"

# Distributable builds use an explicit ad hoc signature until Developer ID
# signing and notarization are configured. Never include local credentials.
TTS_UNIVERSAL=1 TTS_CODESIGN_IDENTITY=- "${ROOT_DIR}/scripts/build_app.sh"
/usr/bin/lipo "${APP_DIR}/Contents/MacOS/TTS" -verify_arch arm64
/usr/bin/lipo "${APP_DIR}/Contents/MacOS/TTS" -verify_arch x86_64
/usr/bin/codesign --verify --deep --strict "${APP_DIR}"

mkdir -p "${OUTPUT_DIR}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${OUTPUT_DIR}/${ASSET_NAME}.zip"
cp "${ROOT_DIR}/docs/INSTALL.md" "${OUTPUT_DIR}/INSTALL.md"

STAGING_DIR="$(mktemp -d "${ROOT_DIR}/build/dmg.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
/usr/bin/ditto "${APP_DIR}" "${STAGING_DIR}/TTS.app"
ln -s /Applications "${STAGING_DIR}/Applications"
cp "${ROOT_DIR}/docs/INSTALL.md" "${STAGING_DIR}/安装说明.md"
/usr/bin/hdiutil create -volname "TTS ${VERSION}" -srcfolder "${STAGING_DIR}" \
  -ov -format UDZO "${OUTPUT_DIR}/${ASSET_NAME}.dmg"

echo "Release assets: ${OUTPUT_DIR}"

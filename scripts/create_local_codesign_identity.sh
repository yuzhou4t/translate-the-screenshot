#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${TTS_LOCAL_CODESIGN_IDENTITY:-TTS Local Code Signing}"
KEYCHAIN="${TTS_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"
P12_PASSWORD="${TTS_LOCAL_CODESIGN_P12_PASSWORD:-tts-local-codesign}"
TMP_DIR="$(/usr/bin/mktemp -d)"

cleanup() {
  /bin/rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if /usr/bin/security find-identity -v -p codesigning "${KEYCHAIN}" | /usr/bin/grep -F "\"${IDENTITY_NAME}\"" >/dev/null 2>&1; then
  echo "${IDENTITY_NAME}"
  exit 0
fi

OPENSSL_CONFIG="${TMP_DIR}/openssl.cnf"
PRIVATE_KEY="${TMP_DIR}/identity.key"
CERTIFICATE="${TMP_DIR}/identity.crt"
P12="${TMP_DIR}/identity.p12"

/bin/cat > "${OPENSSL_CONFIG}" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${IDENTITY_NAME}

[v3_req]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req \
  -newkey rsa:2048 \
  -nodes \
  -keyout "${PRIVATE_KEY}" \
  -x509 \
  -days 3650 \
  -out "${CERTIFICATE}" \
  -config "${OPENSSL_CONFIG}" \
  -sha256 >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
  -export \
  -name "${IDENTITY_NAME}" \
  -inkey "${PRIVATE_KEY}" \
  -in "${CERTIFICATE}" \
  -out "${P12}" \
  -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1

/usr/bin/security import "${P12}" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASSWORD}" \
  -T /usr/bin/codesign >/dev/null

/usr/bin/security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${KEYCHAIN}" \
  "${CERTIFICATE}" >/dev/null

echo "${IDENTITY_NAME}"

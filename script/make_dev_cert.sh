#!/usr/bin/env bash
set -euo pipefail

# Creates a stable, self-signed code-signing certificate ("MonitorFlux Dev") in your login
# keychain. Run it ONCE.
#
# Why: build_and_run.sh otherwise ad-hoc signs the app, and an ad-hoc signature's code hash
# changes on every rebuild. macOS ties the Accessibility (and Screen Recording) permission to
# the app's code identity, so each rebuild looks like a "new" app and the grant is dropped —
# which is why the media-key keyboard control silently stops working after a rebuild. A stable
# certificate keeps the identity constant, so you grant Accessibility once and it sticks.
#
# After running this, the next ./script/build_and_run.sh signs with the cert. macOS will ask
# ONCE to let codesign use the new key — click "Always Allow". Then grant Accessibility in
# System Settings ▸ Privacy & Security ▸ Accessibility once.
#
# To undo: open Keychain Access ▸ login, delete the "MonitorFlux Dev" certificate.

CERT_NAME="MonitorFlux Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✓ '$CERT_NAME' already exists — build_and_run.sh will use it automatically."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass: -name "$CERT_NAME" >/dev/null 2>&1

# Import the certificate + private key; -T lets codesign use the key without re-prompting
# beyond the first "Always Allow".
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo "✓ Created '$CERT_NAME' in your login keychain."
echo
echo "Next steps:"
echo "  1. ./script/build_and_run.sh   → click \"Always Allow\" when macOS asks about the key."
echo "  2. Grant Accessibility once: System Settings ▸ Privacy & Security ▸ Accessibility."
echo "  It will now persist across rebuilds."

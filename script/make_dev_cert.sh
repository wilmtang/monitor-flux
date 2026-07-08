#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
# Affero General Public License v3.0 or later. See LICENSE. No warranty.

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

# Bundle into a PKCS#12 for `security import`. `-legacy -macalg SHA1` and a real (transient)
# password are required: OpenSSL 3.x's default PKCS#12 MAC (SHA-256) and empty-password
# handling make macOS's `security import` fail with "MAC verification failed".
P12_PASS="monitorflux-dev-import"
openssl pkcs12 -export -legacy -macalg SHA1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" >/dev/null 2>&1

# Import the certificate + private key; -T lets codesign use the key.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "✓ Created '$CERT_NAME' in your login keychain."
echo
echo "Next steps:"
echo "  1. ./script/build_and_run.sh   → click \"Always Allow\" when macOS asks about the key."
echo "  2. Grant Accessibility once: System Settings ▸ Privacy & Security ▸ Accessibility."
echo "  It will now persist across rebuilds."

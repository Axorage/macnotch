#!/bin/bash
# One-time helper: create a self-signed code-signing identity named "MacNotch Dev".
# bundle.sh signs with it when present, so the app keeps a stable code identity and
# macOS does not reset Automation / privacy grants on every rebuild.
#
# This script MODIFIES YOUR LOGIN KEYCHAIN. Read it, then run it yourself.
set -euo pipefail
NAME="MacNotch Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
PASS="macnotch-$$"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo
echo "Imported. If codesign reports the identity as untrusted, open Keychain Access,"
echo "double-click \"$NAME\" > Trust > Code Signing: Always Trust."
echo "Then rebuild with scripts/bundle.sh and re-grant Automation once."

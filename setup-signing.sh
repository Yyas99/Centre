#!/bin/bash
# One-time setup: a local code-signing certificate so every rebuild of Centre has the same identity.
# Without it each build is ad-hoc signed, macOS sees a "new" app, and asks for Documents / Accessibility again.
# Run from Centre › Settings › System (or: bash setup-signing.sh). Asks for your Mac password once.
set -euo pipefail

NAME="Centre Local Signing"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Signing identity already in your keychain."
  echo "Signing identity ready."
  exit 0
fi

# A certificate that exists but isn't usable right now (locked keychain, trust not yet set) is never replaced:
# a new certificate is a new identity, and every permission would have to be granted again.
if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "\"$NAME\" is in your keychain but macOS won't use it for signing right now."
  echo "Unlock the login keychain, or open Keychain Access › $NAME › Trust › Code Signing: Always Trust."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Centre Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "Creating certificate…"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout pass:centre


echo "Adding it to your login keychain…"
security import "$TMP/identity.p12" -k "$KC" -P centre -T /usr/bin/codesign >/dev/null

echo "Trusting it for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Signing identity ready."
else
  echo "The certificate was added but macOS doesn't accept it for code signing yet."
  exit 1
fi

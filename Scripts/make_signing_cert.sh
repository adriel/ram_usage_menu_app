#!/bin/bash
# Creates the self-signed "RAM Watch Code Signing" certificate in your login keychain.
# build.sh signs with it, so every build has the same identity: macOS keeps the browser
# (Automation) permission across updates, and the updater only accepts updates signed by it.
#
# Run once per release machine. Back the identity up afterwards (Keychain Access → My
# Certificates → "RAM Watch Code Signing" → Export…): installed copies only accept updates
# signed with this exact certificate.
set -euo pipefail
NAME="RAM Watch Code Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in your keychain."; exit 0
fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cfg" <<CFG
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CFG
openssl req -x509 -newkey rsa:3072 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 7300 -config "$D/cfg" 2>/dev/null
PW=$(openssl rand -hex 24)
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" -out "$D/id.p12" -passout "pass:$PW" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
echo "Created \"$NAME\". It shows as not trusted; that's fine for signing."

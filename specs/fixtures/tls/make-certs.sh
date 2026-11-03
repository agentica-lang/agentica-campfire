#!/bin/sh
# Writes the test-only CA and the certificate of the SMTP peer (specs/fixtures/smtp_peer.agc) next to this script.
# The keys are public test data, never a deployment key; the CA key is not kept. The specs use the checked-in files and
# nothing regenerates them during a run. Needs the `openssl` command.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
days=36500

openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/ca-key.pem"
openssl req -x509 -new -key "$work/ca-key.pem" -subj "/CN=Campfire Test CA" -days "$days" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$dir/ca.pem"

openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/server-key.pem"
openssl req -new -key "$dir/server-key.pem" -subj "/CN=localhost" -out "$work/server.csr"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\n' > "$work/server.ext"
openssl x509 -req -in "$work/server.csr" -CA "$dir/ca.pem" -CAkey "$work/ca-key.pem" -set_serial "0x$(openssl rand -hex 16)" \
  -extfile "$work/server.ext" -days "$days" -out "$dir/server.pem"

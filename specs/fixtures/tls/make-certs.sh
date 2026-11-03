#!/bin/sh
# Writes the test-only CA and the certificates of the SMTP peer (specs/fixtures/smtp_peer.agc) next to this script:
# `server` for localhost, and `wrong-host` for a name that is not the peer's, for the specs of a host name mismatch.
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

leaf() {
  name=$1 cn=$2 san=$3
  openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/$name-key.pem"
  openssl req -new -key "$dir/$name-key.pem" -subj "/CN=$cn" -out "$work/$name.csr"
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san" > "$work/$name.ext"
  openssl x509 -req -in "$work/$name.csr" -CA "$dir/ca.pem" -CAkey "$work/ca-key.pem" -set_serial "0x$(openssl rand -hex 16)" \
    -extfile "$work/$name.ext" -days "$days" -out "$dir/$name.pem"
}

leaf server localhost "DNS:localhost,IP:127.0.0.1,IP:::1"
leaf wrong-host wrong.example "DNS:wrong.example"

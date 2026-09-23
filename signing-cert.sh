#!/bin/bash
# Crea un certificato di firma autofirmato, una volta sola.
#
# Perché: senza identità stabile l'app viene firmata "ad hoc" e macOS la
# considera una app diversa a ogni ricompilazione, quindi richiede di nuovo
# Registrazione schermo e Accessibilità. Con un certificato fisso i permessi
# restano validi tra una build e l'altra.
#
# Non serve un account sviluppatore Apple: il certificato vale solo su questo
# Mac (non sostituisce la notarizzazione per distribuire l'app ad altri).
set -euo pipefail

NAME="${1:-Elsewhere Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✅ Il certificato \"$NAME\" esiste già."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Algoritmi legacy: il PKCS#12 di OpenSSL 3 non è importabile dal portachiavi macOS
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:elsewhere \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -A: codesign può usare la chiave senza chiedere conferma a ogni build
security import "$TMP/id.p12" -k "$KEYCHAIN" -P elsewhere -T /usr/bin/codesign -A >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✅ Certificato \"$NAME\" creato. Ricostruisci l'app: le prossime build"
    echo "   manterranno i permessi di Registrazione schermo e Accessibilità."
else
    echo "❌ Il certificato non risulta utilizzabile. L'app resterà firmata ad hoc."
    exit 1
fi

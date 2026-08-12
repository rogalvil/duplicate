#!/usr/bin/env bash
#
# Creates the self-signed code signing certificate the Makefile looks for.
#
# Why this matters: with ad-hoc signing, the app's designated requirement is
#
#     designated => cdhash H"2ea8395e..."
#
# which is tied to the exact bytes of the binary. TCC stores that requirement, so every code
# change produces a new hash, macOS sees a different app, and every file-access grant has to be
# given again. With this certificate the requirement becomes
#
#     designated => identifier "com.rogalvil.duplicate" and certificate leaf = H"003086..."
#
# which is tied to the bundle identifier and the certificate. Rebuilds keep the grant.
#
# This app reads whole directory trees, so it accumulates grants for Desktop, Documents,
# Downloads and removable volumes. Re-granting all of those after every build is what makes
# the certificate worth the five minutes.
#
# Costs nothing and needs no Apple account. Equivalent to Keychain Access →
# Certificate Assistant → Create a Certificate, but reproducible.

set -euo pipefail

NAME="Duplicate Dev"
BUNDLE_ID="com.rogalvil.duplicate"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "'$NAME' already exists. Nothing to do."
    security find-identity -v -p codesigning | grep -F "\"$NAME\""
    exit 0
fi

workdir="$(mktemp -d)"
# The private key must not outlive this script.
trap 'rm -rf "$workdir"' EXIT

echo "Generating a 10-year self-signed code signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

# Legacy algorithms on purpose. OpenSSL 3 defaults to a newer MAC that Apple's importer rejects
# with "MAC verification failed during PKCS12 import (wrong password?)", which reads like a
# password problem and is not one. A non-empty password avoids a second variant of the same
# failure.
password="duplicate"
openssl pkcs12 -export \
    -out "$workdir/cert.p12" \
    -inkey "$workdir/key.pem" \
    -in "$workdir/cert.pem" \
    -name "$NAME" \
    -passout "pass:$password" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

echo "Importing into the login keychain…"
# -T pre-authorises codesign so signing does not prompt for keychain access on every build.
security import "$workdir/cert.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign

echo "Trusting it for code signing only…"
# `trustRoot` because a self-signed certificate is its own root; `trustAsRoot` is for
# intermediates and fails here with an unhelpful "one or more parameters were not valid".
# Scoped to codeSign and to the user's trust settings, not the system's.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$workdir/cert.pem"

echo
if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
    security find-identity -v -p codesigning | grep -F "\"$NAME\""
    cat <<NEXT

Done. Next:

  1. make            # signs with the new identity
  2. make run
  3. Grant the folders you want to scan in System Settings → Privacy & Security → Files
     and Folders, then relaunch. A TCC grant does not apply to an already-running process.

That grant now survives rebuilds. If the app was previously ad-hoc signed, clear the stale
records first so System Settings does not show an entry that no longer matches:

  tccutil reset SystemPolicyDesktopFolder $BUNDLE_ID
  tccutil reset SystemPolicyDocumentsFolder $BUNDLE_ID
  tccutil reset SystemPolicyDownloadsFolder $BUNDLE_ID
  tccutil reset SystemPolicyRemovableVolumes $BUNDLE_ID
NEXT
else
    echo "The identity did not show up. Check the output above." >&2
    exit 1
fi

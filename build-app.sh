#!/bin/bash
# Builds DualPane.app from source.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Compiling (release)..."
swift build -c release

echo "==> Generating app icon..."
swift make_icon.swift
iconutil -c icns DualPane.iconset -o AppIcon.icns

echo "==> Assembling DualPane.app..."
APP="DualPane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp .build/release/DualPane "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"
# --- Stable code signing -------------------------------------------------
# Ad-hoc signing ("--sign -") gives the app a NEW code hash on every build,
# which makes macOS drop DualPane's Full Disk Access grant — so reading
# iCloud / OneDrive (~/Library/CloudStorage, ~/Library/Mobile Documents)
# breaks after every rebuild. Signing with a STABLE self-signed identity keeps
# the grant valid across rebuilds. The identity is created once, locally, and
# never leaves this Mac.
IDENTITY="DualPane-Dev"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "==> Creating one-time self-signed signing identity '$IDENTITY'..."
    TMP="$(mktemp -d)"
    cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $IDENTITY
[ ext ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -config "$TMP/cert.conf" >/dev/null 2>&1
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/cert.p12" -passout pass: -name "$IDENTITY" >/dev/null 2>&1
    security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "" -T /usr/bin/codesign >/dev/null 2>&1
    rm -rf "$TMP"
fi

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "==> Done: $(pwd)/$APP  (signed with '$IDENTITY')"
echo
echo "First build only: grant DualPane.app Full Disk Access once"
echo "(System Settings > Privacy & Security > Full Disk Access). Because the"
echo "signature is now stable, that grant will survive every future rebuild,"
echo "so iCloud and OneDrive stay readable."

#!/usr/bin/env bash
# Creates the Android signing key ONCE and prints the 3 GitHub secrets.
# Run it on your own computer, not on a shared server. Needs Java (keytool).
set -euo pipefail
OUT="${1:-tamween.jks}"
command -v keytool >/dev/null || { echo "keytool not found. Install Java 17 (or Android Studio) first."; exit 1; }
if [ -e "$OUT" ]; then
  echo "$OUT already exists. Not overwriting it: replacing the key breaks app updates on every device."
  exit 1
fi
read -rsp "Key password (8+ characters): " PW; echo
read -rsp "Repeat password: " PW2; echo
[ "$PW" = "$PW2" ] || { echo "Passwords do not match."; exit 1; }
[ ${#PW} -ge 8 ] || { echo "Password must be at least 8 characters."; exit 1; }
keytool -genkeypair -keystore "$OUT" -storetype PKCS12 -alias tamween -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass "$PW" -keypass "$PW" -dname "CN=Tamween, O=Tamween, C=KW" >/dev/null
base64 < "$OUT" | tr -d '\n' > "$OUT.b64"
echo
echo "Created $OUT and $OUT.b64"
echo "Add these in GitHub: Settings > Secrets and variables > Actions > New repository secret"
echo "  ANDROID_KEYSTORE_BASE64   = contents of $OUT.b64"
echo "  ANDROID_KEYSTORE_PASSWORD = the password you just typed"
echo "  ANDROID_KEY_ALIAS         = tamween"
echo
echo "Keep $OUT and the password somewhere safe (USB drive, password manager)."
echo "Delete $OUT.b64 after adding the secret. Never commit either file."

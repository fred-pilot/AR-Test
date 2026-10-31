#!/usr/bin/env bash
# Baut eine unsignierte OffroadAR.ipa zum Installieren mit Sideloadly oder AltStore.
# Läuft auf dem eigenen Mac (ab Xcode 15.2) und in GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${OUT_DIR:-build}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if command -v xcodegen >/dev/null 2>&1; then
  XCODEGEN=xcodegen
elif [ -x tools/xcodegen/bin/xcodegen ]; then
  XCODEGEN=tools/xcodegen/bin/xcodegen
else
  echo "XcodeGen fehlt. Installieren mit:"
  echo "  curl -L -o /tmp/xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip"
  echo "  unzip -q -o /tmp/xcodegen.zip -d tools"
  exit 1
fi

echo "Xcode: $(xcodebuild -version | head -n 1)"
"$XCODEGEN" generate

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/Payload"

xcodebuild archive \
  -project OffroadAR.xcodeproj \
  -scheme OffroadAR \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT_DIR/OffroadAR.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  -quiet

cp -R "$OUT_DIR/OffroadAR.xcarchive/Products/Applications/OffroadAR.app" "$OUT_DIR/Payload/"
(cd "$OUT_DIR" && zip -qr OffroadAR.ipa Payload)
echo "Fertig: $OUT_DIR/OffroadAR.ipa"

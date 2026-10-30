#!/bin/zsh
# Packs MCRenderTest into an UNSIGNED .ipa (TrollStore-ready; no Apple ID, no
# provisioning, no -allowProvisioningUpdates). TrollStore installs unsigned
# ipas directly and signs them on-device.
#
# Usage:  scripts/build_ipa_unsigned.sh
# Output: build-ios-ipa/MCRenderTest.ipa
set -euo pipefail

ROOT="${0:a:h:h}"
PROJ="$ROOT/build-ios-xcode/MetalCompat.xcodeproj"
OUT="$ROOT/build-ios-ipa"
APP_MEMBER="MCRenderTest.app"

mkdir -p "$OUT"
cmake -S "$ROOT" -B "$ROOT/build-ios-xcode" >/dev/null

xcodebuild -project "$PROJ" -target MCRenderTest -configuration Release \
  -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  CODE_SIGNING_REQUIRED=NO STRIP_BITCODE_FROM_COPIED_FILES=NO \
  clean build

BUILT_APP="$(find "$ROOT/build-ios-xcode" -maxdepth 5 -type d -name "$APP_MEMBER" \
  -path "*Release-iphoneos*" | head -1)"
if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
  echo "ERROR: app bundle not produced under build-ios-xcode (Release-iphoneos)"
  exit 1
fi

# Payload/MCRenderTest.app -> MCRenderTest.ipa (plain zip, TrollStore-ready)
STAGE="$OUT/Payload"
rm -rf "$STAGE" "$OUT/MCRenderTest.ipa"
mkdir -p "$STAGE"
cp -R "$BUILT_APP" "$STAGE/"
cd "$OUT" && zip -qry "$OUT/MCRenderTest.ipa" Payload && cd "$ROOT"
rm -rf "$STAGE"
rmdir "$OUT/build" 2>/dev/null || true

codesign_report=$(codesign -dv "$BUILT_APP" 2>&1 | head -1)
echo "App built : $BUILT_APP"
echo "Signature : $codesign_report"
echo "IPA ready : $OUT/MCRenderTest.ipa"
echo "Install via TrollStore (AirDrop/Files -> Share -> TrollStore)."

#!/bin/zsh
# Builds the MCRenderTest iOS app and packs it into an installable .ipa.
#
# Requires a signed-in Apple ID in Xcode (Settings > Accounts). The device gets
# registered and a free-personal-team profile is created automatically with
# -allowProvisioningUpdates (7-day certificate validity).
#
# Usage:
#   scripts/build_ios_ipa.sh                 # team auto-detected from Xcode
#   MC_IOS_DEV_TEAM=ABCD1234 scripts/build_ios_ipa.sh
# Output:
#   build-ios-ipa/MCRenderTest.ipa
set -euo pipefail

ROOT="${0:a:h:h}"
PROJ="$ROOT/build-ios-xcode/MetalCompat.xcodeproj"
ARCHIVE="$ROOT/build-ios-ipa/MCRenderTest.xcarchive"
IPA_DIR="$ROOT/build-ios-ipa"

TEAM="${MC_IOS_DEV_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  # fall back to the first valid signing identity's team (10-char Apple ID team)
  TEAM=$(security find-identity -v -p codesigning 2>/dev/null |
    grep -oE '[A-Z0-9]{10}\)' | tr -d ')' | head -1 || true)
fi
if [[ -z "$TEAM" ]]; then
  echo "ERROR: no Apple development team found."
  echo "  1) Open Xcode > Settings > Accounts and sign in with your Apple ID."
  echo "  2) Then run: MC_IOS_DEV_TEAM=<teamid> $0"
  echo "  (team id = the 10-char code listed under your account in Xcode)"
  exit 1
fi
echo "Signing with development team: $TEAM"

cmake -S "$ROOT" -B "$ROOT/build-ios-xcode" >/dev/null

xcodebuild -project "$PROJ" -scheme MCRenderTest -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
  -archivePath "$ARCHIVE" archive

EXPORT_OPTS="$IPA_DIR/ExportOptions.plist"
mkdir -p "$IPA_DIR"
cp "$ROOT/scripts/ExportOptions.plist" "$EXPORT_OPTS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM" "$EXPORT_OPTS"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$IPA_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates

IPA="$IPA_DIR/MCRenderTest.ipa"
if [[ ! -f "$IPA" ]]; then
  echo "ERROR: .ipa not produced; check the xcodebuild output above."
  exit 1
fi
echo ""
echo "IPA ready: $IPA"
echo "Install on a paired device with:"
echo "  scripts/install_ios_device.sh"

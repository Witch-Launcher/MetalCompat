#!/bin/zsh
# Installs + launches MCRenderTest.ipa on the paired iPhone via devicectl.
# Usage: scripts/install_ios_device.sh [device-udid]   (default: first paired iPhone)
set -euo pipefail

ROOT="${0:a:h:h}"
IPA="$ROOT/build-ios-ipa/MCRenderTest.ipa"
APP_ID="com.metalcompat.rendertest"

if [[ ! -f "$IPA" ]]; then
  echo "ERROR: $IPA not found. Run scripts/build_ios_ipa.sh first."
  exit 1
fi

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null |
    awk -F'  +' '/iPhone/ && /available/ {print $NF; exit}')
fi
if [[ -z "$DEVICE" ]]; then
  echo "ERROR: no connected device matched."
  echo "  1) Plug the iPhone in (or unlock it for Wi-Fi pairing)."
  echo "  2) List devices:  xcrun devicectl list devices"
  echo "  3) Then: $0 <device-udid>"
  exit 1
fi
echo "Installing $IPA on device $DEVICE ..."
xcrun devicectl device install app --device "$DEVICE" "$IPA"
echo "Launching $APP_ID on $DEVICE ..."
xcrun devicectl device process launch --device "$DEVICE" "$APP_ID"
echo ""
echo "The app streams results on screen and writes to:"
echo "  Documents/MC_TEST_LOG.txt  (add it from Files > On My iPhone > MCRenderTest)"
echo "Share button shares the .txt via the dialog; NSLog lines also appear in"
echo "  Console.app (search for 'MC-LOG')."

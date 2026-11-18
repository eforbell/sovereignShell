#!/usr/bin/env bash
# Archives a Release build of an app target and uploads it to App Store Connect for TestFlight.
# TestFlight builds run without Developer Mode and expire after 90 days.
#   scripts/build-testflight.sh              archive + upload Home Base (Xcode's signed-in account uploads)
#   scripts/build-testflight.sh --no-upload  archive + export an App Store .ipa only (checks signing)
# Optional App Store Connect API key instead of the Xcode account:
#   ASC_KEY_PATH=~/.../AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=uuid scripts/build-testflight.sh
# Needs Config/Local.xcconfig (team and bundle ID) and an App Store Connect app record for that bundle ID.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=HomeBase
DEST=upload
[ "${1:-}" = --no-upload ] && DEST=export
setting() { { sed -nE "s/^$1 *= *([^ /]+).*/\1/p" Config/Local.xcconfig 2>/dev/null || true; } | tail -1; }
TEAM=$(setting DEVELOPMENT_TEAM)
BUNDLE=$(setting SHELL_HOMEBASE_BUNDLE_ID)
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ && "$TEAM" != ABCDE12345 ]] || { echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig first (see Local.xcconfig.example)." >&2; exit 1; }
[[ -n "$BUNDLE" && "$BUNDLE" != org.example.* && "$BUNDLE" != org.yourhousehold.* ]] || { echo "Set SHELL_HOMEBASE_BUNDLE_ID in Config/Local.xcconfig to your registered App ID." >&2; exit 1; }
# Two-part build number (YYYYMMDD.HHMM): always increasing, which App Store Connect requires per version.
BUILD=$(date -u +%Y%m%d.%H%M)
AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi
ARCHIVE="build/$SCHEME-tf.xcarchive"

echo "== Generate project"
xcodegen generate --quiet

echo "== Archive $SCHEME (Release, build $BUILD, $BUNDLE)"
rm -rf "$ARCHIVE" build/testflight
xcodebuild -project SovereignShell.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} CURRENT_PROJECT_VERSION="$BUILD" archive -quiet

echo "== Export ($DEST) for App Store Connect"
mkdir -p build
cat > build/ExportOptions-testflight.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
	<key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/testflight \
  -exportOptionsPlist build/ExportOptions-testflight.plist -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet

if [ "$DEST" = export ]; then
  IPA=$(ls build/testflight/*.ipa | head -1)
  CHECK=$(mktemp -d); trap 'rm -rf "$CHECK"' EXIT
  unzip -q "$IPA" -d "$CHECK"
  APPDIR=$(ls -d "$CHECK"/Payload/*.app)
  echo "  signer: $(codesign -dvv "$APPDIR" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  echo "  bundle: $(plutil -extract CFBundleIdentifier raw -o - "$APPDIR/Info.plist")"
  echo "  name: $(plutil -extract CFBundleDisplayName raw -o - "$APPDIR/Info.plist")"
  echo "  privacy manifests: $(find "$APPDIR" -name PrivacyInfo.xcprivacy | wc -l | tr -d ' ')"
  echo "Exported (not uploaded): $IPA"
else
  echo "Uploaded build $BUILD. It appears in App Store Connect -> TestFlight after processing (usually 5-30 min)."
  echo "Then add it to your internal testing group and install from the TestFlight app."
fi

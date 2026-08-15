#!/bin/bash
# Archive DrawNCut and upload it to TestFlight.
#
# One-time setup:
#   1. App Store Connect → Users and Access → Integrations → Team Keys →
#      Generate API Key (role: App Manager). Note the Key ID and Issuer ID.
#   2. Save the downloaded .p8 as
#      ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#   3. Create the app record once in App Store Connect (My Apps → + → New App,
#      bundle ID studio.irl.DrawNCut). The API cannot create app records.
#
# Usage:
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-....  scripts/deploy-testflight.sh
#
# Optional environment:
#   TEAM_ID       Apple Developer team (default: the project's team)
#   BUILD_NUMBER  CFBundleVersion (default: git commit count — monotonic,
#                 reproducible, never needs manual bumping)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key id}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the App Store Connect issuer id}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$KEY_PATH" ] || { echo "API key not found at $KEY_PATH" >&2; exit 1; }

TEAM_ID="${TEAM_ID:-AR464XUK46}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
ARCHIVE=build-archive/DrawNCut.xcarchive

echo "→ Archiving build $BUILD_NUMBER (team $TEAM_ID)"
xcodegen generate
xcodebuild archive \
    -project DrawNCut.xcodeproj -scheme DrawNCut -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    | tail -5

echo "→ Exporting and uploading to App Store Connect"
mkdir -p build-archive
cat > build-archive/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist build-archive/ExportOptions.plist \
    -exportPath build-archive/export \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    | tail -5

echo "✓ Build $BUILD_NUMBER uploaded — App Store Connect → TestFlight."
echo "  First upload of a new version takes a few minutes to process."

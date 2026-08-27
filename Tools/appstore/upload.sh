#!/usr/bin/env bash
#
# Archive, verify, export and upload to App Store Connect.
#
# Requires the App Store Connect app record to exist already: Apple does not
# allow creating one over the API (POST /v1/apps is 403 FORBIDDEN_ERROR), and
# without it the upload fails with a message that blames the bundle ID:
#
#     Cannot determine the Apple ID from Bundle ID 'com.mdeller.jumpjet'
#
# See Docs/TESTFLIGHT.md for the fields to fill in.
set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
# altool only looks for AuthKey_<id>.p8 in ./private_keys, ~/private_keys,
# ~/.private_keys and ~/.appstoreconnect/private_keys. The key is in none of
# them and is staying where it is, so point altool at it.
export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"

echo "== archive =="
xcodebuild archive -project JUMPjet.xcodeproj -scheme JUMPjet \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/JUMPjet.xcarchive > build/archive.log 2>&1
echo "   ok (log: build/archive.log)"

echo "== verify =="
Tools/appstore/verify-archive.sh build/JUMPjet.xcarchive

echo "== export =="
rm -rf build/export
xcodebuild -exportArchive -archivePath build/JUMPjet.xcarchive \
    -exportOptionsPlist Tools/appstore/ExportOptions.plist \
    -exportPath build/export > build/export.log 2>&1
echo "   $(du -h build/export/JUMPjet.ipa | cut -f1)  build/export/JUMPjet.ipa"

echo "== validate =="
xcrun altool --validate-app -f build/export/JUMPjet.ipa -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "== upload =="
xcrun altool --upload-app -f build/export/JUMPjet.ipa -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "Uploaded. Processing takes a few minutes; watch for it with:"
echo "  Tools/appstore/asc.py GET '/builds?filter[app]=<app-id>&limit=5'"

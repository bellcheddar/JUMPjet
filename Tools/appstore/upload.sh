#!/usr/bin/env bash
# Archive, verify, export, validate and upload to App Store Connect.
#
# Requires the App Store Connect app record to exist: Apple does not allow
# creating one over the API (POST /v1/apps -> 403 FORBIDDEN_ERROR), and without
# it the upload fails with a message that blames the bundle ID instead:
#
#     Cannot determine the Apple ID from Bundle ID 'com.mdeller.jumpjet'
#
# See Docs/TESTFLIGHT.md for the fields to fill in.
set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}" "${APPLE_TEAM_ID:?}"
# altool only looks for AuthKey_<id>.p8 in ./private_keys, ~/private_keys,
# ~/.private_keys and ~/.appstoreconnect/private_keys. The key is in none of
# them and is staying where it is, so point altool at it.
export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"

echo "== archive and verify =="
Tools/appstore/archive.sh

echo
echo "== export =="
OPTIONS=$(Tools/appstore/export-options.sh build/ExportOptions.plist)
rm -rf build/export
xcodebuild -exportArchive -archivePath build/JUMPjet.xcarchive \
    -exportOptionsPlist "$OPTIONS" -exportPath build/export > build/export.log 2>&1 \
  || { echo "EXPORT FAILED, tail of build/export.log:"; tail -20 build/export.log; exit 1; }
echo "  $(du -h build/export/JUMPjet.ipa | cut -f1)  build/export/JUMPjet.ipa"

echo
echo "== validate =="
xcrun altool --validate-app -f build/export/JUMPjet.ipa -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "== upload =="
xcrun altool --upload-app -f build/export/JUMPjet.ipa -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "Uploaded. Apple takes ten to thirty minutes to process the build; until"
echo "it finishes, attaching it to the version returns 409. Then run:"
echo "  Tools/coreml/.venv/bin/python Tools/appstore/store_metadata.py attach-builds"

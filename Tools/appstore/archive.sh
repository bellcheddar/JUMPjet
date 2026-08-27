#!/usr/bin/env bash
# Build the release archive for the App Store, then check what is in it.
#
# JUMPjet is one iOS target covering iPhone and iPad. There is no watch app, no
# macOS and no visionOS leg, so there is only one archive.
#
#   ./Tools/appstore/archive.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

ARCHIVE="build/JUMPjet.xcarchive"
LOG="build/archive.log"
mkdir -p build
rm -rf "$ARCHIVE"

# NOT regenerated from Tools/bootstrap-xcodeproj.rb: JUMPjet's .xcodeproj is
# committed and is the source of truth. That script records its origin only,
# and re-running it discards every change made in Xcode since.

# DerivedData must live outside this directory. The repository is under an
# iCloud-synced ~/Documents, and fileproviderd stamps com.apple.FinderInfo on
# directories it manages, which makes codesign fail the whole build with
# "resource fork, Finder information, or similar detritus not allowed".
# xattr -cr does not stick: the attributes come straight back.
DERIVED="${DERIVED_DATA:-${TMPDIR:-/tmp}/jumpjet-dd}"

echo "Archiving (DerivedData: $DERIVED)..."
xcodebuild archive \
    -project JUMPjet.xcodeproj \
    -scheme JUMPjet \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED" \
    > "$LOG" 2>&1 \
  || { echo "ARCHIVE FAILED, tail of $LOG:"; tail -25 "$LOG"; exit 1; }
grep -c "ARCHIVE SUCCEEDED" "$LOG" >/dev/null && echo "  ARCHIVE SUCCEEDED"

echo
"$(dirname "$0")/verify-archive.sh" "$ARCHIVE"

#!/usr/bin/env bash
# Write ExportOptions.plist from the environment.
#
# Generated rather than committed because it carries the team id, and this
# repository is public. xcodebuild does not expand $(APPLE_TEAM_ID) inside the
# plist, so substituting here is the only option.
set -euo pipefail
: "${APPLE_TEAM_ID:?source ~/.claude/skills/marcs-vibe-coding/credentials.env first}"
OUT="${1:-build/ExportOptions.plist}"
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>${APPLE_TEAM_ID}</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <!-- Manual signing needs every bundle ID in the archive mapped, or the
         export fails with "requires a provisioning profile". JUMPjet has one
         target and no extensions, so this is the whole map. -->
    <key>provisioningProfiles</key>
    <dict>
        <key>com.mdeller.jumpjet</key><string>JUMPjet App Store</string>
    </dict>
    <!-- Bitcode is gone from the toolchain; symbols make TestFlight crash
         reports readable. -->
    <key>uploadSymbols</key><true/>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
echo "$OUT"

#!/usr/bin/env bash
#
# Open the archive and check it is not hollow.
#
# BOFFIN's first successful archive was 7.6 MB and contained not one model. The
# build succeeded, the signature was valid, and the app could not do the one
# thing it exists to do. `ARCHIVE SUCCEEDED` says nothing about the contents,
# so this script says it instead.
set -euo pipefail

ARCHIVE="${1:-build/JUMPjet.xcarchive}"
APP="$ARCHIVE/Products/Applications/JUMPjet.app"
[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }

fail=0
ok()   { printf "  \033[32mOK\033[0m   %s\n" "$1"; }
bad()  { printf "  \033[31mMISS\033[0m %s\n" "$1"; fail=1; }

echo "== resources =="
for f in esm2_t6_8M_UR50D.mlmodelc esm2_t6_8M_UR50D.tokeniser.json \
         flexibility_centroids.json torsion_tables.json; do
    found=$(find "$APP" -maxdepth 4 -name "$f" | head -1)
    if [ -n "$found" ]; then ok "$(printf '%-40s %s' "$f" "$(du -sh "$found" | cut -f1)")"
    else bad "$f"; fi
done

echo "== icon =="
# The compiled icon is a flat PNG at the bundle root, not the .appiconset. An
# empty appiconset still builds, so checking the source proves nothing.
if ls "$APP"/AppIcon60x60@2x.png >/dev/null 2>&1; then ok "AppIcon60x60@2x.png"; else bad "AppIcon60x60@2x.png"; fi
if ls "$APP"/AppIcon76x76@2x~ipad.png >/dev/null 2>&1; then ok "AppIcon76x76@2x~ipad.png"; else bad "AppIcon76x76@2x~ipad.png (iPad)"; fi

echo "== signature =="
# No early `exit` in the awk and no `head`: either closes the pipe while
# codesign is still writing, and under `set -o pipefail` that SIGPIPE becomes a
# script failure (exit 141) that looks exactly like a failed check.
authority=$(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority=/ && !seen++ {print $2}')
case "$authority" in
    "Apple Distribution"*) ok "signed by $authority" ;;
    *) bad "authority is '$authority', expected Apple Distribution" ;;
esac

profile=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract Name raw - 2>/dev/null || true)
if [ "$profile" = "JUMPjet App Store" ]; then ok "profile '$profile'"
else bad "profile is '$profile', expected 'JUMPjet App Store'"; fi

echo "== identity =="
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
    printf "       %-28s %s\n" "$key" \
        "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Info.plist" 2>/dev/null)"
done
printf "       %-28s %s\n" "bundle size" "$(du -sh "$APP" | cut -f1)"

exit $fail

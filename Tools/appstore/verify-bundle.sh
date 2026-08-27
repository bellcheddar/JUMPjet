#!/usr/bin/env bash
# Check that a built JUMPjet app actually contains what it needs to work.
#
# BUILD SUCCEEDED says nothing about the contents. An app that ships without
# its Core ML model or its torsion tables builds cleanly, signs cleanly, and
# cannot do the one thing it exists to do: BOFFIN's first successful archive
# was 7.6 MB, validly signed, and contained not one model.
#
# Negative-test this script by deleting a file from a bundle. It must fail.
set -uo pipefail

APP="${1:?usage: verify-bundle.sh /path/to/JUMPjet.app}"
if [ -d "$APP/Contents/Resources" ]; then
    RES="$APP/Contents/Resources"          # macOS
else
    RES="$APP"                              # iOS
fi

fail=0
note() { printf '  %-42s %s\n' "$1" "$2"; }

check_file() {
    local path="$1" min="$2"
    if [ ! -e "$path" ]; then
        note "$(basename "$path")" "MISSING"; fail=1; return
    fi
    local size
    size=$(du -sk "$path" | cut -f1)
    if [ "$size" -lt "$min" ]; then
        note "$(basename "$path")" "TOO SMALL (${size} kB < ${min} kB)"; fail=1; return
    fi
    note "$(basename "$path")" "$(du -sh "$path" | cut -f1)"
}

echo "Verifying $(basename "$APP")"
echo "Neural prior:"
# The compiled model, not the .mlpackage: an .mlpackage in the bundle would
# mean it was copied as a resource rather than compiled, and would not load.
check_file "$RES/esm2_t6_8M_UR50D.mlmodelc"        8000
check_file "$RES/esm2_t6_8M_UR50D.tokeniser.json"     1

echo "Sampler tables:"
# Without these the sampler silently falls back to a flat torsion landscape,
# which runs, looks plausible, and samples the wrong distribution.
check_file "$RES/torsion_tables.json"                 8
check_file "$RES/flexibility_centroids.json"          8

echo "Icon:"
# The compiled icon at the bundle root, NOT Assets.xcassets/AppIcon.appiconset:
# an empty appiconset builds without complaint and ships an app with no icon.
check_file "$RES/AppIcon60x60@2x.png"                 1
check_file "$RES/AppIcon76x76@2x~ipad.png"            1

echo
if [ "$fail" -eq 0 ]; then
    echo "Bundle contents OK."
else
    echo "Bundle is INCOMPLETE." >&2
fi
exit "$fail"

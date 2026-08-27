#!/usr/bin/env bash
# Capture App Store screenshots from a simulator.
#
# Drives the app through its environment-variable seams, because there is no
# other way to put a loaded structure, a finished run or a below-the-fold panel
# on screen from outside. simctl passes anything prefixed SIMCTL_CHILD_ through
# to the app.
#
#   ./Tools/appstore/capture-screenshots.sh <device-udid> <output-dir>
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: capture-screenshots.sh <udid> <out-dir>}"
OUT="${2:?}"
BUNDLE="com.mdeller.jumpjet"
# 142 residues: big enough to look like a protein, small enough that a sortie
# finishes while the capture is waiting rather than after it.
ACCESSION="${ACCESSION:-P69905}"
SWEEPS="${SWEEPS:-3000}"
mkdir -p "$OUT"

shot() {
    local name="$1"; shift
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    env "$@" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
    # A fixed settle rather than polling: there is no external signal for
    # "the sortie finished and the column has relaid out".
    local n=0; until [ $n -ge "${SETTLE:-14}" ]; do n=$((n+1)); sleep 1; done
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" 2>/dev/null \
        | awk '/pixel/{printf "%s ", $2}')"
}

echo "Capturing from $UDID into $OUT"
SETTLE=6  shot "1-standby"
SETTLE=14 shot "2-structure" SIMCTL_CHILD_JUMPJET_AUTOLOAD="$ACCESSION"
SETTLE=26 shot "3-sortie"    SIMCTL_CHILD_JUMPJET_AUTOLOAD="$ACCESSION" \
                             SIMCTL_CHILD_JUMPJET_AUTORUN="$SWEEPS"
SETTLE=30 shot "4-recorder"  SIMCTL_CHILD_JUMPJET_AUTOLOAD="$ACCESSION" \
                             SIMCTL_CHILD_JUMPJET_AUTORUN="$SWEEPS" \
                             SIMCTL_CHILD_JUMPJET_PANEL="recorder"
SETTLE=30 shot "5-export"    SIMCTL_CHILD_JUMPJET_AUTOLOAD="$ACCESSION" \
                             SIMCTL_CHILD_JUMPJET_AUTORUN="$SWEEPS" \
                             SIMCTL_CHILD_JUMPJET_PANEL="export"

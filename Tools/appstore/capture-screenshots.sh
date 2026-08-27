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

PYBIN="${PYBIN:-Tools/coreml/.venv/bin/python}"

shot() {
    local name="$1"; shift
    local attempt=1 mean
    while [ "$attempt" -le 4 ]; do
        xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
        env "$@" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
        # A fixed settle rather than polling: there is no external signal for
        # "the sortie finished and the column has relaid out".
        local n=0; until [ $n -ge "${SETTLE:-14}" ]; do n=$((n+1)); sleep 1; done
        xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1

        # A system notification banner ("Ready for Apple Intelligence") lands
        # across the top of whatever is on screen and is captured with it. It
        # fires on its own schedule, so it hit exactly one shot of one device
        # in the first run and was missed because only the other device was
        # checked by eye. Detect it and retake: the banner auto-dismisses.
        if mean=$("$PYBIN" Tools/appstore/banner-check.py "$OUT/$name.png"); then
            echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" 2>/dev/null \
                | awk '/pixel/{printf "%s ", $2}') band=$mean"
            return 0
        fi
        echo "  $name.png  notification banner (band=$mean), retaking [$attempt/4]"
        sleep 12
        attempt=$((attempt + 1))
    done
    echo "  $name.png  STILL BANNERED after 4 attempts" >&2
    return 1
}

# Apple's own convention for App Store screenshots, and it stops the clock
# differing between device sets shot minutes apart.
xcrun simctl status_bar "$UDID" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true

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

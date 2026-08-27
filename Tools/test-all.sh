#!/usr/bin/env bash
# Run every package's test suite on the host.
#
# The packages carry a macOS platform purely so this works without booting a
# simulator, which turns the inner loop from tens of seconds into one.
#
# RELEASE, not debug. `swift test` defaults to debug, and for JumpjetEngine that
# is a factor of THIRTY-SIX: the same twenty Monte Carlo sweeps take 4.9 s debug
# and 0.14 s release. A physics suite that has to run thousands of moves is
# unusable at that speed, and worse, a benchmark run in debug measures the
# optimiser being switched off rather than anything about the code. An entire
# optimisation pass here was aimed at debug-build numbers before that was
# noticed.
#
# The cost is that `assert` is compiled out. Nothing in these packages relies on
# it; the invariants that matter use `precondition`, which survives.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
total=0
for package in Packages/*/; do
    name="$(basename "$package")"
    printf '\n=== %s ===\n' "$name"
    output="$(cd "$package" && swift test -c release 2>&1)"
    line="$(printf '%s' "$output" | grep -E '^\s+Executed [0-9]+ tests' | tail -1)"
    if printf '%s' "$output" | grep -qE 'error:|with [1-9][0-9]* failure'; then
        printf '%s' "$output" | grep -E 'error:|failed -' | head -20
        status=1
    fi
    printf '%s\n' "${line:-  no tests}"
    count="$(printf '%s' "$line" | grep -oE 'Executed [0-9]+' | grep -oE '[0-9]+')"
    total=$((total + ${count:-0}))
done

printf '\n%d tests across %d packages\n' "$total" "$(ls -d Packages/*/ | wc -l | tr -d ' ')"
exit "$status"

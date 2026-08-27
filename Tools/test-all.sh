#!/usr/bin/env bash
# Run every package's test suite on the host.
#
# The packages carry a macOS platform purely so this works without booting a
# simulator, which turns the inner loop from tens of seconds into one.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
total=0
for package in Packages/*/; do
    name="$(basename "$package")"
    printf '\n=== %s ===\n' "$name"
    output="$(cd "$package" && swift test 2>&1)"
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

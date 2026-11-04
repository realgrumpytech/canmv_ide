#!/bin/bash
# List the architecture of every Mach-O file under a CanMV IDE.app (or any
# directory). Exit 1 when a binary that the IDE itself loads (MacOS,
# Frameworks, PlugIns) is not arm64 or universal-with-arm64.
#
# Helper tools under Contents/Resources are reported and do not fail the run.
# bash 3.2 compatible.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <CanMV IDE.app or directory>" >&2
    exit 2
fi

root=$1
if [ ! -d "$root" ]; then
    echo "not a directory: $root" >&2
    exit 2
fi

report=$(mktemp)
fail=0

echo "host uname -m: $(uname -m)"
echo "scanning: $root"
echo

printf '%-20s %s\n' "ARCHS" "PATH"
echo "-------------------- ----------------------------------------"

# -print0 / read -d is fine in bash 3.2.
find "$root" -type f -print | while IFS= read -r f; do
    kind=$(file -b "$f" || true)
    case "$kind" in
        Mach-O*) ;;
        *) continue ;;
    esac
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    if [ -z "$archs" ]; then
        archs=$(printf '%s' "$kind" | sed -n 's/.*executable \(arm64\|x86_64\|i386\).*/\1/p')
        if [ -z "$archs" ]; then
            archs="unknown"
        fi
    fi
    rel=${f#"$root"/}
    printf '%-20s %s\n' "$archs" "$rel"
    printf '%s\t%s\n' "$archs" "$rel" >> "$report"
done

echo
echo "=== classification ==="

native=0
intel_app=0
intel_helper=0
other=0

# The while-loop above ran in a subshell because of the pipe, so the report
# file is the only way to see results. Re-read it.
while IFS=$(printf '\t') read -r archs rel; do
    [ -n "$rel" ] || continue
    case "$archs" in
        *arm64*)
            native=$((native + 1))
            ;;
        *)
            case "$rel" in
                Contents/MacOS/*|Contents/Frameworks/*|Contents/PlugIns/*)
                    echo "APP x86_64 (must be arm64): $rel ($archs)"
                    intel_app=$((intel_app + 1))
                    ;;
                *)
                    echo "HELPER not arm64: $rel ($archs)"
                    intel_helper=$((intel_helper + 1))
                    ;;
            esac
            ;;
    esac
done < "$report"

# Counters updated in the while-loop run in this shell (redirect, not pipe).
echo
echo "arm64 or universal: $native"
echo "non-arm64 app/framework/plugin: $intel_app"
echo "non-arm64 other Mach-O: $intel_helper"

if [ "$native" -eq 0 ]; then
    echo "FAIL: no arm64 Mach-O files were found."
    fail=1
fi
if [ "$intel_app" -ne 0 ]; then
    echo "FAIL: the IDE binary, a Qt/Creator library, or a plugin is not arm64."
    fail=1
fi

rm -f "$report"
exit $fail

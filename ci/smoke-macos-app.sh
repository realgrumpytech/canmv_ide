#!/bin/bash
# Launch CanMV IDE briefly and report dyld problems.
# A missing library fails the script. A process that is still alive after
# a few seconds is a pass; it is then terminated.
# bash 3.2 compatible.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <CanMV IDE.app>" >&2
    exit 2
fi

app=$1
exe="$app/Contents/MacOS/CanMV IDE"
log=$(mktemp)

if [ ! -x "$exe" ]; then
    echo "missing executable: $exe" >&2
    exit 2
fi

echo "== codesign =="
codesign --verify --deep --verbose=2 "$app"
echo "signature:"
codesign -dv "$app" 2>&1 || true

echo
echo "== main executable linkage =="
otool -L "$exe"

echo
echo "== unresolved absolute dependencies (app, frameworks, plugins) =="
missing=0
find "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/PlugIns" -type f -print 2>/dev/null | while IFS= read -r f; do
    kind=$(file -b "$f" || true)
    case "$kind" in
        Mach-O*) ;;
        *) continue ;;
    esac
    otool -L "$f" | awk 'NR>1 {print $1}' | while IFS= read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*)
                ;;
            *)
                echo "ABSOLUTE $dep"
                echo "  from $f"
                ;;
        esac
    done
done | tee "$log.deps" || true

if [ -s "$log.deps" ]; then
    echo "FAIL: Mach-O files still link absolute non-system libraries."
    missing=1
fi

echo
echo "== launch =="
xattr -cr "$app" 2>/dev/null || true
# Monitor mode gives the app its own process group so we can stop helpers.
set -m
QT_DEBUG_PLUGINS=1 "$exe" >"$log" 2>&1 &
pid=$!
sleep 12
alive=0
if kill -0 "$pid" 2>/dev/null; then
    alive=1
    echo "process $pid still running after 12s"
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
else
    echo "process $pid exited before 12s"
    wait "$pid" || true
fi
set +m

echo "---- launch log ----"
cat "$log" || true
echo "---- end log ----"

if grep -E -q 'Library not loaded|cannot load library|Cannot load library|Reason: image not found|dyld\[' "$log"; then
    echo "FAIL: loader reported a missing library"
    exit 1
fi

if [ "$missing" -ne 0 ]; then
    exit 1
fi

if [ "$alive" -ne 1 ]; then
    echo "FAIL: CanMV IDE did not stay running."
    exit 1
fi

echo "SMOKE PASS"
exit 0

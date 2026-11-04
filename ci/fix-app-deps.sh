#!/bin/bash
# macdeployqt copies Qt frameworks but misses some Homebrew dylibs those
# frameworks need (for example libbrotlicommon, which libbrotlidec loads via
# @rpath). Copy any such library into Contents/Frameworks, where the bundled
# binaries already search.
#
# bash 3.2 compatible.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <CanMV IDE.app>" >&2
    exit 2
fi

app=$1
fw="$app/Contents/Frameworks"
mkdir -p "$fw"

is_system() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

find_homebrew() {
    base=$1
    if [ -e "/opt/homebrew/lib/$base" ]; then
        echo "/opt/homebrew/lib/$base"
        return 0
    fi
    found=$(find /opt/homebrew/opt /opt/homebrew/Cellar -name "$base" \( -type f -o -type l \) 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
}

in_app() {
    base=$1
    if [ -e "$fw/$base" ]; then
        return 0
    fi
    found=$(find "$app" -name "$base" \( -type f -o -type l \) 2>/dev/null | head -1 || true)
    [ -n "${found}" ]
}

qdir=$(mktemp -d)
n=0
while IFS= read -r f; do
    n=$((n + 1))
    printf '%s\n' "$f" > "$qdir/$n"
done << EOF
$(find "$app" -type f)
EOF

i=1
while [ "$i" -le "$n" ]; do
    bin=$(cat "$qdir/$i")
    i=$((i + 1))
    kind=$(file -b "$bin" || true)
    case "$kind" in
        Mach-O*) ;;
        *) continue ;;
    esac

    selfid=$(otool -D "$bin" 2>/dev/null | awk 'NR==2 {print $1}' || true)
    deps=$(otool -L "$bin" | awk 'NR>1 {print $1}')
    for dep in $deps; do
        if [ -n "${selfid:-}" ] && [ "$dep" = "$selfid" ]; then
            continue
        fi
        if is_system "$dep"; then
            continue
        fi
        base=$(basename "$dep")
        if in_app "$base"; then
            continue
        fi
        if ! src=$(find_homebrew "$base"); then
            echo "WARNING: no Homebrew copy of $dep (needed by $bin)" >&2
            continue
        fi
        echo "vendoring $base"
        echo "  from $src"
        echo "  needed by $bin"
        cp -L "$src" "$fw/$base"
        chmod 755 "$fw/$base" 2>/dev/null || true
        xattr -cr "$fw/$base" 2>/dev/null || true
        n=$((n + 1))
        printf '%s\n' "$fw/$base" > "$qdir/$n"

        case "$dep" in
            @rpath/*|@loader_path/*|@executable_path/*)
                ;;
            *)
                case "$bin" in
                    "$fw"/*) newid="@loader_path/$base" ;;
                    *) newid="@executable_path/../Frameworks/$base" ;;
                esac
                if ! install_name_tool -change "$dep" "$newid" "$bin" 2>/dev/null; then
                    codesign --remove-signature "$bin" 2>/dev/null || true
                    install_name_tool -change "$dep" "$newid" "$bin" 2>/dev/null || \
                        echo "WARNING: left absolute dependency $dep in $bin" >&2
                fi
                ;;
        esac
    done
done

rm -rf "$qdir"
echo "framework dylibs now include:"
ls "$fw" | head -80

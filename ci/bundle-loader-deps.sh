#!/bin/bash
# Copy a Mach-O binary into DESTDIR and vendor every non-system dylib it
# needs, rewriting install names to @loader_path/<basename>.
# bash 3.2 compatible (macOS /bin/bash).
#
# Usage: bundle-loader-deps.sh DESTDIR BINARY

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 DESTDIR BINARY" >&2
    exit 2
fi

dest=$1
src=$2
mkdir -p "$dest"

name=$(basename "$src")
cp -f "$src" "$dest/$name"
chmod +x "$dest/$name"
xattr -cr "$dest/$name" 2>/dev/null || true

queue=$(mktemp)
echo "$dest/$name" > "$queue"

is_system_dep() {
    case "$1" in
        /usr/lib/*|/System/*|@loader_path/*|@executable_path/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_dep() {
    bin=$1
    dep=$2
    if [ -f "$dep" ]; then
        echo "$dep"
        return 0
    fi
    case "$dep" in
        @rpath/*)
            lib=${dep#@rpath/}
            rpaths=$(otool -l "$bin" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
            for r in $rpaths; do
                if [ -f "$r/$lib" ]; then
                    echo "$r/$lib"
                    return 0
                fi
            done
            echo "cannot resolve $dep from $bin" >&2
            return 1
            ;;
        *)
            echo "missing dependency $dep (referenced by $bin)" >&2
            return 1
            ;;
    esac
}

while [ -s "$queue" ]; do
    bin=$(head -n 1 "$queue")
    tail -n +2 "$queue" > "$queue.next"
    mv "$queue.next" "$queue"

    codesign --remove-signature "$bin" 2>/dev/null || true

    deps=$(otool -L "$bin" | awk 'NR>1 {print $1}')
    for dep in $deps; do
        if is_system_dep "$dep"; then
            continue
        fi
        if ! resolved=$(resolve_dep "$bin" "$dep"); then
            exit 1
        fi
        base=$(basename "$resolved")
        if [ ! -f "$dest/$base" ]; then
            cp -f "$resolved" "$dest/$base"
            chmod +x "$dest/$base" 2>/dev/null || true
            xattr -cr "$dest/$base" 2>/dev/null || true
            echo "$dest/$base" >> "$queue"
        fi
        install_name_tool -change "$dep" "@loader_path/$base" "$bin"
    done

    # Executables have no LC_ID_DYLIB; otool -D fails for them.
    id=$(otool -D "$bin" 2>/dev/null | awk 'NR==2 {print $1}' || true)
    if [ -n "${id:-}" ]; then
        case "$id" in
            @loader_path/*) ;;
            *)
                install_name_tool -id "@loader_path/$(basename "$bin")" "$bin"
                ;;
        esac
    fi
done

rm -f "$queue"
echo "bundled $(basename "$src") into $dest"

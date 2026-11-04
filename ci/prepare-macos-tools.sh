#!/bin/bash
# Replace the Intel-only ffmpeg/ffplay shipped for the framebuffer video
# tools with arm64 binaries, before qmake snapshots the file list.
# ffprobe and ffserver in that directory are not launched by the IDE.
#
# bash 3.2 compatible.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/qt-creator/share/qtcreator/ffmpeg/mac"
mkdir -p "$dest"

echo "== static arm64 ffmpeg =="
tmp=$(mktemp)
curl -fL --retry 3 --retry-delay 2 -o "$tmp" \
    "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz"
gunzip -c "$tmp" > "$dest/ffmpeg.new"
rm -f "$tmp"
chmod +x "$dest/ffmpeg.new"
xattr -cr "$dest/ffmpeg.new" 2>/dev/null || true
file "$dest/ffmpeg.new"
archs=$(lipo -archs "$dest/ffmpeg.new")
echo "ffmpeg archs: $archs"
echo "$archs" | grep -q arm64
mv "$dest/ffmpeg.new" "$dest/ffmpeg"

# Not referenced by the IDE. Drop them so the .app does not contain
# extra x86_64 Mach-O files that would need Rosetta.
rm -f "$dest/ffprobe" "$dest/ffserver"

echo "== arm64 ffplay (Homebrew ffmpeg + vendored dylibs) =="
export HOMEBREW_NO_AUTO_UPDATE=1
if [ ! -x "$(brew --prefix ffmpeg)/bin/ffplay" ]; then
    brew install ffmpeg
fi
ffplay="$(brew --prefix ffmpeg)/bin/ffplay"
if [ ! -x "$ffplay" ]; then
    echo "WARNING: no ffplay in Homebrew ffmpeg; the bundled ffplay stays x86_64" >&2
    exit 0
fi

stage=$(mktemp -d)
if bash "$root/ci/bundle-loader-deps.sh" "$stage" "$ffplay"; then
    rm -f "$dest/ffplay"
    cp -a "$stage"/. "$dest"/
    xattr -cr "$dest" 2>/dev/null || true
    echo "ffplay archs: $(lipo -archs "$dest/ffplay")"
    echo "ffplay linkage:"
    otool -L "$dest/ffplay"
else
    echo "WARNING: arm64 ffplay bundling failed; keeping the original x86_64 ffplay" >&2
fi
rm -rf "$stage"

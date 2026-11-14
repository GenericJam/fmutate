#!/bin/sh
# Fetches firmware sources at their pins (tools/native_catalog/pins.json) into native/build/catalog/src/<id>:
# one shallow fetch of the pinned commit, submodules shallow too; then, to keep 213 trees in a few GB, the git
# data goes (the commit stays in <id>/.pin) and so do media no build reads (video, audio previews, PDFs,
# images other than PNG, archives, prebuilt .wasm) and the top-level docs/. Re-runnable (a tree at its pin is kept).
#
#   tools/native_catalog/fetch.sh <id>...      those
#   tools/native_catalog/fetch.sh --all        every pinned firmware (8 at a time)
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
SRC=$ROOT/native/build/catalog/src
mkdir -p "$SRC"

if [ "$1" = --all ]; then
    python3 -c "import json; print('\n'.join(json.load(open('tools/native_catalog/pins.json'))))" |
        xargs -P 8 -n 1 sh "$0"
    exit 0
fi

for id in "$@"; do
    set -- $(python3 -c "import json, sys; p = json.load(open('tools/native_catalog/pins.json'))['$id']; print(p['repo'], p['commit'])")
    repo=$1 commit=$2
    dir=$SRC/$id
    if [ "$(cat "$dir/.pin" 2>/dev/null)" = "$commit" ]; then
        continue
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    export GIT_TERMINAL_PROMPT=0
    if git -C "$dir" init -q && git -C "$dir" remote add origin "https://github.com/$repo.git" &&
        git -C "$dir" fetch -q --depth 1 origin "$commit" && git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD; then
        sub=""
        git -C "$dir" submodule -q update --init --recursive --depth 1 2>"$dir.submodule.log" || sub=" (submodules failed: $dir.submodule.log)"
        [ -s "$dir.submodule.log" ] || rm -f "$dir.submodule.log"
        find "$dir" -name .git -prune -exec rm -rf {} +
        find "$dir" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mp3' -o -iname '*.pdf' -o -iname '*.gif' \
            -o -iname '*.zip' -o -iname '*.wasm' -o -iname '*.webm' -o -iname '*.jpg' -o -iname '*.jpeg' \) -delete
        rm -rf "$dir/docs"
        echo "$commit" > "$dir/.pin"
        echo "$id: $(du -sh "$dir" | cut -f1)$sub"
    else
        echo "$id: FETCH FAILED"
    fi
done

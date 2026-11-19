#!/bin/sh
# native/ios_archive.sh <sdk> <out.a> <input>...: `libtool -static` for native/build_ios.sh. Fails when libtool
# fails or leaves no archive (showing what it said); on success it hides only its "has no symbols" notes (the
# emulator's Rust objects with nothing in them).
set -e
sdk=$1
out=$2
shift 2
rm -f "$out"
if ! log=$(xcrun -sdk "$sdk" libtool -static -o "$out" "$@" 2>&1); then
    printf '%s\n' "$log" >&2
    echo "libtool failed: $out" >&2
    exit 1
fi
if [ ! -s "$out" ]; then
    printf '%s\n' "$log" >&2
    echo "libtool made no archive: $out" >&2
    exit 1
fi
[ -z "$log" ] || printf '%s\n' "$log" | grep -v "has no symbols" || true

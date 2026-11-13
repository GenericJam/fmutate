#!/bin/sh
# Builds the engine and the cartridges for this computer (Linux or macOS), into native/build/host/ with the same file
# names as on Android, so FMutate.Paths' host default finds them and the tests run real firmwares.
# Run native/build_android.sh first once (it fetches the firmware sources), or this fetches them too.
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
OUT=build/host
CFLAGS="-O2 -Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable"
# macOS: the firmwares' ELF section name (".pool") isn't a Mach-O one; those buffers go in plain BSS there
[ "$(uname -s)" = Darwin ] && CARTFLAGS="-Dsection(x)=" || CARTFLAGS=""
mkdir -p "$OUT"
[ -d build/fw/obervave/.git ] || ABIS="" sh build_android.sh
cc $CFLAGS -o "$OUT/libfm1engine.so" engine/fm1engine.c -ldl
for name in obervave:3.3.2 shineon:3.0.1; do
    fw=${name%%:*}
    version=${name#*:}
    src=build/fw/$fw
    cc $CFLAGS $CARTFLAGS -shared -fPIC -DAPP_VER="\"$version\"" -DFW_MAIN="\"$HERE/$src/firmware/src/$fw.c\"" \
        -I"$src/firmware/src" -I"$src/firmware/gen" -o "$OUT/libcart_$fw.so" engine/live.c -lpthread
done
echo "host: $(ls $OUT | tr '\n' ' ')"

#!/bin/sh
# Builds the firmware engine and the firmware cartridges for Android, per ABI, into the APK's jniLibs:
#
#   android/app/src/main/jniLibs/<abi>/libfm1engine.so      the engine: an executable (PIE). Android only lets an
#                                                            app exec files from its native library dir, and only
#                                                            files named lib*.so get extracted there.
#   android/app/src/main/jniLibs/<abi>/libcart_<fw>.so      one firmware each, dlopen'd by the engine
#
# Firmwares are built from their authors' repositories at pinned releases (GPL-3.0); see CARTRIDGES below.
# Re-runnable; run after changing native/engine or the pins. Then `mix mob.deploy --native`.
#
#   native/build_android.sh               all ABIs
#   ABIS="arm64-v8a" native/build_android.sh
#   ABIS="" native/build_android.sh       only fetch the firmwares (native/build_host.sh, native/build_ios.sh)
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
ROOT=$(cd .. && pwd)
NDK=${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/27.2.12479018}
[ -d "$NDK" ] || NDK=$HOME/Library/Android/sdk/ndk/27.2.12479018    # (macOS's default SDK location)
TC=$NDK/toolchains/llvm/prebuilt/$(uname -s | tr 'A-Z' 'a-z')-x86_64/bin   # (darwin-x86_64 on Apple silicon too)
API=28                                          # minSdk (android/app/build.gradle)
ABIS=${ABIS-"arm64-v8a armeabi-v7a x86_64"}
CFLAGS="-O2 -Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable"
# 16 KB pages (Android 15+ devices and the current emulator images) need 16 KB-aligned LOAD segments
LDFLAGS="-Wl,-z,max-page-size=16384"

# name repo commit version
CARTRIDGES="
obervave https://github.com/zvenson/obervave.git 792535d23ef4265475b1c2f9895ca30e857fe596 3.3.2
shineon https://github.com/zvenson/shineon.git 2f37738d690a628e0ae1d23d07ea5ee3eeda2de7 3.0.1
"

fetch() {  # name repo commit
    src=build/fw/$1
    [ -d "$src/.git" ] || git clone -q "$2" "$src"
    git -C "$src" fetch -q origin "$3" 2>/dev/null || true
    git -C "$src" checkout -q -f "$3"
    for p in patches/$1/*.patch; do
        [ -e "$p" ] && git -C "$src" apply "$HERE/$p"
    done
    return 0
}

mkdir -p build/fw
echo "$CARTRIDGES" | while read -r name repo commit version; do
    if [ -n "$name" ]; then fetch "$name" "$repo" "$commit"; fi
done

for abi in $ABIS; do
    case $abi in
        arm64-v8a) cc=$TC/aarch64-linux-android$API-clang ;;
        armeabi-v7a) cc=$TC/armv7a-linux-androideabi$API-clang ;;
        x86_64) cc=$TC/x86_64-linux-android$API-clang ;;
        *) echo "unknown ABI $abi"; exit 1 ;;
    esac
    out=$ROOT/android/app/src/main/jniLibs/$abi
    mkdir -p "$out"
    $cc $CFLAGS -fPIE -pie $LDFLAGS -o "$out/libfm1engine.so" engine/fm1engine.c -ldl
    echo "$CARTRIDGES" | while read -r name repo commit version; do
        [ -z "$name" ] && continue
        src=build/fw/$name
        $cc $CFLAGS -shared -fPIC $LDFLAGS -DAPP_VER="\"$version\"" \
            -DFW_MAIN="\"$HERE/$src/firmware/src/$name.c\"" \
            -I"$src/firmware/src" -I"$src/firmware/gen" -o "$out/libcart_$name.so" engine/live.c
    done
    echo "$abi: $(ls "$out" | grep -E 'fm1engine|cart_' | tr '\n' ' ')"
done

#!/bin/sh
# Builds the emulator engine: any FM-1 firmware package (.fwsc) in fm1-emu (Joakim Eriksson, MIT), behind the
# same engine protocol as libfm1engine.so (docs/engine_protocol.md). The wrapper is native/emu (Rust); fm1-emu
# is fetched at a pinned commit into native/build/fm1-emu, with native/patches/fm1-emu/*.patch applied (none at present).
#
#   android/app/src/main/jniLibs/<abi>/libfm1emu.so   an executable (PIE), named lib*.so like libfm1engine.so
#   native/build/host/libfm1emu.so                    the same for this computer (tests; FMutate.Paths.emu_bin)
#   native/build/packages/<id>.fwsc                   firmware packages for the host tests: the FM-1 Firmware
#                                                     Hub's current one for each id in PACKAGES (found as
#                                                     fm1-emu's tools/hub_catalog.mjs finds them; the Hub drops
#                                                     a package when its next version comes, so no versions)
#
# Rust comes from mise (.tool-versions); the Android targets once: `mise exec -- rustup target add
# aarch64-linux-android x86_64-linux-android` (+ armv7-linux-androideabi to measure it). Then `mix mob.deploy --native`.
#
#   native/build_emu.sh                    host + arm64-v8a and x86_64
#   ABIS="arm64-v8a" native/build_emu.sh   host + those ABIs
#   ABIS="" native/build_emu.sh            host only
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
ROOT=$(cd .. && pwd)
NDK=${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/27.2.12479018}
[ -d "$NDK" ] || NDK=$HOME/Library/Android/sdk/ndk/27.2.12479018    # (macOS's default SDK location)
TC=$NDK/toolchains/llvm/prebuilt/$(uname -s | tr 'A-Z' 'a-z')-x86_64/bin   # (darwin-x86_64 on Apple silicon too)
API=28                                          # minSdk (android/app/build.gradle)
# Not armeabi-v7a by default: fm1-core has no 32-bit ARM code generator, and its interpreter ran Dinghy at 0.11x
# real time on a Moto G Power 2021 (`ABIS=armeabi-v7a` still builds it, for measuring). Without libfm1emu.so,
# FMutate.Firmware.runnable/1 reports packages as not runnable on such phones.
ABIS=${ABIS-"arm64-v8a x86_64"}
FM1EMU_REPO=https://github.com/joakimeriksson/fm1-emu.git
FM1EMU_COMMIT=42c7fef9ae4ef0496e73b3cab9ebaea6d93c310f   # master, 2026-11-13 (has #171: the JIT on x86-64 Android)
HUB=https://thefirmwarehub.com/
# firmware ids on the Hub, for the host tests (GPL-3.0 firmwares: fetched, never committed)
PACKAGES="dinghy obervave"
export CARGO_TARGET_DIR=$HERE/build/emu-target

src=build/fm1-emu
if [ ! -d "$src/.git" ]; then
    git clone -q --filter=blob:none --no-checkout "$FM1EMU_REPO" "$src"
fi
git -C "$src" fetch -q origin "$FM1EMU_COMMIT" 2>/dev/null || true
git -C "$src" checkout -q -f "$FM1EMU_COMMIT"
for p in patches/fm1-emu/*.patch; do
    [ -e "$p" ] && git -C "$src" apply "$HERE/$p"
done

mkdir -p build/packages build/host
for id in $PACKAGES; do
    [ -s "build/packages/$id.fwsc" ] && continue
    pkg=$(curl -fsSL "${HUB}catalog.json" |
        python3 -c "import json, sys; print(next(f['pkg'] for f in json.load(sys.stdin)['firmwares'] if f['id'] == '$id'))")
    curl -fsSL -o "build/packages/$id.fwsc" "$HUB$pkg"
    echo "package: build/packages/$id.fwsc ($pkg)"
done

cargo build -q --release --manifest-path emu/Cargo.toml
cp "$CARGO_TARGET_DIR/release/fm1emu" build/host/libfm1emu.so
echo "host: build/host/libfm1emu.so"

for abi in $ABIS; do
    case $abi in
        arm64-v8a) triple=aarch64-linux-android; cc=$TC/aarch64-linux-android$API-clang ;;
        armeabi-v7a) triple=armv7-linux-androideabi; cc=$TC/armv7a-linux-androideabi$API-clang ;;
        x86_64) triple=x86_64-linux-android; cc=$TC/x86_64-linux-android$API-clang ;;
        *) echo "unknown ABI $abi"; exit 1 ;;
    esac
    var=$(echo "$triple" | tr 'a-z-' 'A-Z_')
    # the NDK's clang links (API 28); 16 KB pages (Android 15+ devices, the current emulator images) need
    # 16 KB-aligned LOAD segments
    env "CARGO_TARGET_${var}_LINKER=$cc" "CARGO_TARGET_${var}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384" \
        cargo build -q --release --manifest-path emu/Cargo.toml --target "$triple"
    out=$ROOT/android/app/src/main/jniLibs/$abi
    mkdir -p "$out"
    cp "$CARGO_TARGET_DIR/$triple/release/fm1emu" "$out/libfm1emu.so"
    echo "$abi: $out/libfm1emu.so"
done

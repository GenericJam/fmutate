#!/bin/sh
# Builds what the iOS app links in place of Android's engine executables (docs/decisions/2026-11-13-ios-port.md):
# one static archive per iOS target, native/build/ios/<target>/libfm1native.a, holding
#
#   the engine core      engine/fm1engine.c with -DFM1ENGINE_LIB: fm1engine_run, no main
#   the built-ins        CARTRIDGES: engine/live.c + the firmware (-DFM1C_TABLE=fm1c_<id>), put through `ld -r` so
#                        that only its table is global (two firmwares' app_main, fb, ... can't clash) and its data
#                        and BSS are moved to sections of their own (__DATA,__<id>_d / __<id>_b): the host restores
#                        them before each boot
#   the published ones   sim and device: every iOS cartridge of the signed index pinned in ios_cartridges.lock
#                        (docs/decisions/2026-11-14-native-catalog.md "Packaging"), built the same way by
#                        github.com/GenericJam/fmutate-cartridges; a built-in's id is never taken from there
#   the cartridge table  fm1native_carts (engine/fm1engine.h): each cartridge's id, version and table, what
#                        c_src/fm1host.c (the NIF that runs them; mob.exs links the archive to it through
#                        :extra_static_libs) offers
#   the emulator engine  native/emu as a static library (fm1emu_run, fm1emu_bench); interpreted, iOS has no JIT
#
# A published cartridge is fetched by ios_cartridges.exs into a cache keyed by SHA-256 (FMUTATE_CART_CACHE, default
# ~/Library/Caches/fmutate/cartridges), kept only when its size, SHA-256 and own Ed25519 signature (the app's key,
# config/config.exs) match the lock, and linked only when it holds what the host assumes: one object whose only
# global is fm1c_<id>, its table's data and BSS bounds (section$start/end) naming two __DATA sections, no writable
# data outside them, and it links for the target. One that doesn't is left out with a warning (it plays emulated);
# a download or signature that doesn't check fails the build. IOS_CARTRIDGES_REFRESH=1 rewrites the lock from the
# index (its signature must verify; one older than the lock's is refused); commit the result.
#
# A Mach-O image has at most 255 sections, so the published cartridges can't each keep two: `ld -r` moves each
# one's data and BSS into two sections they all share (__DATA,__fm1c_d and the zerofill __DATA,__fm1c_b), between
# markers that define the bounds its table asks for, so its state() still gives exactly its own globals. That
# relies on the linker keeping an object's atoms of a section together and in order, which a link of all of them
# checks (its map: ios_cartridges.exs layout) before the archive is made.
#
# Targets: sim (the arm64 simulator), device (an iPhone), and host (this Mac: the built-ins only, plus
# c_src/fm1host.c linked with the archive as a loadable NIF, native/build/host/fm1host.so, so the tests run engines
# in-process as iOS does). Needs Xcode, Elixir (run it through `mise exec`) and Rust with `rustup target add
# aarch64-apple-ios aarch64-apple-ios-sim`; puts the firmware sources at their pinned commits with native/patches
# applied, every run (native/build_android.sh, so a tree checked out before a patch was added gets it too), and
# fetches fm1-emu (native/build_emu.sh) when it isn't there yet.
#
#   native/build_ios.sh                     sim and device
#   TARGETS="sim host" native/build_ios.sh  those
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
MIN_IOS=17.0                                    # Mob's deployment target (ios/build.zig, ios/build_device.zig)
TARGETS=${TARGETS-"sim device"}
CFLAGS="-O2 -Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable"
# id:version, as native/build_android.sh's CARTRIDGES
CARTRIDGES="obervave:3.3.2 shineon:3.0.1"
LOCK=$HERE/ios_cartridges.lock
CART_CACHE=${FMUTATE_CART_CACHE:-$HOME/Library/Caches/fmutate/cartridges}
export CARGO_TARGET_DIR=$HERE/build/emu-target

ABIS="" sh build_android.sh
[ -d build/fm1-emu/.git ] || ABIS="" sh build_emu.sh

if [ -n "$IOS_CARTRIDGES_REFRESH" ] || [ ! -f "$LOCK" ]; then
    elixir ios_cartridges.exs lock "$LOCK" $(for c in $CARTRIDGES; do echo "${c%%:*}"; done)
fi

# an id as a C identifier (as the pipeline's c_name: ids have '-')
c_name() { printf %s "$1" | tr -c 'A-Za-z0-9' _; }

# Puts the published cartridge archive $2 (id $1) in $obj as cart_<C name>.o, ready to link, or says on stdout why
# it can't. Reads and extends $obj/globals, the tables already taken. (sh has no locals: its variables start
# with cp_.)
link_published() {
    cp_f=$2
    [ ${#1} -le 62 ] || { echo "its id is longer than the crash marker's 62 characters (c_src/fm1host.c)"; return; }
    cp_c=$(c_name "$1")
    cp_sym=_fm1c_$cp_c
    cp_n=$(ar t "$cp_f" | grep -cv '^__\.SYMDEF' || true)
    [ "$cp_n" = 1 ] || { echo "$cp_n objects, not one"; return; }
    cp_globals=$(nm -gU "$cp_f" | awk 'NF == 3 { print $3 }' | tr '\n' ' ')
    [ "$cp_globals" = "$cp_sym " ] || { echo "its globals are not just $cp_sym: $cp_globals"; return; }
    ! grep -qx "$cp_sym" "$obj/globals" || { echo "$cp_sym is another cartridge's"; return; }
    # the table's state() gives the host its data and BSS by these bounds
    cp_bounds=$(nm -u "$cp_f" | grep -c '^section\$' || true)
    cp_sects=$(nm -u "$cp_f" | sed -nE 's/^section\$(start|end)\$__DATA\$//p' | sort -u)
    [ "$cp_bounds" = 4 ] && [ "$(echo "$cp_sects" | wc -l | tr -d ' ')" = 2 ] ||
        { echo "its data/BSS bounds aren't two __DATA sections: $(nm -u "$cp_f" | grep '^section\$' | tr '\n' ' ')"; return; }
    cp_size=$(xcrun size -m "$cp_f")
    for cp_s in $(echo "$cp_size" | sed -nE 's/^[[:space:]]*Section \(__DATA, ([^)]*)\).*/\1/p'); do
        [ "$cp_s" = __const ] || echo "$cp_sects" | grep -qx "$cp_s" ||
            { echo "writable data outside its sections: __DATA,$cp_s"; return; }
    done
    # which is the data (a regular section) and which the BSS (zerofill); one not in the object takes what's left
    cp_d=
    cp_b=
    for cp_s in $cp_sects; do
        if echo "$cp_size" | grep -q "Section (__DATA, $cp_s): [0-9]* (zerofill)"; then
            [ -z "$cp_b" ] || { echo "its bounds name two zerofill sections"; return; }
            cp_b=$cp_s
        elif echo "$cp_size" | grep -q "Section (__DATA, $cp_s):"; then
            [ -z "$cp_d" ] || { echo "its bounds name two data sections"; return; }
            cp_d=$cp_s
        fi
    done
    for cp_s in $cp_sects; do
        [ "$cp_s" = "$cp_d" ] || [ "$cp_s" = "$cp_b" ] || if [ -z "$cp_d" ]; then cp_d=$cp_s; else cp_b=$cp_s; fi
    done
    cp_dir=$obj/pub/$cp_c
    mkdir -p "$cp_dir"
    (cd "$cp_dir" && ar x "$cp_f")
    for cp_edge in start end; do
        {
            echo ".globl \"section\$$cp_edge\$__DATA\$$cp_d\""
            echo ".globl \"section\$$cp_edge\$__DATA\$$cp_b\""
            echo ".section __DATA,__fm1c_d"
            echo "\"section\$$cp_edge\$__DATA\$$cp_d\":"
            echo ".byte 0"
            echo ".zerofill __DATA,__fm1c_b,\"section\$$cp_edge\$__DATA\$$cp_b\",1,0"
        } > "$cp_dir/$cp_edge.s"
        $cc -c "$cp_dir/$cp_edge.s" -o "$cp_dir/$cp_edge.o"
    done
    xcrun -sdk $sdk ld -r -arch arm64 "$cp_dir/start.o" "$cp_dir/$(ar t "$cp_f" | grep -v '^__\.SYMDEF')" \
        "$cp_dir/end.o" -o "$obj/cart_$cp_c.o" -exported_symbol "$cp_sym" \
        -rename_section __DATA "$cp_d" __DATA __fm1c_d -rename_section __DATA "$cp_b" __DATA __fm1c_b
    rm -rf "$cp_dir"
    if nm -u "$obj/cart_$cp_c.o" | grep -q '^section\$'; then
        rm -f "$obj/cart_$cp_c.o"
        echo "its bounds didn't bind to the markers"
        return
    fi
    printf 'extern const char %s;\nint main(void) { return (int)(long)&%s; }\n' "${cp_sym#_}" "${cp_sym#_}" \
        > "$obj/probe.c"
    if ! cp_log=$($cc "$obj/probe.c" "$obj/cart_$cp_c.o" -lc++ -Wl,-fatal_warnings -o "$obj/probe" 2>&1); then
        rm -f "$obj/cart_$cp_c.o"
        echo "it doesn't link for $t: $(echo "$cp_log" | grep -v '^clang: error' | head -3 | tr '\n' ' ')"
        return
    fi
    echo "$cp_sym" >> "$obj/globals"
}

for t in $TARGETS; do
    case $t in
        sim) sdk=iphonesimulator; triple=arm64-apple-ios$MIN_IOS-simulator; rust=aarch64-apple-ios-sim
             platform=ios-sim ;;
        device) sdk=iphoneos; triple=arm64-apple-ios$MIN_IOS; rust=aarch64-apple-ios; platform=ios-device ;;
        host) sdk=macosx; triple=arm64-apple-macos; rust=aarch64-apple-darwin; platform= ;;
        *) echo "unknown target $t"; exit 1 ;;
    esac
    out=build/ios/$t
    obj=$out/obj
    rm -rf "$obj"
    mkdir -p "$obj"
    cc="xcrun -sdk $sdk clang -target $triple"
    : > "$obj/carts"                              # id version symbol commit sha256 caps_bits, per linked cartridge
    : > "$obj/globals"
    : > "$obj/left_out"
    published=0

    $cc $CFLAGS -c -DFM1ENGINE_LIB engine/fm1engine.c -o "$obj/fm1engine.o"

    for c in $CARTRIDGES; do
        name=${c%%:*}
        version=${c#*:}
        src=build/fw/$name
        # the firmwares put a few buffers in an ELF section (".pool") that Mach-O can't name: plain BSS here
        $cc $CFLAGS -c -fvisibility=hidden -D'section(x)=' -DAPP_VER="\"$version\"" \
            -DFW_MAIN="\"$HERE/$src/firmware/src/$name.c\"" -DFM1C_TABLE="fm1c_$name" \
            -DFM1C_DATA="\"__${name}_d\"" -DFM1C_BSS="\"__${name}_b\"" \
            -I"$src/firmware/src" -I"$src/firmware/gen" -Iengine engine/live.c -o "$obj/live_$name.o"
        xcrun -sdk $sdk ld -r -arch arm64 "$obj/live_$name.o" -o "$obj/cart_$name.o" -exported_symbol "_fm1c_$name" \
            -rename_section __DATA __data __DATA "__${name}_d" -rename_section __DATA __bss __DATA "__${name}_b"
        # every writable global must be in the two sections the reset restores
        other=$(xcrun size -m "$obj/cart_$name.o" | grep 'Section (__DATA' | grep -v -e '__const)' \
            -e "__${name}_d)" -e "__${name}_b)" || true)
        if [ -n "$other" ]; then
            echo "cartridge $name has writable data outside __${name}_d / __${name}_b:"
            echo "$other"
            exit 1
        fi
        echo "$name $version fm1c_$name - - 0" >> "$obj/carts"
        echo "_fm1c_$name" >> "$obj/globals"
    done

    if [ -n "$platform" ]; then
        elixir ios_cartridges.exs fetch "$LOCK" "$platform" "$CART_CACHE" > "$obj/fetched"
        while read -r id version f commit sha caps; do
            why=$(link_published "$id" "$f")
            if [ -n "$why" ]; then
                echo "  $id $version: $why" >> "$obj/left_out"
            else
                echo "$id $version fm1c_$(c_name "$id") $commit $sha $caps" >> "$obj/carts"
                published=$((published + 1))
            fi
        done < "$obj/fetched"
    fi

    {
        echo "/* generated by native/build_ios.sh: the cartridges in this libfm1native.a, for c_src/fm1host.c */"
        echo '#include "fm1engine.h"'
        while read -r id version table commit sha caps; do echo "extern const struct fm1c_api $table;"; done < "$obj/carts"
        echo "const struct fm1native_cart fm1native_carts[] = {"
        while read -r id version table commit sha caps; do
            [ "$commit" != "-" ] || commit=
            [ "$sha" != "-" ] || sha=
            echo "    {\"$id\", \"$version\", &$table, \"$commit\", \"$sha\", $caps},"
        done < "$obj/carts"
        echo "};"
        echo "const size_t fm1native_ncarts = sizeof fm1native_carts / sizeof fm1native_carts[0];"
        echo "const char fm1native_carts_layout_2 = 1;"
    } > "$obj/fm1native_carts.c"
    $cc $CFLAGS -c -Iengine "$obj/fm1native_carts.c" -o "$obj/fm1native_carts.o"

    if [ "$published" -gt 0 ]; then
        # every cartridge linked as the app links them: each one's data and BSS between its own markers (the
        # built-ins' crash-marker calls, c_src/fm1host.c's in the app, stubbed)
        {
            echo '#include "fm1engine.h"'
            echo 'const void *fm1host_marker(void) { return 0; }'
            echo 'void fm1host_set_marker(const void *m) { (void)m; }'
            echo 'int main(void) { return (int)fm1native_ncarts + (fm1native_carts[0].api != 0); }'
        } > "$obj/probe.c"
        $cc -Iengine "$obj/probe.c" "$obj/fm1native_carts.o" "$obj"/cart_*.o -lc++ -Wl,-dead_strip \
            -Wl,-map,"$obj/probe.map" -o "$obj/probe"
        elixir ios_cartridges.exs layout "$obj/probe.map"
        rm -f "$obj/probe.c" "$obj/probe" "$obj/probe.map"
    fi

    IPHONEOS_DEPLOYMENT_TARGET=$MIN_IOS cargo rustc -q --release --lib --crate-type staticlib \
        --manifest-path emu/Cargo.toml --target "$rust"

    sh ios_archive.sh "$sdk" "$out/libfm1native.a" "$obj"/fm1engine.o "$obj"/cart_*.o "$obj/fm1native_carts.o" \
        "$CARGO_TARGET_DIR/$rust/release/libfm1emu.a"
    echo "$t: $out/libfm1native.a ($(du -h "$out/libfm1native.a" | cut -f1)), $(wc -l < "$obj/carts" | tr -d ' ') cartridges"
    if [ -s "$obj/left_out" ]; then
        echo "warning: $t: $(wc -l < "$obj/left_out" | tr -d ' ') published cartridges left out (they play emulated):" >&2
        cat "$obj/left_out" >&2
    fi
    if [ "$t" = host ]; then
        erts=$(erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
        mkdir -p build/host
        $cc $CFLAGS -bundle -undefined dynamic_lookup -I"$erts" ../c_src/fm1host.c "$out/libfm1native.a" \
            -o build/host/fm1host.so
        echo "host: build/host/fm1host.so"
    fi
done

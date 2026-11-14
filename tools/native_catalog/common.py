"""Shared by tools/native_catalog/build.py and its recipes (tools/native_catalog/recipes/*.py): paths, pins, the
compilers per target, running a command into the build log, linking a cartridge."""
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CAT = Path(os.environ.get("FM1_CATALOG_DIR") or ROOT / "native/build/catalog")   # (work dir: sources, objects, results)
SRC = CAT / "src"
PINS = json.loads((HERE / "pins.json").read_text())
EMCC_DIR = HERE / "emcc"
SHIM_INC = HERE / "shims/include"
NDK_API = 28
MIN_IOS = "17.0"                                        # (Mob's deployment target)
IOS = {"ios-device": ("iphoneos", f"arm64-apple-ios{MIN_IOS}"),
       "ios-sim": ("iphonesimulator", f"arm64-apple-ios{MIN_IOS}-simulator")}


def ndk_bin():
    ndk = os.environ.get("ANDROID_NDK_HOME") or str(Path.home() / "Android/Sdk/ndk/27.2.12479018")
    if not Path(ndk).is_dir():
        ndk = str(Path.home() / "Library/Android/sdk/ndk/27.2.12479018")
    host = "darwin-x86_64" if sys.platform == "darwin" else "linux-x86_64"
    return Path(ndk) / "toolchains/llvm/prebuilt" / host / "bin"


def target_cc(target):
    """(compiler argv, extra compile flags, extra link flags) for a target"""
    if target == "host":
        return [os.environ.get("CC", "cc")], [], []
    if target.startswith("android-"):
        abi = target[len("android-"):]
        triple = {"arm64-v8a": "aarch64-linux-android", "armeabi-v7a": "armv7a-linux-androideabi",
                  "x86_64": "x86_64-linux-android"}[abi]
        # 16 KB pages (Android 15+), the static symbol table stripped (the fm1c_* exports stay)
        return [str(ndk_bin() / f"{triple}{NDK_API}-clang")], [], ["-Wl,-z,max-page-size=16384", "-s"]
    if target in IOS:                                   # (static: linked into the app, link() below)
        sdk, triple = IOS[target]
        return ["xcrun", "-sdk", sdk, "clang", "-target", triple], ["-fno-common"], []
    raise SystemExit(f"unknown target {target}")


def sh(cmd, cwd, env=None, log=None, timeout=900):
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
                       shell=isinstance(cmd, str))
    if log is not None:
        log.append(f"$ {cmd if isinstance(cmd, str) else shlex.join(cmd)}  (in {cwd})\n{r.stdout[-4000:]}{r.stderr[-6000:]}")
    return r.returncode


SKIP = {"node_modules", ".git", "build", "experiments", "vendor"}


def c_name(fid):
    """an id as a C identifier (ids have '-')"""
    return "".join(ch if ch.isalnum() else "_" for ch in fid)


def link_ios(fid, target, objs, cpp, log):
    """libcart_<id>.a for the iOS app: one relocatable object (ld -r) whose only global is the table fm1c_<id>
    (adapters/ios_table.c), its writable data and BSS in sections of their own for the app's host to restore before
    each boot (FMutate's native/build_ios.sh does the same for its bundled cartridges)."""
    sdk, triple = IOS[target]
    cc = ["xcrun", "-sdk", sdk, "clang", "-target", triple]
    work = CAT / "obj" / target / fid
    tag = __import__("hashlib").sha1(fid.encode()).hexdigest()[:8]  # (Mach-O section names: 16 characters)
    sd, sb = f"__c{tag}d", f"__c{tag}b"
    table = work / "ios_table.o"
    if sh([*cc, "-O2", "-c", f"-DFM1C_TABLE=fm1c_{c_name(fid)}", f'-DFM1C_DATA="{sd}"', f'-DFM1C_BSS="{sb}"',
           str(HERE / "adapters/ios_table.c"), "-o", str(table)], ROOT, log=log):
        return None
    one = work / f"cart_{fid}.o"
    if sh(["xcrun", "-sdk", sdk, "ld", "-r", "-arch", "arm64", str(table), *objs, "-o", str(one),
           "-exported_symbol", f"_fm1c_{c_name(fid)}", "-rename_section", "__DATA", "__data", "__DATA", sd,
           "-rename_section", "__DATA", "__bss", "__DATA", sb, "-rename_section", "__DATA", "__common", "__DATA", sb],
          ROOT, log=log):
        return None
    out = CAT / "out" / target / f"libcart_{fid}.a"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.unlink(missing_ok=True)
    if sh(["xcrun", "-sdk", sdk, "libtool", "-static", "-o", str(out), str(one)], ROOT, log=log):
        return None
    return out


def link(fid, target, objs, cpp, log):
    if target in IOS:
        return link_ios(fid, target, objs, cpp, log)
    cc, cflags_t, lflags_t = target_cc(target)
    out = CAT / "out" / target / f"libcart_{fid}.so"
    out.parent.mkdir(parents=True, exist_ok=True)
    libs = ["-lm"] + (["-lpthread"] if not target.startswith("android") else [])
    if cpp:                                             # (C++ in the firmware: its runtime linked in, not shared)
        libs += ["-lc++"] if target == "host" and sys.platform == "darwin" else ["-static-libstdc++", "-lstdc++"] \
            if target == "host" else ["-static-libstdc++"]
        cc = [cc[0] + "++"] if target.startswith("android") else cc
    undef = [] if sys.platform == "darwin" and target == "host" else ["-Wl,--no-undefined"]
    if sh([*cc, "-shared", "-fPIC", *lflags_t, "-o", str(out), *objs, *libs, *undef], ROOT, log=log):
        return None
    return out

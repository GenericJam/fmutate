"""Recipe "foma": the foma framework's emulator (konsumer/fomajam, Spellbox: platform/web.c, the API of fm1.h over a
simulated FM-1, compiled with the app by `clang --target=wasm32` in tools/build.py's build_wasm). The firmware's
own tools/build.py runs with a recording stand-in as clang on PATH (tools/native_catalog/emcc/emcc under that name:
the samples, ROMs and tables are generated as for the emulator); the recorded compile is replayed natively, its
freestanding libc (platform/src/libc.c: memset, memcpy, memcmp) renamed out of the C library's way, and
adapters/foma.c links in front: the fm1c_* calls."""
import shutil
import sys
from pathlib import Path

from common import CAT, HERE, SHIM_INC, link, sh, target_cc
from recipes import _entry, web

ORDER = 30

LIBC_RENAMES = ["-Dmemset=fm1n_memset", "-Dmemcpy=fm1n_memcpy", "-Dmemcmp=fm1n_memcmp"]


def detect(d, fid):
    w, b = d / "platform/web.c", d / "tools/build.py"
    if not w.exists() or not b.exists():
        return None
    t = w.read_text(errors="replace")
    if "web_boot" in t and "web_encoder" in t and "def build_wasm" in b.read_text(errors="replace"):
        return {"recipe": "foma", "entry": "platform/web.c"}
    return None


def record(fid, log):
    # tools/build.py stops before anything without a JieLi toolchain; one that fails lets it build the emulator
    # (recorded) and then stop at the FM-1 build
    fake = CAT / "fake-jieli/pi32v2/bin/clang"
    fake.parent.mkdir(parents=True, exist_ok=True)
    fake.write_text("#!/bin/sh\necho 'native_catalog: no JieLi toolchain' >&2\nexit 1\n")
    fake.chmod(0o755)
    cmds = _entry.record(fid, [sys.executable, "tools/build.py"], stand_ins=("clang",), clean=["build"],
                         env_extra={"JIELI_TOOLCHAIN": str(CAT / "fake-jieli")}, log=log)
    return [c for c in cmds if any(a.startswith("--target=wasm32") for a in c["args"])]


def build_once(fid, cmd, target, shims, log):
    cc, cflags_t, _ = target_cc(target)
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    cwd = Path(cmd["cwd"])
    flags, srcs, _, _, _ = web.split_cmd(cmd)
    flags = [f for f in flags if not f.startswith(("--target", "-nostdlib", "-Wl,", "-O"))]
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-O2", "-ffp-contract=off", "-fno-strict-aliasing", *cflags_t, *shimflags, *LIBC_RENAMES]
    objs = []
    for i, s in enumerate(srcs):
        o = work / f"{i:03d}_{Path(s).stem}.o"
        if sh([*cc, *base, *flags, "-c", s, "-o", str(o)], cwd, log=log):
            return None, "compile"
        objs.append(str(o))
    have = web.defined_symbols(objs, target)
    defs = ["-DFOMA_HAS_FLASH=1"] if "web_flash" in have else []
    adapter = work / "adapter_foma.o"
    if sh([*cc, "-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *flags, *defs, "-I", str(HERE / "adapters"),
           "-c", str(HERE / "adapters/foma.c"), "-o", str(adapter)], cwd, log=log):
        return None, "adapter"
    out = link(fid, target, [str(adapter), *objs], False, log)
    return (out, None) if out else (None, "link")


def build(fid, r, target, log, res):
    cmds = record(fid, log)
    if not cmds:
        return None, "record"
    stage = None
    for shims in (False, True):
        out, stage = build_once(fid, cmds[0], target, shims, log)
        res["shims"] = shims
        if out:
            return out, None
    return None, stage

"""Recipe "bubba": Bubba Machine's emulator sources (tools/build.py's web(): SRC = the portable core + hal/bm_hal_sim.c,
CXX_SRC = its C++ engines, with CFLAGS / CXXFLAGS; the emulator itself is built in an Emscripten Docker image, so
nothing is recorded: the lists and flags are read from the firmware's own tools/build.py). Compiled natively with
adapters/bubba.c in hal/web/hal_web.c's place for the fm1c_* calls."""
import glob
import importlib.util
import shlex
import shutil
import sys
from pathlib import Path

from common import CAT, HERE, SHIM_INC, SRC, link, sh, target_cc

ORDER = 30


def detect(d, fid):
    b = d / "tools/build.py"
    if (d / "hal/web/hal_web.c").exists() and (d / "hal/bm_hal_sim.c").exists() and b.exists() \
            and "CXX_SRC" in b.read_text(errors="replace"):
        return {"recipe": "bubba"}
    return None


def firmware_build(d):
    """the firmware's tools/build.py as a module (its lists and flags; nothing of it runs here)"""
    spec = importlib.util.spec_from_file_location("bubba_build", d / "tools/build.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def build_once(fid, fw, target, shims, log):
    d = SRC / fid
    cc, cflags_t, _ = target_cc(target)
    cxx = [cc[0] + "++"] if target.startswith("android") else ["c++"]
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-ffp-contract=off", *cflags_t, *shimflags]
    drop = ("-O", "-g", "-W")
    cflags = [f for f in shlex.split(fw.CFLAGS) if not f.startswith(drop)]
    cxxflags = [f for f in shlex.split(fw.CXXFLAGS) if not f.startswith(drop)]
    csrc = sorted(set(p for pat in fw.SRC.split() for p in glob.glob(pat, root_dir=d)))
    objs = []
    for i, s in enumerate(csrc):
        o = work / f"c{i:03d}_{Path(s).stem}.o"
        if sh([*cc, *base, "-O2", *cflags, "-c", s, "-o", str(o)], d, log=log):
            return None, "compile"
        objs.append(str(o))
    for i, s in enumerate(fw.CXX_SRC.split()):
        o = work / f"x{i:03d}_{Path(s).stem}.o"
        if sh([*cxx, *base, "-O2", *cxxflags, "-c", s, "-o", str(o)], d, log=log):
            return None, "compile"
        objs.append(str(o))
    o = work / "adapter_bubba.o"
    if sh([*cc, *base, "-O2", *cflags, "-Ihal", "-Icore", "-I", str(HERE / "adapters"), "-c",
           str(HERE / "adapters/bubba.c"), "-o", str(o)], d, log=log):
        return None, "adapter"
    out = link(fid, target, [str(o), *objs], True, log)
    return (out, None) if out else (None, "link")


def build(fid, r, target, log, res):
    d = SRC / fid
    try:
        fw = firmware_build(d)
    except Exception as e:                              # (its imports, a changed layout)
        log.append(f"bubba: tools/build.py: {e!r}")
        return None, "recipe"
    sh([sys.executable, "tools/gen_lang.py"], d, log=log)   # (as web() does first)
    stage = None
    for shims in (False, True):
        out, stage = build_once(fid, fw, target, shims, log)
        res["shims"] = shims
        if out:
            return out, None
    return None, stage

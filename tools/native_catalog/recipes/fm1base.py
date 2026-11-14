"""Recipe "fm1base": an fm1-base app (charlesvestal/fm1-base: <base>/tools/build.py, <base>/host/plat_host.c) whose
tree has no browser entry (<base>/web/emu/emu_web.c, which recipe "web" builds), only the host simulator: J6's
vendored fm1-base, the Audio Router's fork. The firmware's own `tools/build.py APP --host` runs with
tools/native_catalog/emcc/emcc as $CC (it records each compile, generating the fonts and words as for the
simulator); the calls are replayed natively, plat_host.c's own replaced by adapters/fm1base.c (which includes it with
PLAT_WEB and exports the web_* calls), and adapters/web.c maps those to the fm1c_* calls."""
import json
import shutil
import sys
from pathlib import Path

from common import CAT, EMCC_DIR, HERE, ROOT, SHIM_INC, SKIP, SRC, link, sh, target_cc
from recipes import web

ORDER = 30


def detect(d, fid):
    for host in sorted(d.glob("**/host/plat_host.c"), key=lambda p: len(p.parts)):
        base = host.parents[1]
        rel = base.relative_to(d)
        if set(rel.parts) & SKIP or (base / "web/emu/emu_web.c").exists():
            continue
        bp = base / "tools/build.py"
        if not bp.exists() or "def build_host" not in bp.read_text(errors="replace") \
                or "PLAT_WEB" not in host.read_text(errors="replace"):
            continue
        tomls = [p for p in d.rglob("fm1.toml") if not set(p.relative_to(d).parts) & (SKIP | {"tests", "template"})]
        if not tomls:
            continue
        # the app: an fm1.toml outside the base first (J6: the repository's root), else one in it (the Audio Router)
        tomls.sort(key=lambda p: (base in p.parents, len(p.relative_to(d).parts)))
        return {"recipe": "fm1base", "base": str(rel), "app": str(tomls[0].parent.relative_to(d))}
    return None


def record(fid, r, log):
    d = SRC / fid
    rec = CAT / "rec" / f"{fid}.jsonl"
    rec.parent.mkdir(parents=True, exist_ok=True)
    rec.unlink(missing_ok=True)
    env = web.gen_env(rec)
    env["CC"] = str(EMCC_DIR / "emcc")                  # (tools/build.py --host compiles with $CC)
    shutil.rmtree(d / r["app"] / "build", ignore_errors=True)
    sh([sys.executable, str(d / r["base"] / "tools/build.py"), r["app"], "--host"], d, env, log)
    return [json.loads(l) for l in rec.read_text().splitlines()] if rec.exists() else []


def build_once(fid, r, cmds, target, shims, log):
    d = SRC / fid
    cc, cflags_t, _ = target_cc(target)
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    plat = (d / r["base"] / "host/plat_host.c").resolve()
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-O2", "-ffp-contract=off", "-fno-strict-aliasing", *cflags_t, *shimflags]
    objs, entry = [], False
    for n, c in enumerate(cmds):
        if c["tool"] != "emcc" or set(c["args"]) & {"-M", "-MM", "-E"}:
            continue
        flags, srcs, _, _, _ = web.split_cmd(c)
        cwd = Path(c["cwd"])
        for i, s in enumerate(srcs):
            o = work / f"{n:03d}_{i}_{Path(s).stem}.o"
            if (cwd / s).resolve() == plat:            # the simulator's main unit: our entry in its place
                s, entry = str(HERE / "adapters/fm1base.c"), True
                flags = [*flags, "-DPLAT_WEB", "-I", str(plat.parent)]
            if sh([*cc, *base, *flags, "-c", s, "-o", str(o)], cwd, log=log):
                return None, "compile"
            objs.append(str(o))
    if not entry:
        return None, "record"
    defs = ["-DWEB_MASTER_MAX=4096u"]
    defs += [f"-DWEB_HAS_{s}=1" for s in sorted(web.defined_symbols(objs, target)) if s.startswith("web_")]
    adapter = work / "adapter_web.o"
    if sh([*cc, "-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *defs, "-c",
           str(HERE / "adapters/web.c"), "-o", str(adapter)], ROOT, log=log):
        return None, "adapter"
    out = link(fid, target, [str(adapter), *objs], False, log)
    return (out, None) if out else (None, "link")


def build(fid, r, target, log, res):
    cmds = record(fid, r, log)
    res["cc_calls"] = len(cmds)
    stage = None
    for shims in (False, True):
        out, stage = build_once(fid, r, cmds, target, shims, log)
        res["shims"] = shims
        if out or stage == "record":
            return out, stage
    return None, stage

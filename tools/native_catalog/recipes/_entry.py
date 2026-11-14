"""Shared by the recipes that record a firmware's own host or browser build and replay it natively with an adapter
in front (fm1base, demake, guitchordi, gator, bubba, kawawasm, fm1open, adrift, ...). Not a recipe itself (build.py
loads recipes/[a-z]*.py only).

record(): run the firmware's own build command with tools/native_catalog/emcc/emcc standing in for the compilers it
calls (emcc on PATH; also `cc`/`clang` by those names, or $CC), so it generates its tables and fonts as it always does
and each compile is logged. replay(): compile each logged unit natively; the firmware's entry unit (its browser or
host main file) either replaced by the adapter, which #includes it as FM1N_ENTRY (its path; mode "include"), or compiled as it is with
the adapter beside it ("beside"); link the cartridge."""
import json
import shutil
from pathlib import Path

from common import CAT, EMCC_DIR, HERE, SHIM_INC, SRC, link, sh, target_cc
from recipes import web

COMPILERS = ("emcc", "em++", "cc", "clang", "gcc", "c++", "clang++", "g++")
CXX = ("em++", "c++", "clang++", "g++")


def record(fid, cmd, cwd=None, stand_ins=(), env_extra=None, cc_env=False, clean=(), log=None):
    """run cmd (in SRC/fid or cwd) with the recording stand-in on PATH as emcc and as each name in stand_ins
    (and as $CC / $CXX if cc_env); the logged compiles"""
    d = SRC / fid
    rec = CAT / "rec" / f"{fid}.jsonl"
    rec.parent.mkdir(parents=True, exist_ok=True)
    rec.unlink(missing_ok=True)
    env = web.gen_env(rec)
    if stand_ins:
        stand = CAT / "bin-rec"
        stand.mkdir(parents=True, exist_ok=True)
        for name in stand_ins:
            (stand / name).unlink(missing_ok=True)
            (stand / name).symlink_to(EMCC_DIR / "emcc")
        env["PATH"] = f"{stand}:{env['PATH']}"
    if cc_env:
        stand = CAT / "bin-rec"
        stand.mkdir(parents=True, exist_ok=True)
        for name in ("cc", "c++"):
            (stand / name).unlink(missing_ok=True)
            (stand / name).symlink_to(EMCC_DIR / "emcc")
        env["CC"], env["CXX"] = str(stand / "cc"), str(stand / "c++")
    env.update(env_extra or {})
    for c in clean:
        shutil.rmtree(d / c, ignore_errors=True)
    sh(cmd, cwd or d, env, log)
    cmds = [json.loads(l) for l in rec.read_text().splitlines()] if rec.exists() else []
    return [c for c in cmds if c["tool"] in COMPILERS and not set(c["args"]) & {"-M", "-MM", "-E", "--version", "-v"}]


DROP = ("--target", "-nostdlib", "-Wl,", "-O", "-fsanitize", "-fno-sanitize", "-g", "-ffreestanding", "-Werror",
        "--sysroot", "-mbulk-memory", "-msimd128", "-flto")


def replay(fid, cmds, target, shims, log, entry, adapter, mode="include", extra=(), adapter_flags=(), keep=None,
           libs_cpp=None):
    """(objects, error stage). entry: the firmware's entry unit (absolute path); adapter: adapters/<name>.c.
    keep(src) -> False drops a logged unit (a test, a tool). extra: flags for every unit."""
    cc, cflags_t, _ = target_cc(target)
    cxx = [cc[0] + "++"] if target.startswith("android") else ["c++"] if target == "host" else cc
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-O2", "-ffp-contract=off", "-fno-strict-aliasing", *cflags_t, *shimflags, *extra]
    objs, found, seen, cpp = [], None, set(), False
    for n, c in enumerate(cmds):
        flags, srcs, _, _, _ = web.split_cmd(c)
        flags = [f for f in flags if not f.startswith(DROP)]
        cwd = Path(c["cwd"])
        for i, s in enumerate(srcs):
            p = (cwd / s).resolve()
            if p in seen or (keep and not keep(p)):
                continue
            seen.add(p)
            is_cpp = c["tool"] in CXX or p.suffix in (".cc", ".cpp", ".cxx")
            comp = [*(cxx if is_cpp else cc)]
            cpp = cpp or is_cpp
            o = work / f"{n:03d}_{i}_{p.stem}.o"
            if p == entry.resolve():
                found = flags
                if mode == "include":
                    s = str(HERE / "adapters" / adapter)
                    comp = [*cc]
                    flags = [*flags, *adapter_flags, f'-DFM1N_ENTRY="{p}"', "-I", str(p.parent), "-I", str(HERE / "adapters")]
            std = [f for f in flags if f.startswith("-std=")]
            if is_cpp and std and "c++" not in std[-1] and "gnu++" not in std[-1]:
                flags = [f for f in flags if not f.startswith("-std=")]
            if sh([*comp, *base, *flags, "-c", s, "-o", str(o)], cwd, log=log):
                return None, "compile", cpp
            objs.append(str(o))
    if found is None:
        return None, "record", cpp
    if mode == "beside":
        o = work / "adapter.o"
        if sh([*cc, *base, *found, *adapter_flags, "-I", str(HERE / "adapters"), "-c", str(HERE / "adapters" / adapter),
               "-o", str(o)], Path(cmds[0]["cwd"]), log=log):
            return None, "adapter", cpp
        objs.insert(0, str(o))
    return objs, None, cpp


def build_with(fid, cmds, target, log, res, entry, adapter, **kw):
    """replay plainly, then with the generic shims; link"""
    stage = "record"
    if not cmds:
        return None, stage
    for shims in (False, True):
        objs, stage, cpp = replay(fid, cmds, target, shims, log, entry, adapter, **kw)
        res["shims"] = shims
        if stage == "record":
            return None, stage
        if objs:
            out = link(fid, target, objs, cpp, log)
            if out:
                return out, None
            stage = "link"
    return None, stage

"""Recipe "wasm": a firmware's own browser build that is not the X0X lineage's web_* API (recipes/web.py): clang
--target=wasm32, `zig cc` (also `python3 -m ziglang cc`), a WASI SDK's clang, or Emscripten, each firmware with the
panel API its page calls. The build script runs as its author wrote it with tools/native_catalog/wasmcc (and the
emcc stand-in) first on PATH, which record each wasm compile; the compile of the simulator's entry is replayed with
a native compiler (the wasm-only flags dropped), and the adapter of its API family (adapters/<family>.c) maps that
API to the fm1c_* calls of native/engine/live.c.

A family: the file that has the API (markers: names it defines), the script that builds it (one that names
`mention`, default the file), the adapter, defines for the firmware's units (`fw_defs`: its own native build's, as
zp12's SIM_NATIVE) and `unity`: the adapter #includes the entry (FW_ENTRY) instead of linking it (an API whose
state is static in the entry)."""
import json
import os
import re
import shutil
import sys
from pathlib import Path

from common import CAT, HERE, ROOT, SHIM_INC, SKIP, SRC, link, sh, target_cc
from recipes import web

ORDER = 30
WASMCC = HERE / "wasmcc"
ADAPTERS = HERE / "adapters"

FAMILIES = [
    # zp12's sim/sim.c (OberVave's web/sim pattern): the sim_* panel API, the main loop a coroutine natively
    {"family": "sim", "file": "sim.c", "markers": ["sim_render", "sim_screen", "sim_init", "sim_out_l"],
     "fw_defs": ["-DSIM_NATIVE=1"]},
]


def scripts_for(d, name):
    """the scripts that compile `name` for the browser (sh, py, Makefile), the shell scripts first"""
    out = []
    for p in d.rglob("*"):
        rel = p.relative_to(d)
        if not p.is_file() or set(rel.parts) & SKIP:
            continue
        if p.suffix in (".sh", ".py", ".mk") or p.name in ("Makefile", "makefile"):
            t = p.read_text(errors="replace")
            if name in t and re.search(r"wasm32|\bemcc\b", t):
                out.append(rel)
    out.sort(key=lambda r: (r.suffix != ".sh", len(r.parts), str(r)))
    return [str(r) for r in out]


def detect(d, fid):
    for fam in FAMILIES:
        for p in sorted(d.rglob(fam["file"]), key=lambda p: (len(p.parts), str(p))):
            rel = p.relative_to(d)
            if set(rel.parts) & SKIP:
                continue
            t = p.read_text(errors="replace")
            if not all(re.search(r"\b%s\s*\(" % m, t) for m in fam["markers"]):
                continue
            scripts = scripts_for(d, fam.get("mention", p.name))
            if scripts:
                return {"recipe": "wasm", "family": fam["family"], "entry": str(rel), "scripts": scripts}
    return None


# ------------------------------------------------------------------------------------------------ record ---

def record(fid, r, fam, log):
    d = SRC / fid
    rec = CAT / "rec" / f"{fid}.jsonl"
    rec.parent.mkdir(parents=True, exist_ok=True)
    rec.unlink(missing_ok=True)
    env = web.gen_env(rec)
    env["PATH"] = f"{WASMCC}:{env['PATH']}"
    env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(WASMCC / "pyshim"), env.get("PYTHONPATH")]))
    env["WASI_SDK"] = str(WASMCC / "wasi")
    env.pop("CC", None)
    env.update(fam.get("env", {}))
    entry = Path(r["entry"]).name
    for s in r["scripts"]:
        if s.endswith(".sh"):
            cmd = ["sh", s]
        elif s.endswith(".py"):
            cmd = [sys.executable, s, *fam.get("script_args", [])]
        else:
            cmd = ["make", "-f", s, *fam.get("make_args", [])]
        sh(cmd, d, env, log)
        if rec.exists() and entry in rec.read_text():
            break
    return [json.loads(l) for l in rec.read_text().splitlines()] if rec.exists() else []


# ------------------------------------------------------------------------------------------------ replay ---

WASM_DROP_ARG = {"-target", "--target", "--sysroot", "-mllvm"}
WASM_DROP_PREFIX = ("--target=", "-target=", "-mcpu=", "-nostdlib", "--sysroot=", "-Wl,", "-mexec-model", "-mbulk",
                    "-msimd", "-mmultivalue", "-mreference-types", "-mtail-call", "-fuse-ld", "-z")


def clean_flags(args):
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a in WASM_DROP_ARG:
            i += 2
            continue
        if not a.startswith(WASM_DROP_PREFIX) and a != "-s":
            out.append(a)
        i += 1
    return out


def replay(fid, r, fam, cmds, target, shims, log):
    """the entry's compile, natively: (objects, the entry's flags) or None"""
    d = SRC / fid
    cc, cflags_t, _ = target_cc(target)
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    entry = (d / r["entry"]).resolve()
    want = (d / fam["compiled"]).resolve() if fam.get("compiled") else entry
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-O2", "-ffp-contract=off", "-fno-strict-aliasing", "-fvisibility=hidden", *cflags_t,
            "-I", str(ADAPTERS / "include"), *shimflags, *fam.get("fw_defs", [])]
    produced, n = {}, 0
    for c in cmds:
        cwd = Path(c["cwd"])
        if c["tool"] == "emar":
            if len(c["args"]) >= 2:
                produced[str((cwd / c["args"][1]).resolve())] = [m for m in (produced.get(str((cwd / a).resolve()))
                                                                            for a in c["args"][2:]) if m]
            continue
        if c["tool"] not in ("emcc", "em++", "clang") or set(c["args"]) & {"-M", "-MM", "-E"}:
            continue
        flags, srcs, objs, out, comp = web.split_cmd({"args": clean_flags(c["args"])})
        flags = [f for f in flags if not re.match(r"^-O[0-3sz]$", f)]
        if not comp and want not in [(cwd / s).resolve() for s in srcs] and \
                not any(isinstance(produced.get(str((cwd / o).resolve())), str) and
                        produced.get(str((cwd / o).resolve()) + "#want") for o in objs):
            # (a link without the entry: compile-only steps are remembered below, other links skipped)
            continue
        mine, entry_flags = [], None
        for s in srcs:
            sp = (cwd / s).resolve()
            if sp == want:
                entry_flags = (cwd, flags)
                if fam.get("unity"):
                    continue
            n += 1
            o = work / f"{n:03d}_{Path(s).stem}.o"
            cpp = c["tool"] == "em++" or s.endswith((".cc", ".cpp", ".cxx"))
            if sh([*cc, *(["-x", "c++"] if cpp and s.endswith(".c") else []), *base, *flags, "-c", s, "-o", str(o)],
                  cwd, log=log):
                return None, "compile"
            mine.append(str(o))
        if comp:
            if mine and (out or srcs):
                key = str((cwd / (out or Path(srcs[0]).stem + ".o")).resolve())
                produced[key] = mine[0]
                if entry_flags:
                    produced[key + "#want"] = entry_flags
            continue
        objs_all = list(mine)
        for o in objs:
            p = produced.get(str((cwd / o).resolve()))
            if p:
                objs_all += p if isinstance(p, list) else [p]
            ef = produced.get(str((cwd / o).resolve()) + "#want")
            entry_flags = entry_flags or ef
        return {"objs": objs_all, "entry_flags": entry_flags, "base": base}, None
    return None, "record"


def build(fid, r, target, log, res):
    fam = next(f for f in FAMILIES if f["family"] == r["family"])
    cmds = record(fid, r, fam, log)
    res["wasm_calls"] = len(cmds)
    cc, cflags_t, _ = target_cc(target)
    stage = None
    for shims in (False, True):
        final, stage = replay(fid, r, fam, cmds, target, shims, log)
        res["shims"] = shims
        if not final:
            if stage == "record":
                break
            continue
        aflags = ["-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *fam.get("adapter_defs", [])]
        cwd = ROOT
        if fam.get("unity"):
            cwd, flags = final["entry_flags"]
            aflags = [*final["base"], *flags, *fam.get("adapter_defs", []),
                      f'-DFW_ENTRY="{(SRC / fid / (fam.get("compiled") or r["entry"])).resolve()}"']
        adapter = CAT / "obj" / target / fid / f"adapter_{fam['family']}.o"
        if sh([*cc, *aflags, "-c", str(ADAPTERS / f"{fam['family']}.c"), "-o", str(adapter)], cwd, log=log):
            stage = "adapter"
            continue
        out = link(fid, target, [str(adapter), *final["objs"]], False, log)
        if out:
            return out, None
        stage = "link"
    return None, stage

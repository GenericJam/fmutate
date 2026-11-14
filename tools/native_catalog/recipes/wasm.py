"""Recipe "wasm": a firmware's own browser build that is not the X0X lineage's web_* API (recipes/web.py): clang
--target=wasm32, `zig cc` (also `python3 -m ziglang cc`), a WASI SDK's clang, or Emscripten, each firmware with the
panel API its page calls. The build script runs as its author wrote it with tools/native_catalog/wasmcc (and the
emcc stand-in) first on PATH, which record each wasm compile; the compile of the simulator's entry is replayed with
a native compiler (the wasm-only flags dropped), and the adapter of its API family (adapters/<family>.c) maps that
API to the fm1c_* calls of native/engine/live.c.

A family: the file that has the API (markers: names it defines), the script that builds it (one that names
`mention`, default the file), the unit compiled (`compiled`, relative to the file; default the file), the adapter, defines for the firmware's units (`fw_defs`: its own native build's, as
zp12's SIM_NATIVE) and `bridge`: an adapter that turns the API into the X0X web_* calls, adapters/web.c then making the cartridge
(`web_defs`: its build knobs), `unity`: the adapter #includes the entry (FW_ENTRY) instead of linking it (an API whose
state is static in the entry)."""
import json
import os
import re
import shutil
import sys
from pathlib import Path

from common import CAT, HERE, PINS, ROOT, SHIM_INC, SKIP, SRC, link, sh, target_cc
from recipes import web

ORDER = 30
WASMCC = HERE / "wasmcc"
ADAPTERS = HERE / "adapters"

FAMILIES = [
    # zp12's sim/sim.c (OberVave's web/sim pattern): the sim_* panel API, the main loop a coroutine natively
    {"family": "sim", "file": "sim.c", "markers": ["sim_render", "sim_screen", "sim_init", "sim_out_l"],
     "fw_defs": ["-DSIM_NATIVE=1"]},
    # KAWA's and K-WASUB's web/wasm_host.c (platform.c takes it under KAWA_WASM): PFX_step / PFX_audio (kawa_, ksub_)
    {"family": "ksub", "file": "wasm_host.c", "markers": [r"\w+_audio", r"\w+_step", r"\w+_screen"],
     "mention": "KAWA_WASM", "compiled": "*", "probe": "ksub_probe"},
    # LUXR's emu/lx_emu_web.c: emu_* calls of the X0X web_* shape; adapters/luxr_web.c bridges them to adapters/web.c
    {"family": "luxr", "file": "lx_emu_web.c", "markers": ["emu_render", "emu_screen", "emu_buttons", "emu_init"],
     "bridge": "luxr_web", "web_defs": {"WEB_MASTER_MAX": "1023u"}},
    # Ravel's web/emu/ravel_web.c on host/host_core.c: rv_*; adapters/ravel_web.c bridges them to adapters/web.c
    {"family": "ravel", "file": "ravel_web.c", "markers": ["rv_boot", "rv_run", "rv_fb", "rv_set_buttons"],
     "bridge": "ravel_web", "web_defs": {"WEB_MASTER_MAX": "4096u", "WEB_FB_SWAP": "0"}},
    # the SLOOP line's firmware/wasm/*_wasm.c (No Man Sky FM, winampFM): emu_init / emu_frame / emu_render, the
    # firmware's one unit after a browser HAL; its pointer exports are wasm32 addresses, so the adapter includes it
    {"family": "sloop_emu", "file": "*_wasm.c", "markers": ["emu_init", "emu_start", "emu_frame", "emu_render",
                                                            "emu_fb_ptr", "emu_input"],
     "unity": True},
    # MONO2K's web/m2k_web.c (Emscripten): the firmware's core with the page's w_* calls
    {"family": "m2k", "file": "m2k_web.c", "markers": ["w_render", "w_frame", "w_init", "w_audio"]},
    # XMOD's host/websim.c (WASI SDK clang): the FM-1's pages, the player and the song slots
    # (tools/build_web.py's build_sim_page alone: its song manager page needs the Felucca submodule, not here)
    {"family": "xmod", "file": "websim.c", "markers": ["sim_frame", "sim_audio", "sim_input", "sim_fb"],
     "call": "build_sim_page"},
    # Veffbox's host/emu.c (Emscripten, `make emu` on an MNM-1 tree): the app with MNM-1's gfx.c, unity for its state
    {"family": "veffbox", "file": "emu.c", "markers": ["emu_frame", "emu_audio", "emu_button", "emu_encoder"],
     "unity": True, "prepare": "veffbox_mnm", "make_args": ["emu"]},
    # PT/FM's emulator/plat_web.c with fw/core, natively as its fw/tests/web_native.c (WEB_NATIVE: the system's C
    # library, not the wasm build's emulator/libc.c and emulator/include)
    {"family": "ptfm", "file": "plat_web.c", "markers": ["web_init", "web_knob", "web_note", "web_fb_dirty"],
     "fw_defs": ["-DWEB_NATIVE=1"], "drop": [r"emulator/libc\.c$", r"^-I.*emulator/include$"]},
]


def ksub_probe(d, entry):
    """the export prefix (wasm_host.c's PFX_audio), and whether the app exports its store and settings"""
    t = (d / entry).read_text(errors="replace")
    m = re.search(r'WASM_EXPORT\("(\w+)_audio"\)', t)
    if not m:
        return None
    pfx = m.group(1)
    src = "".join(p.read_text(errors="replace") for p in (d / entry).parents[1].rglob("*.c"))
    return [f"-DPFX={pfx}", f"-DKS_STORE={int(f'WASM_EXPORT(\"{pfx}_store\")' in src)}",
            f"-DKS_SETTINGS={int(f'WASM_EXPORT(\"{pfx}_settings\")' in src)}"]


def veffbox_mnm(fid, log):
    """Veffbox builds on an MNM-1 tree (its Makefile's MNM, tools/fm1_build.sh's argument): the catalogue's mnm1, at
    the version its README names (1.0.1), copied (its generated headers made there, its own tree left as it is)"""
    if PINS.get("mnm1", {}).get("version") != "1.0.1" or not (SRC / "mnm1").is_dir():
        log.append("veffbox: needs the catalogue's mnm1 at 1.0.1, fetched (tools/native_catalog/fetch.sh mnm1)")
        return None
    dep = CAT / "deps" / "mnm1"
    shutil.rmtree(dep, ignore_errors=True)
    shutil.copytree(SRC / "mnm1", dep, ignore=shutil.ignore_patterns("build", "dist", ".git"))
    if sh([sys.executable, "tools/build.py", "--gen-only"], dep, log=log):
        return None
    return [f"MNM={dep}"]


def scripts_for(d, name):
    """the scripts that compile `name` for the browser (sh, py, Makefile): the shell scripts first, the tests' last"""
    out = []
    for p in d.rglob("*"):
        rel = p.relative_to(d)
        if not p.is_file() or set(rel.parts) & SKIP:
            continue
        if p.suffix in (".sh", ".py", ".mk") or p.name in ("Makefile", "makefile"):
            t = p.read_text(errors="replace")
            if name in t and re.search(r"wasm32|\bemcc\b", t):
                out.append(rel)
    out.sort(key=lambda r: ("test" in str(r), r.suffix != ".sh", len(r.parts), str(r)))
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
            defs = globals()[fam["probe"]](d, rel) if fam.get("probe") else []
            if scripts and defs is not None:
                return {"recipe": "wasm", "family": fam["family"], "entry": str(rel), "scripts": scripts,
                        "adapter_defs": defs}
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
    make_args = list(fam.get("make_args", []))
    if fam.get("prepare"):
        extra = globals()[fam["prepare"]](fid, log)
        if extra is None:
            return []
        make_args += extra
    entry = Path(r["entry"]).name
    for s in r["scripts"]:
        if fam.get("call") and s.endswith(".py"):     # (one function of the script: its other parts need more)
            mod = Path(s)
            cmd = [sys.executable, "-c", f"import sys; sys.path.insert(0, {str(mod.parent)!r}); "
                                         f"import {mod.stem}; {mod.stem}.{fam['call']}()"]
        elif s.endswith(".sh"):
            cmd = ["sh", s]
        elif s.endswith(".py"):
            cmd = [sys.executable, s, *fam.get("script_args", [])]
        else:
            cmd = ["make", "-f", s, *make_args]
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
    # (compiled "*": the build's first link, whatever its units)
    want = None if fam.get("compiled") == "*" else (entry.parent / fam["compiled"]).resolve() if fam.get("compiled") \
        else entry
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
        args = [a for a in clean_flags(c["args"]) if not any(re.search(x, a) for x in fam.get("drop", []))]
        flags, srcs, objs, out, comp = web.split_cmd({"args": args})
        flags = [f for f in flags if not re.match(r"^-O[0-3sz]$", f)]
        if not comp and want and want not in [(cwd / s).resolve() for s in srcs] and \
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
        aflags = ["-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *fam.get("adapter_defs", []),
                  *r.get("adapter_defs", [])]
        cwd = ROOT
        if fam.get("unity"):
            cwd, flags = final["entry_flags"]
            aflags = [*final["base"], *flags, *fam.get("adapter_defs", []),
                      f'-DFW_ENTRY="{((SRC / fid / r["entry"]).parent / fam.get("compiled", Path(r["entry"]).name)).resolve()}"']
        work = CAT / "obj" / target / fid
        name = fam.get("bridge") or fam["family"]
        adapter = work / f"adapter_{name}.o"
        if sh([*cc, *aflags, "-c", str(ADAPTERS / f"{name}.c"), "-o", str(adapter)], cwd, log=log):
            stage = "adapter"
            continue
        objs = [str(adapter), *final["objs"]]
        if fam.get("bridge"):                       # (the bridge's web_* calls: adapters/web.c makes the cartridge)
            defs = [f"-DWEB_HAS_{s}=1" for s in sorted(web.defined_symbols(objs, target)) if s.startswith("web_")]
            defs += [f"-D{k}={v}" for k, v in fam.get("web_defs", {}).items()]
            webo = work / "adapter_web.o"
            if sh([*cc, "-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *defs, "-c",
                   str(ADAPTERS / "web.c"), "-o", str(webo)], ROOT, log=log):
                stage = "adapter"
                continue
            objs.insert(0, str(webo))
        out = link(fid, target, objs, False, log)
        if out:
            return out, None
        stage = "link"
    return None, stage

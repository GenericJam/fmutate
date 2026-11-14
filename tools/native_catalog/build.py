#!/usr/bin/env python3
"""Build one Hub firmware as a native cartridge (libcart_<id>.so, the fm1c_* calls of native/engine/live.c).

    python3 tools/native_catalog/build.py <id> [--target host|android-arm64-v8a|android-x86_64|android-armeabi-v7a]

Non-interactive and one firmware per call, so a CI job per firmware runs it as it is. Needs the source fetched
(tools/native_catalog/fetch.sh <id>). Writes native/build/catalog/out/<target>/libcart_<id>.so and the outcome
to native/build/catalog/results/<id>.<target>.json: {"ok", "stage", "recipe", "shims", "log"}.

Recipes (how the firmware's own host build is found; nothing of the firmware is changed):
  dinghy  zvenson's Dinghy platform: firmware/src/platform.c includes the fake FM-1 tests/host.c under DINGHY_HOST
          (OBV_HOST in OberVave's line). Compiled with tools/native_catalog/adapters/dinghy.c, which drives the
          app's loop as native/engine/live.c does (the fake FM-1's own script runner and main() renamed away).
  web     the X0X lineage's browser build (web/emu/*_web.c, fm1-base's emu_web.c): the firmware's own browser build
          script runs with tools/native_catalog/emcc on PATH (it records each emcc call and generates the
          firmware's tables and fonts as for the browser), the calls are replayed with a native compiler, and
          adapters/web.c maps the web_* exports to fm1c_*.
Generic shims, tried when a plain build fails: shims/include (emscripten.h; ELF-only section attributes on
Mach-O). A firmware needing more than that is a per-firmware patch (tools/native_catalog/patches/<id>/*.patch).
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CAT = ROOT / "native/build/catalog"
SRC = CAT / "src"
PINS = json.loads((HERE / "pins.json").read_text())
EMCC_DIR = HERE / "emcc"
SHIM_INC = HERE / "shims/include"
NDK_API = 28


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
        return [str(ndk_bin() / f"{triple}{NDK_API}-clang")], [], ["-Wl,-z,max-page-size=16384"]
    raise SystemExit(f"unknown target {target}")


def sh(cmd, cwd, env=None, log=None, timeout=900):
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
                       shell=isinstance(cmd, str))
    if log is not None:
        log.append(f"$ {cmd if isinstance(cmd, str) else shlex.join(cmd)}  (in {cwd})\n{r.stdout[-4000:]}{r.stderr[-6000:]}")
    return r.returncode


# ---------------------------------------------------------------------------------------------- recipe ---

def find_dinghy(d):
    p = d / "firmware/src/platform.c"
    if not p.exists():
        return None
    t = p.read_text(errors="replace")
    m = re.search(r"#ifdef\s+(\w+_HOST)\s*\n\s*#include\s+\"\.\./\.\./tests/host\.c\"", t)
    if not m or not (d / "tests/host.c").exists():
        return None
    apps = [f for f in (d / "firmware/src").glob("*.c") if '#include "platform.c"' in f.read_text(errors="replace")]
    if not apps:
        return None
    return {"recipe": "dinghy", "macro": m.group(1), "app": str(apps[0].relative_to(d))}


SKIP = {"node_modules", ".git", "build", "experiments", "vendor"}


def web_entries(d):
    out = []
    for p in d.rglob("*_web.c"):
        rel = p.relative_to(d)
        if set(rel.parts) & SKIP or "editor_web" in p.name:
            continue
        t = p.read_text(errors="replace")
        if "web_render" in t and "web_boot" in t:
            out.append(rel)
    # the firmware's own emulator first: shortest path under web/, fm1-base's last
    out.sort(key=lambda r: ("emu_web.c" == r.name and "base" in str(r), len(r.parts), str(r)))
    return out


def fm1base_app(d, entry):
    base = d / entry.parents[2]                         # <base>/web/emu/emu_web.c
    if not (base / "tools/build.py").exists() or not (base / "host/plat_host.c").exists():
        return None
    tomls = [p for p in d.rglob("fm1.toml") if not set(p.relative_to(d).parts) & SKIP
             and base not in p.parents]
    if not tomls:
        return None
    tomls.sort(key=lambda p: len(p.relative_to(d).parts))
    return {"recipe": "web", "kind": "fm1-base", "entry": str(entry), "base": str(base.relative_to(d)),
            "app": str(tomls[0].parent.relative_to(d))}


def web_script(d, entry):
    name = entry.name
    cands = []
    for p in d.rglob("*"):
        if not p.is_file() or set(p.relative_to(d).parts) & SKIP:
            continue
        if p.suffix in (".sh", ".py", ".mk") or p.name in ("Makefile", "makefile", "build.sh"):
            try:
                t = p.read_text(errors="replace")
            except OSError:
                continue
            if name in t and "emcc" in t:
                cands.append(p.relative_to(d))
    cands.sort(key=lambda r: (0 if r.suffix == ".sh" else 1, len(r.parts)))
    return [str(c) for c in cands]


def recipe(fid):
    d = SRC / fid
    r = find_dinghy(d)
    if r:
        return r
    for e in web_entries(d):
        if e.name == "emu_web.c":
            r = fm1base_app(d, e)
            if r:
                return r
        scripts = web_script(d, e)
        if scripts:
            return {"recipe": "web", "kind": "script", "entry": str(e), "scripts": scripts}
    return {"recipe": None}


# ------------------------------------------------------------------------------------------------ record ---

def gen_env(rec_log):
    env = dict(os.environ)
    env["PATH"] = f"{EMCC_DIR}:{env['PATH']}"
    env["FM1_EMCC_LOG"] = str(rec_log)
    if sys.platform == "darwin" and Path("/opt/homebrew/lib/libfribidi.dylib").exists():
        env["DYLD_LIBRARY_PATH"] = "/opt/homebrew/lib"    # (Pillow's libraqm finds FriBiDi there)
    env.setdefault("PYTHON", sys.executable)
    return env


def generate_tables(d, env, log):
    """a Felucca-line tools/build.py's generate(): the tables, fonts and samples a browser build expects in build/gen"""
    for b in ("tools/build.py",):
        p = d / b
        if p.exists() and "def generate(" in p.read_text(errors="replace"):
            code = ("import sys; sys.argv=['build.py']; sys.path.insert(0, 'tools'); import build; build.generate()")
            sh([sys.executable, "-c", code], d, env, log)


def record(fid, r, log):
    d = SRC / fid
    rec = CAT / "rec" / f"{fid}.jsonl"
    rec.parent.mkdir(parents=True, exist_ok=True)
    if rec.exists():
        rec.unlink()
    env = gen_env(rec)
    if r["kind"] == "fm1-base":
        sh([sys.executable, str(d / r["base"] / "tools/build.py"), r["app"], "--web"], d, env, log)
    else:
        generate_tables(d, env, log)
        for s in r["scripts"]:
            cmd = ["sh", s] if s.endswith(".sh") else [sys.executable, s] if s.endswith(".py") else ["make", "-f", s]
            sh(cmd, d, env, log)
            if rec.exists() and r["entry"].split("/")[-1] in rec.read_text():
                break
    cmds = [json.loads(l) for l in rec.read_text().splitlines()] if rec.exists() else []
    return cmds


# ------------------------------------------------------------------------------------------------ replay ---

DROP_WITH_ARG = {"--js-library", "--pre-js", "--post-js", "--shell-file", "--embed-file", "--preload-file",
                 "--closure", "-s", "--extern-pre-js", "--extern-post-js", "--use-preload-plugins"}
DROP_PREFIX = ("-s", "--no-entry", "-msimd128", "-mbulk-memory", "-mnontrapping-fptoint", "-msign-ext",
               "-gsource-map", "-lembind", "--emrun", "-sEXPORT", "-mexec-model", "-flto", "--minify", "-mtail-call",
               "-fwasm-exceptions", "-Wl,--export", "-Wl,--no-entry", "-Wl,--allow-undefined", "-Wl,--initial-memory",
               "-Wl,-z,stack-size", "-Wl,--stack-first", "--profiling")
SRC_EXT = (".c", ".cc", ".cpp", ".cxx", ".S", ".s")


def split_cmd(c):
    """(flags, sources, objects, output, compile_only)"""
    args = c["args"]
    flags, srcs, objs, out, comp = [], [], [], None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a in DROP_WITH_ARG:
            i += 2
            continue
        if a == "-o":
            out = args[i + 1]
            i += 2
            continue
        if a == "-c":
            comp = True
        elif a.startswith(DROP_PREFIX) and not a.startswith("-std"):
            pass
        elif not a.startswith("-") and a.endswith(SRC_EXT):
            srcs.append(a)
        elif not a.startswith("-") and a.endswith((".o", ".a", ".bc")):
            objs.append(a)
        elif a in ("-I", "-D", "-include", "-isystem", "-iquote", "-x", "-U"):
            flags += [a, args[i + 1]]
            i += 2
            continue
        else:
            flags.append(a)
        i += 1
    return flags, srcs, objs, out, comp


def replay(fid, r, cmds, target, shims, log):
    d = SRC / fid
    cc, cflags_t, lflags_t = target_cc(target)
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    produced = {}                                       # recorded output (absolute) -> our object/archive
    entry = (d / r["entry"]).resolve()
    final = None
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-O2", "-ffp-contract=off", "-fno-strict-aliasing", *cflags_t, *shimflags]
    n = 0
    for c in cmds:
        cwd = Path(c["cwd"])
        if c["tool"] == "emar":
            args = c["args"]
            if len(args) >= 2:
                members = [produced.get(str((cwd / a).resolve())) for a in args[2:]]
                produced[str((cwd / args[1]).resolve())] = [m for m in members if m]
            continue
        if c["tool"] not in ("emcc", "em++"):
            continue
        flags, srcs, objs, out, comp = split_cmd(c)
        cpp = c["tool"] == "em++"
        flags = [f for f in flags if not re.match(r"^-O[0-3sz]$", f)]
        mine = []
        for s in srcs:
            n += 1
            o = work / f"{n:03d}_{Path(s).stem}.o"
            cmd = [*cc, *(["-x", "c++"] if cpp and s.endswith(".c") else []), *base, *flags, "-c", s, "-o", str(o)]
            if sh(cmd, cwd, log=log):
                return None, "compile"
            mine.append(str(o))
        if comp:
            if out and mine:
                produced[str((cwd / out).resolve())] = mine[0]
            elif mine:
                produced[str((cwd / (Path(srcs[0]).stem + ".o")).resolve())] = mine[0]
            if mine and any((cwd / s).resolve() == entry for s in srcs):
                produced[mine[0] + "#entry"] = mine[0]
            continue
        linked = list(mine)
        for o in objs:
            p = produced.get(str((cwd / o).resolve()))
            if p is None:
                continue
            linked += p if isinstance(p, list) else [p]
        entry_objs = {produced.get(k) for k in produced if k.endswith("#entry")}
        if final is None and (any((cwd / s).resolve() == entry for s in srcs) or set(linked) & entry_objs):
            final = {"objs": linked, "flags": flags, "cpp": cpp}   # (the browser build's own link: its entry)
            break
    if not final:
        return None, "record"
    return final, None

def defined_symbols(objs, target):
    nm = str(ndk_bin() / "llvm-nm") if target.startswith("android") else "nm"
    r = subprocess.run([nm, "-g", "--defined-only", *objs], capture_output=True, text=True)
    return {line.split()[-1].lstrip("_") for line in r.stdout.splitlines() if len(line.split()) >= 3}


def link_web(fid, r, final, target, shims, log):
    d = SRC / fid
    cc, cflags_t, lflags_t = target_cc(target)
    work = CAT / "obj" / target / fid
    t = (d / r["entry"]).read_text(errors="replace")
    m = re.search(r"web_master\s*\(\s*uint32_t\s+\w+\s*\)[^}]*?(\d{3,5})u?", t)
    defs = []
    if m:
        defs.append(f"-DWEB_MASTER_MAX={m.group(1)}u")
    elif "plat_host.c" in t:
        defs.append("-DWEB_MASTER_MAX=4096u")
    defs += [f"-DWEB_HAS_{s}=1" for s in sorted(defined_symbols(final["objs"], target)) if s.startswith("web_")]
    adapter = work / "adapter_web.o"
    if sh([*cc, "-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *defs, "-c",
           str(HERE / "adapters/web.c"), "-o", str(adapter)], ROOT, log=log):
        return None
    return link(fid, target, [str(adapter), *final["objs"]], final["cpp"], log)


def link(fid, target, objs, cpp, log):
    cc, cflags_t, lflags_t = target_cc(target)
    out = CAT / "out" / target / f"libcart_{fid}.so"
    out.parent.mkdir(parents=True, exist_ok=True)
    libs = ["-lm"] + (["-lpthread"] if not target.startswith("android") else []) + (["-lc++" if sys.platform == "darwin" and target == "host" else "-lstdc++"] if cpp else [])
    undef = [] if sys.platform == "darwin" and target == "host" else ["-Wl,--no-undefined"]
    if sh([*cc, "-shared", "-fPIC", *lflags_t, "-o", str(out), *objs, *libs, *undef], ROOT, log=log):
        return None
    return out


# ---------------------------------------------------------------------------------------------- dinghy ---

def build_dinghy(fid, r, target, shims, log):
    """the app with its fake FM-1 (tests/host.c), the fake's own script runner and main() renamed away, and
    adapters/dinghy.c driving its loop"""
    d = SRC / fid
    cc, cflags_t, lflags_t = target_cc(target)
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    tree = work / "tree"
    shutil.copytree(d / "firmware", tree / "firmware", symlinks=True)
    host = (d / "tests/host.c").read_text(errors="replace")
    obv = r["macro"] == "OBV_HOST"                      # (OberVave's line: OBV_WASM leaves poll and main to us)
    host, n_poll = re.subn(r"^static void platform_poll\(void\)", "static __attribute__((unused)) void host_script_poll(void)", host, flags=re.M)
    host, n_main = re.subn(r"^int main\(int argc, char \*\*argv\)", "static __attribute__((unused)) int host_script_main(int argc, char **argv)", host, flags=re.M)
    (tree / "tests").mkdir(parents=True)
    (tree / "tests/host.c").write_text(host)
    if not n_poll and not obv:
        log.append("dinghy: tests/host.c has no platform_poll to replace")
        return None, "adapter"
    for extra in ("gen", "build/gen"):
        if (d / extra).is_dir():
            shutil.copytree(d / extra, tree / extra, symlinks=True)
    defs = [f"-D{r['macro']}=1"] + (["-DOBV_WASM=1"] if obv else [])
    for arr in ("host_set", "host_store", "host_blob", "host_slot"):
        if re.search(r"static\s+uint8_t\s[^;]*\b%s\s*\[" % arr, host):
            defs.append(f"-DDH_STORE_{arr}=1")
    if re.search(r"\bmq\s*\[\s*64\s*\]\s*\[\s*4\s*\]", host):
        defs.append("-DDH_MQ4=1")
    version = PINS[fid]["version"]
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    o = work / "cart.o"
    cmd = [*cc, "-fPIC", "-O2", "-w", "-ffp-contract=off", *cflags_t, *shimflags, *defs,
           f'-DAPP_VER="{version}"', f'-DFW_MAIN="{tree / r["app"]}"',
           "-I", str(tree / "firmware/src"), "-I", str(tree / "firmware/hal"), "-I", str(tree / "firmware/gen"),
           "-I", str(tree / "build/gen"), "-c", str(HERE / "adapters/dinghy.c"), "-o", str(o)]
    if sh(cmd, ROOT, log=log):
        return None, "compile"
    out = link(fid, target, [str(o)], False, log)
    return (out, None) if out else (None, "link")


# ------------------------------------------------------------------------------------------------- main ---

def build(fid, target):
    log = []
    res = {"id": fid, "target": target, "ok": False, "stage": None, "recipe": None, "shims": False}
    d = SRC / fid
    if not d.is_dir():
        res["stage"] = "fetch"
        return res, log
    r = recipe(fid)
    res["recipe"] = r
    if not r["recipe"]:
        res["stage"] = "recipe"
        return res, log
    patches = sorted((HERE / "patches" / fid).glob("*.patch")) if (HERE / "patches" / fid).is_dir() else []
    for p in patches:
        if sh(["patch", "-p1", "-N", "-s", "-i", str(p)], d, log=log):
            res["stage"] = "patch"
            return res, log
    res["patches"] = [p.name for p in patches]
    if r["recipe"] == "dinghy":
        for shims in (False, True):
            out, stage = build_dinghy(fid, r, target, shims, log)
            res.update(shims=shims, stage=stage)
            if out:
                break
    else:
        cmds = record(fid, r, log)
        res["emcc_calls"] = len(cmds)
        out = None
        for shims in (False, True):
            final, stage = replay(fid, r, cmds, target, shims, log)
            res.update(shims=shims, stage=stage)
            if final:
                out = link_web(fid, r, final, target, shims, log)
                if out:
                    break
                res["stage"] = "link"
            if stage == "record":
                break
    if out:
        res.update(ok=True, stage="built", file=str(out), size=out.stat().st_size)
    return res, log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("id")
    ap.add_argument("--target", default="host")
    a = ap.parse_args()
    res, log = build(a.id, a.target)
    rdir = CAT / "results"
    rdir.mkdir(parents=True, exist_ok=True)
    (rdir / f"{a.id}.{a.target}.log").write_text("\n".join(log))
    (rdir / f"{a.id}.{a.target}.json").write_text(json.dumps(res, indent=1) + "\n")
    print(f"{a.id} {a.target}: {'ok' if res['ok'] else 'FAILED at ' + str(res['stage'])}"
          f"{' (shims)' if res.get('shims') and res['ok'] else ''}")
    sys.exit(0 if res["ok"] else 1)


if __name__ == "__main__":
    main()

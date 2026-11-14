"""Recipe "web": the X0X lineage's browser build (web/emu/*_web.c, fm1-base's emu_web.c, ChoralRoot's
tools/emu/web/emu_web.c ...). The firmware's own browser build runs with tools/native_catalog/emcc on PATH (it records
each emcc call and generates the firmware's tables and fonts as for the browser), the calls are replayed with a
native compiler, and adapters/web.c maps the web_* exports to the fm1c_* calls."""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from common import CAT, EMCC_DIR, HERE, ROOT, SHIM_INC, SKIP, SRC, link, ndk_bin, sh, target_cc

ORDER = 20



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
    # the app: an fm1.toml outside the base, else one the base keeps among its own apps (DUB-BOX's src/apps/...,
    # Kris Jangle's kris-jangle/ in a repository that is the base); never its tests', template's and examples'. A
    # base kept in a subdirectory with no app of the repository's own (Playa's fm1base/) is not this firmware.
    tomls = []
    for p in d.rglob("fm1.toml"):
        parts = set(p.relative_to(d).parts)
        if parts & (SKIP | {"tests", "template", "examples"}):
            continue
        if base != d and base in p.parents and "apps" not in p.relative_to(base).parts:
            continue
        tomls.append(p)
    if not tomls:
        return None
    tomls.sort(key=lambda p: (base in p.parents, len(p.relative_to(d).parts)))
    return {"recipe": "web", "kind": "fm1-base", "entry": str(entry), "base": str(base.relative_to(d)),
            "app": str(tomls[0].parent.relative_to(d))}


def web_script(d, entry, fid=""):
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
    # a variant named for this firmware (fm1-amy's web/emu/build_amy.sh beside X0X's build.sh): that one alone,
    # the other builds the firmware it was forked from
    own = [c for c in cands if re.fullmatch(r"build_(\w{3,})", c.stem) and c.stem[6:] in fid.replace("-", "_")]
    return [str(c) for c in own or cands]



# ------------------------------------------------------------------------------------------------ record ---

def tree_roots(d, entry):
    """where the browser build's tree starts: the repository, and the entry's <root>/web/emu/x_web.c when that is
    deeper (a firmware kept in firmware/, ext/Felucca/, upstream/felucca/ ...)"""
    roots = [d]
    if len(entry.parts) > 3 and entry.parts[-3] == "web":
        roots.insert(0, d / entry.parents[2])
    return roots


def generate_tables(roots, env, log):
    """a Felucca-line tools/build.py's generate(): the tables, fonts and samples a browser build expects in build/gen"""
    for d in roots:
        p = d / "tools/build.py"
        if p.exists() and "def generate(" in p.read_text(errors="replace"):
            code = ("import sys; sys.argv=['build.py']; sys.path.insert(0, 'tools'); import build; build.generate()")
            sh([sys.executable, "-c", code], d, env, log)
            return


def gen_env(rec_log):
    env = dict(os.environ)
    path = f"{EMCC_DIR}:{env['PATH']}"
    if sys.platform == "darwin" and Path("/opt/homebrew/lib/libfribidi.dylib").exists():
        # Pillow's libraqm needs FriBiDi, which Homebrew keeps where dyld doesn't look; macOS drops DYLD_* when a
        # script runs python through /bin/sh, so python3 on PATH is a wrapper that sets it again
        # (written to a file of this process's own and renamed into place: builds run in parallel)
        wrap = CAT / "bin/python3"
        wrap.parent.mkdir(parents=True, exist_ok=True)
        tmp = wrap.with_name(f".python3.{os.getpid()}")
        tmp.write_text(f"#!{sys.executable}\nimport os, sys\nos.environ['DYLD_LIBRARY_PATH'] = '/opt/homebrew/lib'\n"
                       f"os.execv({sys.executable!r}, [{sys.executable!r}] + sys.argv[1:])\n")
        tmp.chmod(0o755)
        os.replace(tmp, wrap)
        link = wrap.with_name(f".python.{os.getpid()}")
        link.unlink(missing_ok=True)
        link.symlink_to("python3")
        os.replace(link, wrap.parent / "python")
        path = f"{wrap.parent}:{path}"
        env["DYLD_LIBRARY_PATH"] = "/opt/homebrew/lib"
    env["PATH"] = path
    env["FM1_EMCC_LOG"] = str(rec_log)
    env.setdefault("PYTHON", str(CAT / "bin/python3") if sys.platform == "darwin" else sys.executable)
    return env


def record(fid, r, log):
    d = SRC / fid
    rec = CAT / "rec" / f"{fid}.jsonl"
    rec.parent.mkdir(parents=True, exist_ok=True)
    if rec.exists():
        rec.unlink()
    env = gen_env(rec)
    env["HOSTCC_FORCE"] = "1"                           # (ChoralRoot's line keeps outputs its stamp says are current)
    if r.get("define"):
        env[r["define"]] = "1"                          # (the switch as tools/build.py takes it: its generators too)
    roots = tree_roots(d, Path(r["entry"]))
    # a clean tree: browser builds keep objects and libraries they built before, which the record has to see made
    for b in [*(x / "build" for x in roots), d / r.get("app", "-") / "build"]:
        if b.is_dir():
            shutil.rmtree(b)
    if r["kind"] == "fm1-base":
        sh([sys.executable, str(d / r["base"] / "tools/build.py"), r["app"], "--web"], d, env, log)
    else:
        generate_tables(roots, env, log)
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
    any_cpp = False
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    base = ["-fPIC", "-w", "-O2", "-ffp-contract=off", "-fno-strict-aliasing", *cflags_t, *shimflags,
            *([f"-D{r['define']}=1"] if r.get("define") else [])]
    n = 0
    for c in cmds:
        cwd = Path(c["cwd"])
        if c["tool"] == "emar":
            args = c["args"]
            if len(args) >= 2:
                members = [produced.get(str((cwd / a).resolve())) for a in args[2:]]
                produced[str((cwd / args[1]).resolve())] = [m for m in members if m]
            continue
        if c["tool"] not in ("emcc", "em++") or set(c["args"]) & {"-M", "-MM", "-E"}:
            continue                                    # (not a compile: a dependency scan, the preprocessor alone)
        flags, srcs, objs, out, comp = split_cmd(c)
        cpp = c["tool"] == "em++"
        any_cpp = any_cpp or cpp or any(s.endswith((".cc", ".cpp", ".cxx")) for s in srcs)
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
            final = {"objs": linked, "flags": flags, "cpp": any_cpp}   # (the browser build's own link: its entry)
            break
    if not final:
        return None, "record"
    return final, None

def defined_symbols(objs, target):
    nm = str(ndk_bin() / "llvm-nm") if target.startswith("android") else "nm"
    r = subprocess.run([nm, "-g", "--defined-only", *objs], capture_output=True, text=True)
    return {line.split()[-1].lstrip("_") for line in r.stdout.splitlines() if len(line.split()) >= 3}


# ---- the dialect: what the entry's exports take and the page's panel tables (index.html / worklet.js), as -D

WIRE_BTN = ("OCT-", "OCT+", "FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC")
WIRE_ENC = ("SELECT", "ALGO", "K1", "K2", "K3", "K4", "PRESET")
BTN_ALIAS = {"SCL": "SEL", "SCALE": "SEL", "OCTDN": "OCT-", "OCTUP": "OCT+", "OCT_DN": "OCT-", "OCT_UP": "OCT+"}
ENC_ALIAS = {"ALGORITHM": "ALGO", "PRESETS": "PRESET", "KNOB1": "K1", "KNOB2": "K2", "KNOB3": "K3", "KNOB4": "K4"}
JS_PAIR = re.compile(r"""["']?([A-Z][A-Z0-9+\-_]*)["']?\s*:\s*(\d+)""")


def page_tables(d, entry):
    """the page's label -> bit table for web_buttons and label -> index for web_enc (`{FX: 0, SEL: 1, ...}`), from
    the scripts beside the entry; None where there is none (the X0X lineage's orders are the adapter's default)"""
    btn = enc = None
    for p in sorted((d / entry).parent.glob("*")):
        if p.suffix not in (".html", ".js", ".mjs"):
            continue
        for m in re.finditer(r"\{[^{}]{10,600}\}", p.read_text(errors="replace")):
            kv = {k: int(v) for k, v in JS_PAIR.findall(m.group(0))}
            b = {BTN_ALIAS.get(k, k): v for k, v in kv.items()}
            e = {ENC_ALIAS.get(k, k): v for k, v in kv.items()}
            if btn is None and all(w in b for w in WIRE_BTN) and sorted(b[w] for w in WIRE_BTN) == list(range(14)):
                btn = [b[w] for w in WIRE_BTN]
            if enc is None and all(w in e for w in WIRE_ENC) and sorted(e[w] for w in WIRE_ENC) == list(range(7)):
                enc = [e[w] for w in WIRE_ENC]
    return btn, enc


def n_params(t, name):
    """how many parameters the entry's definition of `name` takes (None: not defined there)"""
    m = re.search(r"\b%s\s*\(([^()]*)\)\s*(?:/\*.*?\*/\s*|//[^\n]*\s*)*\{" % name, t, re.S)
    if not m:
        return None
    a = m.group(1).strip()
    return 0 if a in ("", "void") else a.count(",") + 1


def dialect(d, entry):
    t = (d / entry).read_text(errors="replace")
    defs = []
    m = re.search(r"web_master\s*\(\s*uint32_t\s+\w+\s*\)[^}]*?(\d{3,5})u?", t)
    if m:
        defs.append(f"-DWEB_MASTER_MAX={m.group(1)}u")
    elif "plat_host.c" in t:
        defs.append("-DWEB_MASTER_MAX=4096u")
    if n_params(t, "web_boot"):
        defs.append("-DWEB_BOOT_MASTER=1")              # (Melodee's: the MASTER knob at power on)
    if n_params(t, "web_midi_in") == 3:
        defs.append("-DWEB_MIDI_IN_3=1")                # (status, data1, data2 rather than port, USB packet)
    if n_params(t, "web_key") in (2, 3):
        defs.append(f"-DWEB_KEY_ARGS={n_params(t, 'web_key')}")    # (a key at a time, where there is no web_keys)
    btn, enc = page_tables(d, entry)
    if btn:
        defs.append("-DWEB_BTN_MAP=" + ",".join(map(str, btn)))
    if enc:
        defs.append("-DWEB_ENC_MAP=" + ",".join(map(str, enc)))
    if "emu_fw_audio(" in t:
        # ChoralRoot's line hands the page the mix's Q15 as it is; the codec gets it shifted OUT_SHIFT into its
        # 24-bit word (audio.c: 7, -6 dBFS): the device's level is 2^(OUT_SHIFT - 8) of the page's
        for root in tree_roots(d, Path(entry)):
            a = root / "firmware/src/audio.c"
            m = re.search(r"#define\s+OUT_SHIFT\s+(\d+)", a.read_text(errors="replace")) if a.exists() else None
            if m:
                defs.append(f"-DWEB_GAIN={2.0 ** (int(m.group(1)) - 8)}f")
                break
    return defs


def link_web(fid, r, final, target, shims, log):
    d = SRC / fid
    cc, cflags_t, lflags_t = target_cc(target)
    work = CAT / "obj" / target / fid
    defs = dialect(d, r["entry"])
    defs += [f"-DWEB_HAS_{s}=1" for s in sorted(defined_symbols(final["objs"], target)) if s.startswith("web_")]
    adapter = work / "adapter_web.o"
    if sh([*cc, "-fPIC", "-O2", "-Wall", "-Wno-unused-function", *cflags_t, *defs, "-c",
           str(HERE / "adapters/web.c"), "-o", str(adapter)], ROOT, log=log):
        return None
    return link(fid, target, [str(adapter), *final["objs"]], final["cpp"], log)


VENDORED = {"upstream", "ext", "third_party", "external", "deps", "submodules"}


def variant_flag(d, entry, fid):
    """the build switch that makes this firmware of its base (Flyfish: Felucca with FELUCCA_FLYFISH=1 in the
    environment of tools/build.py, Satie-1: AMB with EN_SATIE1), or None"""
    name = re.sub(r"\W", "", fid).upper()
    for root in tree_roots(d, entry):
        b = root / "tools/build.py"
        t = b.read_text(errors="replace") if b.exists() else ""
        m = re.search(r"""os\.environ\.get\(["']((?:\w+_)?%s)["']\)\s*==\s*["']1""" % name, t)
        if m:
            return m.group(1)
    return None


def detect(d, fid):
    entries = web_entries(d)
    # a firmware made of its base by a build switch: the browser entry that sets it (Flyfish's web/emu/ff_web.c
    # beside Felucca's felucca_web.c), never one without it (the base's own)
    flags = {e: variant_flag(d, e, fid) for e in entries}
    sets = {e: bool(flags[e]) and flags[e] in (d / e).read_text(errors="replace") for e in entries}
    entries.sort(key=lambda e: not sets[e])
    for e in entries:
        if e.name == "emu_web.c":
            r = fm1base_app(d, e)
            if r:
                return r
            base = d / e.parents[2]
            if (base / "tools/build.py").exists() and (base / "host/plat_host.c").exists():
                continue                                # (fm1-base with no app of this firmware: its scripts build
                                                        #  the base's own tests and template)
        if {p.lower() for p in e.parts[:-1]} & VENDORED:
            continue                                    # (the browser build of a firmware it builds on, not its own)
        if flags[e] and not sets[e]:
            continue                                    # (the base's browser build, without this firmware)
        scripts = web_script(d, e, fid)
        if scripts:
            r = {"recipe": "web", "kind": "script", "entry": str(e), "scripts": scripts}
            t = (d / e).read_text(errors="replace") + "".join((d / s).read_text(errors="replace") for s in scripts)
            if flags[e] and not re.search(r"(#define\s+|-D)%s\b" % flags[e], t):
                r["define"] = flags[e]                  # (Satie-1's amb_web.c tests EN_SATIE1, nothing sets it:
                                                        #  as tools/build.py, -DEN_SATIE1=1)
            return r
    return None


def build(fid, r, target, log, res):
    cmds = record(fid, r, log)
    res["emcc_calls"] = len(cmds)
    stage = None
    for shims in (False, True):
        final, stage = replay(fid, r, cmds, target, shims, log)
        res["shims"] = shims
        if final:
            out = link_web(fid, r, final, target, shims, log)
            if out:
                return out, None
            stage = "link"
        if stage == "record":
            break
    return None, stage

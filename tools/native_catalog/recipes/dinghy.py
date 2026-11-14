"""Recipe "dinghy": zvenson's Dinghy platform and its forks. firmware/src/platform.c includes a fake FM-1 (a host.c:
tests/host.c, firmware/src/host.c in GR!MM's line; CS-1 splits it into tests/fake_fm1.h + tests/host.c) under a
<NAME>_HOST switch (DINGHY_HOST, OBV_HOST, CHIPBOX_HOST, ...). A copy of the firmware is compiled with
adapters/dinghy.c, which drives the app's loop as native/engine/live.c does: the fake's script runner (platform_poll)
is renamed away, its main() kept (the fork's own setup: an erased flash, ...) and run with no arguments.

The fakes differ across forks, so the names the adapter needs are read from the fake's own functions, not per fork:
the press/release edges from fm1_input_edges, the note edges from fm1_input_note_edges, the encoders' counts from
fm1_enc_take, the lit LEDs from fm1_led_key (and the dim layer from fm1_led_glow / fm1_led_key_glow); each becomes a
-DDH_<what>=<name> for the adapter. The app, the other units, -I and -D come from the fork's host build (the cc line
in tests/*.sh that builds the app the device build compiles)."""
import re
import shlex
import shutil

from common import CAT, HERE, PINS, ROOT, SHIM_INC, SKIP, SRC, link, sh, target_cc

ORDER = 10

# the fake FM-1's RAM storage (settings, slots, the flash it fakes): saved as one blob, in this order
STORE = ("host_set", "host_store", "host_blob", "host_slot", "host_slots", "host_longs", "host_lib", "host_psect",
         "host_ssec", "host_flash", "host_mem", "fake_store", "fake_bank", "fake_flash", "fake_save")

_INC = re.compile(r'^\s*#\s*include\s+"([^"]*host\.c)"', re.M)
_COND = re.compile(r'^\s*#\s*(?:ifdef|if|elif)\b[^\n]*?\b(\w+_HOST)\b')


def _host_include(platform):
    """(macro, path) of the fake FM-1 platform.c includes under a <NAME>_HOST switch"""
    lines = platform.read_text(errors="replace").splitlines()
    for i, l in enumerate(lines):
        m = _INC.match(l)
        if not m:
            continue
        for j in range(i - 1, max(-1, i - 6), -1):
            c = _COND.match(lines[j])
            if c:
                return c.group(1), m.group(1)
    return None


def _includes(path):
    return re.findall(r'^\s*#\s*include\s+"([^"]+\.c)"', path.read_text(errors="replace"), re.M)


def _apps(src):
    """the firmware/src units that reach platform.c through their includes and that no other unit includes"""
    cs = {p.name: p for p in src.glob("*.c")}
    inc = {n: [i for i in _includes(p) if "/" not in i] for n, p in cs.items()}
    included = {i for v in inc.values() for i in v}

    def reaches(n, seen):
        if n == "platform.c":
            return True
        if n in seen or n not in inc:
            return False
        seen.add(n)
        return any(reaches(i, seen) for i in inc[n])
    return sorted(n for n in cs if n != "platform.c" and n not in included and reaches(n, set())), included


def _expand(line, script):
    """the shell variables of a cc line: ${X:-default}, and X=... set in the script (the last plain value)"""
    vals = {}
    for m in re.finditer(r'^\s*(?:export\s+)?(\w+)=("?)(.*?)\2\s*(?:;|$|#)', script, re.M):
        v = m.group(3)
        d = re.fullmatch(r'\$\{\w+:-([^}]*)\}', v)
        vals[m.group(1)] = d.group(1) if d else v if "$" not in v else ""
    for _ in range(3):
        line = re.sub(r'\$\{(\w+):-([^{}]*)\}', lambda m: vals.get(m.group(1)) or m.group(2), line)
        line = re.sub(r'\$\{(\w+):\+[^{}]*\}', "", line)
        line = re.sub(r'\$\{?(\w+)\}?', lambda m: vals.get(m.group(1), ""), line)
    return line


def _cc_lines(d, macro):
    """the host builds in the fork's scripts: (script, the cc line with its variables expanded)"""
    out = []
    for s in sorted(d.glob("tests/*.sh")) + sorted(d.glob("*.sh")):
        t = s.read_text(errors="replace")
        for l in t.replace("\\\n", " ").splitlines():
            if re.search(r"-D%s\b" % macro, l) and re.search(r"firmware/src/\S*\.c\b|\$\w*\.c\b", l):
                out.append((s.name, _expand(l.split("||")[0].split("&&")[0].strip(), t)))
    out.sort(key=lambda x: x[0] != "run_host.sh")
    return out


def detect(top, fid):
    """the tree at the top, else the first subdirectory holding a Dinghy-platform firmware (agtdeck's
    firmware-build/, scintilla's firmware/, rhytmsec1's fm1-dock/)"""
    for d in [top] + sorted(p for p in top.iterdir() if p.is_dir() and p.name not in SKIP):
        if (d / "web/wasm_host.c").exists():           # (KAWA's line: its own fake, built by recipes/wasm.py)
            continue
        r = _detect(d, fid)
        if r:
            r["root"] = str(d.relative_to(top)) if d != top else ""
            # an app kept outside that tree, copied over its app by the fork's release (agtdeck: firmware/agentdeck.c)
            outside = sorted(p for p in top.rglob("*.c") if d not in p.parents and d != top
                             and not SKIP & set(p.relative_to(top).parts)
                             and re.search(r'^\s*#\s*include\s+"platform\.c"', p.read_text(errors="replace"), re.M))
            if outside:
                r["app_from"] = str(outside[0].relative_to(top))
            return r
    return None


def _detect(d, fid):
    p = d / "firmware/src/platform.c"
    if not p.exists():
        return None
    hi = _host_include(p)
    if not hi:
        return None
    macro, inc = hi
    host = (p.parent / inc).resolve()
    if not host.exists():
        return None
    apps, _ = _apps(d / "firmware/src")
    if not apps:
        return None
    devb = d / "tools/build.py"
    dev = devb.read_text(errors="replace") if devb.exists() else ""
    m = re.search(r'^APP\s*=\s*"(\w+)"', dev, re.M)
    dev += f' "{m.group(1)}_app.c"' if m and "{APP}_app.c" in dev else ""
    ccs = _cc_lines(d, macro)
    first = next((re.findall(r"firmware/src/([\w]+\.c)", l) for _, l in ccs), [])
    stem = fid.replace("-", "").lower()

    def rank(a):
        s = a[:-2].replace("_app", "").replace("-", "").lower()
        return (not re.search(r'["/]%s"?' % re.escape(a), dev), not (s and (s in stem or stem in s)),
                a not in first[:1], a)
    app = sorted(apps, key=rank)[0]
    return {"recipe": "dinghy", "macro": macro, "host": str(host.relative_to(d.resolve())),
            "app": f"firmware/src/{app}"}


# --------------------------------------------------------------------------------------- the fake's names ---

def _block(t, i):
    """the braces' block that opens at or after t[i]"""
    i, depth = t.index("{", i), 0
    for k in range(i, len(t)):
        depth += {"{": 1, "}": -1}.get(t[k], 0)
        if not depth:
            return t[i:k + 1]
    return None


def _body(t, name):
    """a function's signature and body"""
    m = re.search(r"^[^\n;{}]*\b%s\s*\([^)]*\)\s*(?://[^\n]*\n\s*|/\*.*?\*/\s*)*\{" % name, t, re.M | re.S)
    return t[m.start():m.end() - 1] + _block(t, m.end() - 1) if m else None


def _decl(t, name):
    """(type, is_array) of a file-scope static"""
    m = re.search(r"^static\s+(?:volatile\s+)?(\w+)\s+(?:[^;=(]*,\s*)?\b%s\s*(\[)?" % name, t, re.M)
    return (m.group(1), bool(m.group(2))) if m else (None, False)


def _target(body):
    """the file-scope variable a setter writes (its locals and parameters skipped)"""
    local = set(re.findall(r"\b(?:u?int\d+_t|int|unsigned)\s+(\w+)", body))
    for m in re.finditer(r"\b(\w+)\s*(?:\[[^\]]*\])?\s*(?:\|=|&=|\^=|=(?!=))", body):
        if m.group(1) not in local:
            return m.group(1)
    return None


def fake_names(t):
    """-D flags naming the fake FM-1's panel and LED state for adapters/dinghy.c"""
    defs = []
    b = _body(t, "fm1_input_edges") or ""
    m = re.search(r"uint32_t\s+\w+\s*=\s*(\w+)\s*;", b)
    press = m.group(1) if m else "host_edges" if _decl(t, "host_edges")[0] else None
    m = re.search(r"\*\s*released\s*=\s*([A-Za-z_]\w*)\s*;", b)
    rel = m.group(1) if m else "host_rel" if not b and _decl(t, "host_rel")[0] else None
    if press:
        defs.append(f"-DDH_PRESS={press}")
    if rel:
        defs.append(f"-DDH_REL={rel}")
    m = re.search(r"uint32_t\s+\w+\s*=\s*([A-Za-z_]\w*)\s*;", _body(t, "fm1_input_note_edges") or "")
    if m:
        defs.append(f"-DDH_NOTE_PRESS={m.group(1)}")
    m = re.search(r"\b(\w+)\s*\[\s*e\b", _body(t, "fm1_enc_take") or "")
    enc = m.group(1) if m else "host_enc" if _decl(t, "host_enc")[1] else None
    if enc:
        defs.append(f"-DDH_ENC={enc}")
    if _decl(t, "host_enc_pos")[1]:
        defs.append("-DDH_ENC_POS=host_enc_pos")
    lb = _body(t, "fm1_led_key") or ""
    led = _target(lb)
    ty, arr = _decl(t, led) if led else (None, False)
    gb = _body(t, "fm1_led_glow") or _body(t, "fm1_led_key_glow") or ""
    glow = _target(gb)
    if ty == "uint64_t" and not arr:
        defs.append(f"-DDH_LED64={led}")
    elif ty == "uint32_t" and not arr and re.search(r"\bid\s*-\s*14u?\b", lb):
        defs.append(f"-DDH_LED_KEYS32={led}")
    elif ty == "uint8_t" and arr:
        defs.append(f"-DDH_LED_ARR={led}")
        if glow == led:                                  # (one array: 2 lit, 1 dim)
            defs.append("-DDH_LED_ARR_GLOW=1")
    if glow and glow != led:
        gty, garr = _decl(t, glow)
        if gty == "uint64_t" and not garr:
            defs.append(f"-DDH_GLOW64={glow}")
        elif gty == "uint8_t" and garr:
            defs.append(f"-DDH_GLOW_ARR={glow}")
    elif not glow and _decl(t, "host_glow") == ("uint64_t", False):
        defs.append("-DDH_GLOW64=host_glow")
    for i, name in enumerate(n for n in STORE if _decl(t, n)[1]):
        defs.append(f"-DDH_STORE{i}={name}")
    return defs


# ------------------------------------------------------------------------------------------------ build ---

def build_dinghy(fid, r, target, shims, log):
    """the app with its fake FM-1, the fake's script runner renamed away, its main() kept for the adapter to call,
    and adapters/dinghy.c driving the app's loop"""
    d = SRC / fid / r.get("root", "")
    cc, cflags_t, lflags_t = target_cc(target)
    work = CAT / "obj" / target / fid
    shutil.rmtree(work, ignore_errors=True)
    tree = work / "tree"
    skip = shutil.ignore_patterns("*.wav", "*.png", "*.ppm", "*.txt", "*.fwsc", "*.bin")
    shutil.copytree(d / "firmware", tree / "firmware", symlinks=True, ignore=skip)
    if (d / "tests").is_dir():
        shutil.copytree(d / "tests", tree / "tests", symlinks=True, ignore=skip)
    if r.get("app_from"):
        shutil.copyfile(SRC / fid / r["app_from"], tree / r["app"])
    host_rel = r.get("host", "tests/host.c")
    (tree / host_rel).parent.mkdir(parents=True, exist_ok=True)
    host = (d / host_rel).read_text(errors="replace")
    obv = r["macro"] == "OBV_HOST"                      # (OberVave's line: OBV_WASM leaves poll and main to us)
    host, n_poll = re.subn(r"^static void platform_poll\(void\)(?!\s*;)",
                           "static __attribute__((unused)) void host_script_poll(void)", host, flags=re.M)
    mains = list(re.finditer(r"^int main\(int argc, char \*\*argv\)", host, re.M))
    if mains and not obv:                               # (the fork's own setup, then the app: the adapter's boot first)
        m = mains[-1]
        b = _block(host, m.end())
        nb = re.sub(r"\b(app_main|app_init)\s*\(\s*\)", r"(dh_boot(), \1())", b, count=1)
        host = host[:m.start()] + host[m.start():].replace(b, nb, 1)
        host = host[:m.start()] + "static __attribute__((unused)) int host_script_main(int argc, char **argv)" + \
            host[m.end():]
    (tree / host_rel).write_text(host)
    if not n_poll and not obv:
        log.append("dinghy: the fake FM-1 has no platform_poll to replace")
        return None, "adapter"
    for extra in ("gen", "build/gen"):
        if (d / extra).is_dir():
            shutil.copytree(d / extra, tree / extra, symlinks=True)
    # the names the adapter needs: the host file and the fake FM-1 headers beside it (CS-1's tests/fake_fm1.h)
    fake = host + "".join((d / host_rel).parent.joinpath(h).read_text(errors="replace")
                          for h in re.findall(r'#include\s+"([^"]+\.h)"', (d / "firmware/src/platform.c").read_text(
                              errors="replace") + host) if (d / host_rel).parent.joinpath(h).exists() and "fake" in h)
    defs = [f"-D{r['macro']}=1"] + (["-DOBV_WASM=1"] if obv else []) + fake_names(fake)
    if mains and not obv:
        defs.append("-DDH_HOST_MAIN=1")
    if re.search(r"\bout_usb16\s*\(", _body(host, "host_script_poll") or ""):
        defs.append("-DDH_OUT_USB16=1")             # (GR!MM V2: the app's words are 24-bit, USB their 16-bit copy)
    # the fork's host build: its -I, the units beside the app
    app_name = r["app"].rsplit("/", 1)[1]
    ccs = _cc_lines(d, r["macro"])
    line = next((l for _, l in ccs if app_name in l), ccs[0][1] if ccs else "")
    try:
        argv = shlex.split(line)
    except ValueError:
        argv = line.split()
    def at(rel):
        """a path of the host build: in the tree copy (copied in when the copy lacks it), or, outside the
        firmware's tree (scintilla's ../engine), where it is"""
        p = (d / rel).resolve()
        if p != d.resolve() and d.resolve() not in p.parents:
            return p
        t = tree / p.relative_to(d.resolve())
        if not t.exists() and p.is_dir():
            shutil.copytree(p, t, symlinks=True)
        elif not t.exists() and p.exists():
            t.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p, t)
        return t
    incs, units = [], []                        # (its -D are the host tests' tunings, e.g. artihive's BOOT_HOLD_MS=1)
    for i, a in enumerate(argv):
        v = a[2:] or (argv[i + 1] if i + 1 < len(argv) else "")
        if a.startswith("-I") and v and not v.startswith("/"):
            incs += ["-I", str(at(v))]
        elif a.endswith(".c") and not a.startswith("-") and argv[i - 1] != "-o":
            units.append(a)
    apps, included = _apps(d / "firmware/src")
    run_host = d / "tests/run_host.sh"           # (and the units its variables name: opn1's EXTRA)
    units += re.findall(r"firmware/src/[\w/]+\.c", run_host.read_text(errors="replace")) if run_host.exists() else []
    extras = []
    for x in units:
        p = at(x)
        if (p.exists() and p.name != app_name and p not in extras and not (p.parent == tree / "firmware/src" and (
                p.name in included or p.name in apps or p.name == "platform.c"))):
            extras.append(p)
    fallback = [f for p in sorted((tree / "firmware").iterdir()) if p.is_dir() for f in ("-idirafter", str(p))]
    version = PINS[fid]["version"]
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    common = [*cc, "-fPIC", "-O2", "-w", "-ffp-contract=off", *cflags_t, *shimflags, *defs,
              f'-DAPP_VER="{version}"', *incs, "-I", str(tree / "firmware/src"), "-I", str(tree / "firmware/hal"),
              "-I", str(tree / "firmware/gen"), "-I", str(tree / "build/gen"), *fallback]
    o = work / "cart.o"
    if sh([*common, f'-DFW_MAIN="{tree / r["app"]}"', "-c", str(HERE / "adapters/dinghy.c"), "-o", str(o)], ROOT,
          log=log):
        return None, "compile"
    objs = [str(o)]
    for i, x in enumerate(extras):                      # (opn1's opn2.c, psg.c ...; mvance's mv_dsp.c)
        xo = work / f"extra{i}.o"
        if sh([*common, "-c", str(x), "-o", str(xo)], ROOT, log=log):
            return None, "compile"
        objs.append(str(xo))
    out = link(fid, target, objs, False, log)
    return (out, None) if out else (None, "link")


def build(fid, r, target, log, res):
    stage = None
    for shims in (False, True):
        out, stage = build_dinghy(fid, r, target, shims, log)
        res["shims"] = shims
        if out:
            return out, None
    return None, stage

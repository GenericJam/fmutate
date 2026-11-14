"""Recipe "dinghy": zvenson's Dinghy platform. firmware/src/platform.c includes the fake FM-1 tests/host.c under
DINGHY_HOST (OBV_HOST in OberVave's line); a copy of the firmware is compiled with adapters/dinghy.c, which drives the
app's loop as native/engine/live.c does (the fake FM-1's own script runner and main() renamed away)."""
import re
import shutil
from pathlib import Path

from common import CAT, HERE, PINS, ROOT, SHIM_INC, SRC, link, sh, target_cc

ORDER = 10

def detect(d, fid):
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
    shutil.copytree(d / "tests", tree / "tests", symlinks=True,
                    ignore=shutil.ignore_patterns("*.wav", "*.png", "*.ppm", "*.py", "*.txt"))
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
    for name in ("host_rel", "host_enc_pos", "host_leds", "host_glow"):
        if re.search(r"^static\s[^;(]*\b%s\b" % name, host, re.M):
            defs.append(f"-DDH_HAS_{name}=1")
    if re.search(r"^static\s+uint64_t\s+host_led\b", host, re.M):
        defs.append("-DDH_HAS_host_led64=1")
    elif re.search(r"^static\s+uint8_t\s+host_led\s*\[", host, re.M):
        defs.append("-DDH_HAS_host_led_arr=1")
    version = PINS[fid]["version"]
    shimflags = ["-I", str(SHIM_INC), "-include", str(SHIM_INC / "fm1_native_shims.h")] if shims else []
    o = work / "cart.o"
    cmd = [*cc, "-fPIC", "-O2", "-w", "-ffp-contract=off", *cflags_t, *shimflags, *defs,
           f'-DAPP_VER="{version}"', f'-DFW_MAIN="{tree / r["app"]}"',
           "-I", str(tree / "firmware/src"), "-I", str(tree / "firmware/hal"), "-I", str(tree / "firmware/gen"),
           "-I", str(tree / "build/gen"), "-c", str(HERE / "adapters/dinghy.c"), "-o", str(o)]
    if sh(cmd, ROOT, log=log):
        return None, "compile"
    objs = [str(o)]
    # other units the fake FM-1's own build compiles beside the app (tests/run_host.sh: opn1's opn2.c, psg.c ...)
    run_host = d / "tests/run_host.sh"
    extras = sorted(set(re.findall(r"firmware/src/[\w/]+\.c", run_host.read_text(errors="replace")))) if run_host.exists() else []
    for i, x in enumerate(e for e in extras if e != r["app"]):
        xo = work / f"extra{i}.o"
        if sh([*cc, "-fPIC", "-O2", "-w", "-ffp-contract=off", *cflags_t, *shimflags, *defs, f'-DAPP_VER="{version}"',
               "-I", str(tree / "firmware/src"), "-I", str(tree / "firmware/hal"), "-I", str(tree / "firmware/gen"),
               "-I", str(tree / "build/gen"), "-c", str(tree / x), "-o", str(xo)], ROOT, log=log):
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

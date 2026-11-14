#!/usr/bin/env python3
"""Classify the fetched firmware sources (native/build/catalog/src/<id>, tools/native_catalog/fetch.sh).

    python3 tools/native_catalog/classify.py      -> native/build/catalog/classify.json, a table on stdout

Per firmware: the SDK lineage, the build system, which host (desktop) builds the repository has, whether it
uses the FM-1's second core, its size. Static: it reads files, runs nothing.

Lineages (what the host build of a firmware looks like):
  dinghy     zvenson's Dinghy platform: firmware/src/platform.c with a host build (OBV_HOST), the browser
             simulator web/sim/sim.c, one firmware/src/<app>.c. native/engine/live.c runs it.
  x0x-web    the Felucca/X0X lineage's browser build: web/emu/<x>_web.c compiles the whole firmware against a
             simulated FM-1 and exports web_boot / web_render / web_keys / web_screen ... (charlesvestal/fm1-x0x
             first). native/engine/live_web.c runs it.
  felucca    Felucca's HAL (firmware/hal/fm1_*.h, src/main.c) without a browser build of its own.
  other      anything else; `host` lists what host code there is.
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "native/build/catalog/src"
OUT = ROOT / "native/build/catalog/classify.json"
PINS = json.loads((Path(__file__).resolve().parent / "pins.json").read_text())

C_EXT = {".c", ".h", ".S", ".s", ".cpp", ".cc", ".hpp", ".inc"}
SKIP_DIRS = {"node_modules", ".git", "build", "dist", "out"}


def walk(d):
    for dirpath, dirnames, files in os.walk(d):
        dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
        for f in files:
            yield Path(dirpath) / f


def read(p, limit=2_000_000):
    try:
        if p.stat().st_size > limit:
            return ""
        return p.read_text(errors="replace")
    except OSError:
        return ""


def classify(fid):
    d = SRC / fid
    files = [p for p in walk(d) if p.is_file()]
    rel = {str(p.relative_to(d)): p for p in files}
    c_files = [p for p in files if p.suffix in C_EXT]
    fw_c = [p for p in c_files if "/firmware/" in "/" + str(p.relative_to(d)) and "/tests/" not in str(p)]
    loc = sum(read(p).count("\n") for p in fw_c)
    size_kb = sum(p.stat().st_size for p in files) // 1024

    host = []
    web_c = [k for k in rel if re.match(r"web/emu/[^/]+_web\.c$", k) or re.match(r"web/[^/]+/[^/]+_web\.c$", k)]
    web_api = [k for k in web_c if "web_render" in read(rel[k]) and "web_screen" in read(rel[k])]
    if web_api:
        host.append("web/emu")
    if "web/sim/sim.c" in rel:
        host.append("web/sim")
    if "tests/host.c" in rel:
        host.append("tests/host.c")
    if "tests/hostsim.c" in rel:
        host.append("tests/hostsim.c")
    other_wasm = []
    for k, p in rel.items():
        if p.suffix in (".c", ".cpp") and k not in web_c and k != "web/sim/sim.c" and not k.startswith("tests/"):
            t = read(p)
            if "EMSCRIPTEN_KEEPALIVE" in t or ("__EMSCRIPTEN__" in t and "export" in t.lower()):
                other_wasm.append(k)
    if other_wasm:
        host.append("wasm:" + ",".join(sorted(other_wasm)[:3]))

    platform = rel.get("firmware/src/platform.c")
    dinghy_host = bool(platform) and "OBV_HOST" in read(platform)
    felucca_hal = "firmware/hal/fm1_input.h" in rel and "firmware/src/main.c" in rel

    if dinghy_host and "web/sim" in host:
        lineage = "dinghy"
    elif web_api:
        lineage = "x0x-web"
    elif dinghy_host:
        lineage = "dinghy-nosim"
    elif felucca_hal:
        lineage = "felucca"
    else:
        lineage = "other"

    buildsys = [b for b in ("build.sh", "tools/build.py", "Makefile", "CMakeLists.txt", "Cargo.toml",
                            "platformio.ini", "build.zig", "firmware/Makefile", "meson.build") if b in rel]
    alltext = None

    def grep(pattern, paths):
        r = re.compile(pattern)
        return sum(1 for p in paths if r.search(read(p)))

    toolchain = []
    bs_text = " ".join(read(rel[b]) for b in buildsys if b in rel)
    if "pi32v2" in bs_text or "JIELI" in bs_text.upper() or "jieli" in bs_text:
        toolchain.append("jieli-pi32v2")
    if "arm-none-eabi" in bs_text:
        toolchain.append("arm-none-eabi")
    if "zig" in bs_text and "build.zig" in rel:
        toolchain.append("zig")
    langs = sorted({p.suffix for p in c_files} | ({".rs"} if any(p.suffix == ".rs" for p in files) else set()))

    dual = grep(r"fm1_cpu1_start\s*\(|FELUCCA_CPU2\s+1|cpu1_entry|core1_main|CPU1_ENTRY", fw_c)
    dual_doc = any(k.upper().startswith("DUALCORE") for k in rel)
    smk = "SMK37.md" in rel or any("smk" in k.lower() for k in rel if k.startswith("firmware/src/"))

    return {
        "id": fid,
        "lineage": lineage,
        "host": host,
        "web_entry": web_api[0] if web_api else None,
        "buildsys": buildsys,
        "toolchain": toolchain,
        "langs": langs,
        "dual_core": dual > 0 or dual_doc,
        "dual_core_files": dual,
        "firmware_loc": loc,
        "size_kb": size_kb,
        "c_files": len(fw_c),
    }


def main():
    ids = sys.argv[1:] or [i for i in PINS if (SRC / i).is_dir()]
    res = {}
    for fid in ids:
        if (SRC / fid).is_dir():
            res[fid] = classify(fid)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    old = json.loads(OUT.read_text()) if OUT.exists() and sys.argv[1:] else {}
    old.update(res)
    OUT.write_text(json.dumps(old, indent=1) + "\n")
    from collections import Counter
    print("lineage", Counter(r["lineage"] for r in old.values()).most_common())
    print("dual core", sum(r["dual_core"] for r in old.values()))
    print("toolchain", Counter(tuple(r["toolchain"]) for r in old.values()).most_common())
    print("buildsys", Counter(tuple(r["buildsys"]) for r in old.values()).most_common(8))
    print("host", Counter(h.split(":")[0] for r in old.values() for h in r["host"]).most_common())


if __name__ == "__main__":
    main()

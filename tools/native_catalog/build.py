#!/usr/bin/env python3
"""Build one Hub firmware as a native cartridge (libcart_<id>.so, the fm1c_* calls of native/engine/live.c).

    python3 tools/native_catalog/build.py <id> [--target host|android-arm64-v8a|android-x86_64|android-armeabi-v7a]

Non-interactive and one firmware per call, so a CI job per firmware runs it as it is. Needs the source fetched
(tools/native_catalog/fetch.sh <id>). Writes native/build/catalog/out/<target>/libcart_<id>.so and the outcome
to native/build/catalog/results/<id>.<target>.json: {"ok", "stage", "recipe", "shims", "log"}.

Recipes (tools/native_catalog/recipes/*.py; how the firmware's own host build is found and built, nothing of the
firmware changed): each has ORDER, detect(source_dir, id) -> recipe dict or None, and build(id, recipe, target, log,
result) -> (cartridge path or None, failed stage). The first to recognise a tree builds it: dinghy (zvenson's Dinghy
platform), web (the X0X lineage's browser builds), ...
Generic shims, tried when a plain build fails: shims/include (emscripten.h; ELF-only section attributes on
Mach-O). A firmware needing more than that is a per-firmware patch (tools/native_catalog/patches/<id>/*.patch).
"""
import argparse
import importlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import CAT, HERE, SRC, sh  # noqa: E402

RECIPES = {}
for _p in sorted((HERE / "recipes").glob("[a-z]*.py")):
    _m = importlib.import_module("recipes." + _p.stem)
    RECIPES[_p.stem] = _m


def recipe(d, fid):
    """the first recipe (by ORDER) that recognises the source tree"""
    for m in sorted(RECIPES.values(), key=lambda m: m.ORDER):
        r = m.detect(d, fid)
        if r:
            return r
    return {"recipe": None}


# ------------------------------------------------------------------------------------------------- main ---

def build(fid, target):
    log = []
    res = {"id": fid, "target": target, "ok": False, "stage": None, "recipe": None, "shims": False}
    d = SRC / fid
    if not d.is_dir():
        res["stage"] = "fetch"
        return res, log
    r = recipe(d, fid)
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
    out, stage = RECIPES[r["recipe"]].build(fid, r, target, log, res)
    res["stage"] = stage
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

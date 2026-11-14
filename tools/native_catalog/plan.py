#!/usr/bin/env python3
"""Which firmwares a CI run builds: those whose pin differs from the published index's (a new Hub entry, a new
version, a new pin), plus any named; as a JSON list on stdout (a GitHub Actions matrix).

    python3 plan.py [--index URL_OR_FILE] [--all] [id ...]

The published index is read from --index (default: the live one); none (the first run) means everything.
`overrides.json` (beside this file) can hold {"skip": {id: reason}}: firmwares not to build (for example a
licence question), listed in the report rather than built.
"""
import argparse
import json
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
INDEX_URL = "https://genericjam.github.io/fmutate-cartridges/index.json"


def published(src):
    try:
        if src.startswith("http"):
            req = urllib.request.Request(src, headers={"User-Agent": "fmutate-cartridges"})
            return json.loads(urllib.request.urlopen(req, timeout=60).read())
        return json.loads(Path(src).read_text())
    except Exception as e:                          # (no index yet: build everything)
        print(f"plan: no published index ({e}); building all", file=sys.stderr)
        return {"firmwares": []}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default=INDEX_URL)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("ids", nargs="*")
    a = ap.parse_args()
    pins = json.loads((HERE / "pins.json").read_text())
    ov = json.loads((HERE / "overrides.json").read_text()) if (HERE / "overrides.json").exists() else {}
    skip = ov.get("skip", {})
    if a.ids:
        todo = [i for i in a.ids if i in pins]
    elif a.all:
        todo = list(pins)
    else:
        idx = {f["id"]: f for f in published(a.index).get("firmwares", [])}
        tried = {f["id"]: f for f in published(a.index).get("tried", [])}
        todo = []
        for fid, p in pins.items():
            old = idx.get(fid) or tried.get(fid)
            if not old or old.get("commit") != p["commit"] or old.get("version") != p["version"]:
                todo.append(fid)
    print(json.dumps([i for i in todo if i not in skip]))


if __name__ == "__main__":
    main()

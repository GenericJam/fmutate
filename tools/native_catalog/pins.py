#!/usr/bin/env python3
"""Pin every FM-1 Firmware Hub firmware to a source commit.

    python3 tools/native_catalog/pins.py [catalog.json]     -> tools/native_catalog/pins.json

For each catalogue entry: the commit its package was built from, in this order of trust:
  provenance  the Hub's verified build provenance (`provenance.commit`, a signed CI build of that commit)
  srcref      the Hub's own source reference
  tag         the entry's release tag (`tag`), resolved with `git ls-remote` (annotated tags dereferenced)
  head        the default branch's HEAD today: the entry names no tag, so the package's exact source is unknown
An entry whose Hub version is unchanged keeps its pin (re-running doesn't move a HEAD pin); a new version
resolves again. The catalogue defaults to https://thefirmwarehub.com/catalog.json.
"""
import json
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
PINS = HERE / "pins.json"
HUB = "https://thefirmwarehub.com/catalog.json"


def load_catalog(arg):
    if arg and not arg.startswith("http"):
        return json.loads(Path(arg).read_text())
    with urllib.request.urlopen(arg or HUB, timeout=60) as r:
        return json.loads(r.read())


def ls_remote(url, *refs):
    out = subprocess.run(["git", "ls-remote", url, *refs], capture_output=True, text=True, timeout=120,
                         env={"GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin:/opt/homebrew/bin"})
    if out.returncode:
        raise RuntimeError(out.stderr.strip()[:200])
    return dict(reversed(line.split("\t")) for line in out.stdout.splitlines() if "\t" in line)


def resolve(fw):
    url = "https://github.com/%s.git" % fw["repo"]
    prov = fw.get("provenance") or {}
    if prov.get("commit") and prov.get("repo", "").lower() == fw["repo"].lower():
        return {"commit": prov["commit"], "how": "provenance", "ref": prov.get("ref")}
    if fw.get("srcref"):
        return {"commit": fw["srcref"], "how": "srcref", "ref": None}
    if fw.get("tag"):
        tag = "refs/tags/" + fw["tag"]
        refs = ls_remote(url, tag, tag + "^{}")
        commit = refs.get(tag + "^{}") or refs.get(tag)
        if commit:
            return {"commit": commit, "how": "tag", "ref": tag}
    refs = ls_remote(url, "HEAD")
    return {"commit": refs["HEAD"], "how": "head", "ref": "HEAD@" + date.today().isoformat()}


def main():
    cat = load_catalog(sys.argv[1] if len(sys.argv) > 1 else None)
    old = json.loads(PINS.read_text()) if PINS.exists() else {}
    todo = []
    pins = {}
    for fw in cat["firmwares"]:
        entry = {"name": fw.get("name") or fw["id"], "repo": fw["repo"], "version": str(fw.get("version")), "pkg": fw.get("pkg"),
                 "sha256": fw.get("sha256"), "lic": fw.get("lic"), "tag": fw.get("tag")}
        prev = old.get(fw["id"])
        if prev and prev["version"] == entry["version"] and prev["repo"] == entry["repo"] and prev.get("commit"):
            pins[fw["id"]] = {**entry, **{k: prev[k] for k in ("commit", "how", "ref")}}
        else:
            todo.append((fw, entry))

    def one(item):
        fw, entry = item
        try:
            return fw["id"], {**entry, **resolve(fw)}
        except Exception as e:                  # (a repository gone or private: recorded, not fatal)
            return fw["id"], {**entry, "commit": None, "how": "error", "ref": str(e)}

    with ThreadPoolExecutor(16) as ex:
        for fid, pin in ex.map(one, todo):
            pins[fid] = pin
    order = [fw["id"] for fw in cat["firmwares"]]
    PINS.write_text(json.dumps({k: pins[k] for k in order}, indent=1) + "\n")
    how = {}
    for p in pins.values():
        how[p["how"]] = how.get(p["how"], 0) + 1
    print("pins: %d (%s), %d resolved now" % (len(pins), ", ".join("%s %d" % kv for kv in sorted(how.items())),
                                             len(todo)))


if __name__ == "__main__":
    main()

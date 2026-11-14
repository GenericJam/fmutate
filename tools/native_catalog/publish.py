#!/usr/bin/env python3
"""Assemble and sign the cartridge index (schema 1, docs/decisions/2026-11-14-native-catalog.md "The index").

    python3 publish.py --artifacts DIR --tag TAG --out DIST [--prev INDEX] [--key signing.pem]

DIR holds what the build jobs uploaded, one directory per firmware (any layout below it): results/<id>.<platform>.json,
out/<platform>/libcart_<id>.so (Android, this computer) or libcart_<id>.a (iOS), verify/<id>.json. A firmware is
published when its check against the emulator is `match` or `silent` (report.py's verdicts), or overrides.json
"accept" names it with the reason a person checked; anything else goes to the index's "tried" list with the reason,
so the next run doesn't build the same commit again. Firmwares not built in this run keep their entries from --prev
(the published index). Writes DIST/assets/libcart_<id>-<version>-<platform>.<so|a> (+ .sig each) and DIST/index.json
+ index.json.sig, signed with --key (Ed25519 PEM, `openssl genpkey -algorithm ed25519`) through openssl. Asset URLs
are https://github.com/<repo>/releases/download/<tag>/<file>.
"""
import argparse
import base64
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import date, datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from report import verdict  # noqa: E402

REPO = "GenericJam/fmutate-cartridges"
PUBLISHABLE = {"match", "silent"}
PLATFORMS = ("android-arm64-v8a", "android-x86_64", "android-armeabi-v7a", "ios-device", "ios-sim")


def sign(key, path):
    sig = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(key), "-rawin", "-in", str(path)],
                         capture_output=True, check=True).stdout
    return base64.b64encode(sig).decode()


def load_prev(src):
    if not src:
        return {"firmwares": [], "tried": []}
    if src.startswith("http"):
        import urllib.request
        try:
            req = urllib.request.Request(src, headers={"User-Agent": "fmutate-cartridges"})
            return json.loads(urllib.request.urlopen(req, timeout=60).read())
        except Exception:
            return {"firmwares": [], "tried": []}
    return json.loads(Path(src).read_text())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prev")
    ap.add_argument("--key")
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--hub-updated")
    a = ap.parse_args()
    pins = json.loads((HERE / "pins.json").read_text())
    ov = json.loads((HERE / "overrides.json").read_text()) if (HERE / "overrides.json").exists() else {}
    accept = ov.get("accept", {})
    art = Path(a.artifacts)
    out = Path(a.out)
    (out / "assets").mkdir(parents=True, exist_ok=True)
    prev = load_prev(a.prev)
    entries = {f["id"]: f for f in prev.get("firmwares", [])}
    tried = {f["id"]: f for f in prev.get("tried", [])}
    today = date.today().isoformat()

    built = {}
    for rj in art.rglob("results/*.json"):
        r = json.loads(rj.read_text())
        if not isinstance(r, dict) or "id" not in r or "target" not in r:
            continue
        built.setdefault(r["id"], {})[r["target"]] = (r, rj.parents[1])

    for fid, per in sorted(built.items()):
        pin = pins.get(fid)
        if not pin:
            continue
        host = per.get("host", (None, None))
        root = (host[1] or next(iter(per.values()))[1])
        vj = next(root.rglob(f"verify/{fid}.json"), None)
        recipe = (host[0] or {}).get("recipe", {}) or {}
        if vj:
            check, why = verdict(json.loads(vj.read_text()), recipe.get("recipe"))
            v = json.loads(vj.read_text())
        else:
            check, why, v = "unchecked", ["no check ran"], {}
        ok = check in PUBLISHABLE or fid in accept
        assets = {}
        for platform in PLATFORMS:
            r, rroot = per.get(platform, (None, None))
            if not r or not r.get("ok"):
                continue
            src = next(rroot.rglob(f"out/{platform}/libcart_{fid}.*"), None)
            if not src:
                continue
            name = f"libcart_{fid}-{pin['version']}-{platform}{src.suffix}".replace("/", "_")
            dst = out / "assets" / name
            shutil.copyfile(src, dst)
            sig = sign(a.key, dst) if a.key else ""
            if sig:
                (out / "assets" / (name + ".sig")).write_text(sig + "\n")
            assets[platform] = {"url": f"https://github.com/{a.repo}/releases/download/{a.tag}/{name}",
                                "sha256": hashlib.sha256(dst.read_bytes()).hexdigest(), "size": dst.stat().st_size,
                                "sig": sig}
        host_r = host[0] or {}
        base = {"id": fid, "version": pin["version"], "repo": pin["repo"], "commit": pin["commit"], "pin": pin["how"]}
        if not ok or not assets:
            reason = "; ".join(why) if not ok else "no platform built: " + str(
                {p: (per[p][0].get("stage")) for p in per})
            tried[fid] = {**base, "check": check, "reason": reason[:300], "date": today}
            for p in list(assets):
                (out / "assets" / Path(assets[p]["url"]).name).unlink(missing_ok=True)
                (out / "assets" / (Path(assets[p]["url"]).name + ".sig")).unlink(missing_ok=True)
            continue
        tried.pop(fid, None)
        c = v.get("compare", {})
        old = entries.get(fid, {})
        entries[fid] = {
            **base, "name": pin.get("name") or fid, "license": pin["lic"], "recipe": recipe.get("recipe"),
            "build": "patch" if host_r.get("patches") else "shims" if host_r.get("shims") else "clean",
            "patches": host_r.get("patches", []),
            "parity": {"status": check if check in PUBLISHABLE else "accepted", "level_diff_db": c.get("level_diff_db"),
                       "spectrum_corr": c.get("spectrum_corr"),
                       "screen_diff": max([c.get(k, 0) for k in c if k.startswith("screen_diff")] or [0]),
                       "notes": accept.get(fid) or "; ".join(why)},
            "added": old.get("added", today), "updated": today,
            "assets": {**({k: v2 for k, v2 in old.get("assets", {}).items()} if old.get("commit") == pin["commit"] else {}),
                       **assets},
        }

    index = {"schema": 1, "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "engine_abi": 1,
             "hub_updated": a.hub_updated or prev.get("hub_updated"),
             "firmwares": [entries[k] for k in sorted(entries)], "tried": [tried[k] for k in sorted(tried)]}
    ip = out / "index.json"
    ip.write_text(json.dumps(index, indent=1) + "\n")
    if a.key:
        (out / "index.json.sig").write_text(sign(a.key, ip) + "\n")
    print(f"index: {len(index['firmwares'])} published, {len(index['tried'])} tried; "
          f"{len(list((out / 'assets').glob('*.so'))) + len(list((out / 'assets').glob('*.a')))} assets this run")


if __name__ == "__main__":
    main()

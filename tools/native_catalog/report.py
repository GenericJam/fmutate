#!/usr/bin/env python3
"""Summarise builds and checks: tools/native_catalog/results.json and a Markdown report on stdout.

    python3 tools/native_catalog/report.py [--target host]

Per firmware: how it built (clean: as its own host build is; shims: with the generic shims; patch: with
per-firmware patches; failed: the stage and the first error), and the check against the emulator (verify.py):
  match      audio within 3 dB (after the recipe's known level offset), spectra correlated >= 0.9, screens within
             12/255 after boot, in the chord and while playing
  silent     neither run sounds from a chord or PLAY (a firmware that waits for something else), screens match
  diverges   native runs (sound and a screen) but differs from the emulator (the reasons listed)
  no-ref     native runs; the emulator gave nothing to compare (silent or failed)
  broken     native has no screen, or is silent where the emulator sounds, or doesn't start
"""
import argparse
import json
import os
import re
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAT = Path(os.environ.get("FM1_CATALOG_DIR") or HERE.parents[1] / "native/build/catalog")
PINS = json.loads((HERE / "pins.json").read_text())


def first_error(log):
    for line in log.splitlines():
        if re.search(r"error:|Undefined symbols|not found|No such file|failed", line):
            return re.sub(r"/\S*/native/build/catalog/(src|obj/\w+)/", "", line).strip()[:160]
    return ""


# the Dinghy line's native level is its USB audio (Q15 as the app renders it); the emulator plays its DAC, where the
# firmware puts Q15 at -6 dBFS (platform.c: `o[i] <<= 7` into the 24-bit word). The browser builds play the DAC's.
LEVEL_OFFSET_DB = {"dinghy": 6.0}


def verdict(v, recipe=None):
    n, e, c = v.get("native"), v.get("emu"), v.get("compare", {})
    if not n:
        return "broken", ["native: " + v.get("native_error", "no run")[:120]]
    why = []
    n_sound = max(n["chord"]["peak"], n.get("play", {}).get("peak", 0)) >= 64
    e_sound = bool(e) and max(e["chord"]["peak"], e.get("play", {}).get("peak", 0)) >= 64
    if not n.get("lit_screen"):
        why.append("native screen dark")
    if not n_sound and e_sound:
        why.append("native silent, the emulator sounds")
    if why:
        return "broken", why
    if not e:
        return "no-ref", ["emulator failed: " + v.get("emu_error", "")[:100]]
    for s in ("boot", "chord", "play"):
        if c.get(f"screen_diff_{s}", 0) > 12:
            why.append(f"screen {s} {c[f'screen_diff_{s}']}")
    if not n_sound:
        return ("silent" if not why else "diverges"), why or ["no sound from a chord or PLAY in either"]
    if not e_sound:
        return "no-ref", ["emulator silent in the chord and PLAY"] + why
    dl = c.get("level_diff_db", 99) - LEVEL_OFFSET_DB.get(recipe, 0.0)
    if abs(dl) > 3:
        why.append(f"level {dl:+.1f} dB ({c.get('window')})")
    if (c.get("spectrum_corr") or 0) < 0.9:
        why.append(f"spectrum r={c.get('spectrum_corr')} ({c.get('window')})")
    return ("match" if not why else "diverges"), why

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="host")
    a = ap.parse_args()
    cls = json.loads((CAT / "classify.json").read_text()) if (CAT / "classify.json").exists() else {}
    rows = {}
    for fid, pin in PINS.items():
        rp = CAT / "results" / f"{fid}.{a.target}.json"
        r = json.loads(rp.read_text()) if rp.exists() else {"ok": False, "stage": "not run"}
        row = {"id": fid, "repo": pin["repo"], "commit": pin["commit"], "pin": pin["how"], "version": pin["version"],
               "lic": pin["lic"], "lineage": cls.get(fid, {}).get("lineage"),
               "dual_core": cls.get(fid, {}).get("dual_core"), "loc": cls.get(fid, {}).get("firmware_loc"),
               "recipe": (r.get("recipe") or {}).get("recipe")}
        if r.get("ok"):
            row["build"] = "patch" if r.get("patches") else "shims" if r.get("shims") else "clean"
            row["size"] = r.get("size")
        else:
            row["build"] = "failed"
            row["stage"] = r.get("stage")
            lp = CAT / "results" / f"{fid}.{a.target}.log"
            row["cause"] = first_error(lp.read_text(errors="replace")) if lp.exists() else ""
        vp = CAT / "verify" / f"{fid}.json"
        if row["build"] != "failed" and vp.exists():
            v = json.loads(vp.read_text())
            row["check"], row["why"] = verdict(v, row["recipe"])
            n = v.get("native") or {}
            row["native_chord_db"] = (n.get("chord") or {}).get("rms_db")
            row["compare"] = v.get("compare")
            row["boot_ms"] = {"native_first_screen": n.get("first_screen_fw_ms"),
                              "emu_first_screen": (v.get("emu") or {}).get("first_screen_fw_ms")}
        bp = CAT / "bench" / f"{fid}.json"
        if bp.exists():
            row["bench"] = json.loads(bp.read_text())
        rows[fid] = row
    (HERE / "results.json").write_text(json.dumps(rows, indent=1) + "\n")

    b = Counter(r["build"] for r in rows.values())
    ch = Counter(r.get("check") for r in rows.values() if r["build"] != "failed")
    st = Counter(r.get("stage") for r in rows.values() if r["build"] == "failed")
    print(f"## Builds ({a.target}), {len(rows)} firmwares\n")
    print("| clean | generic shims | per-firmware patch | failed |\n|---|---|---|---|")
    print(f"| {b['clean']} | {b['shims']} | {b['patch']} | {b['failed']} |\n")
    print("Failed by stage: " + ", ".join(f"{k} {v}" for k, v in st.most_common()) + "\n")
    print("## Checks against the emulator\n")
    print(" | ".join(f"{k} {v}" for k, v in ch.most_common()) + "\n")
    print("| firmware | lineage | build | check | notes |\n|---|---|---|---|---|")
    for r in rows.values():
        note = r.get("cause") or "; ".join(r.get("why") or [])
        print(f"| {r['id']} | {r['lineage']} | {r['build']}{' (' + str(r.get('stage')) + ')' if r['build'] == 'failed' else ''} "
              f"| {r.get('check', '')} | {note.replace('|', '/')} |")


if __name__ == "__main__":
    main()

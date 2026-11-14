"""Recipe "gator": GATOR's host simulator (tools/sim.py: host/sim.c with host/host_hal.h, the app and its C++ DSP,
Mutable's Plaits, compiled with $CC / $CXX). sim.py runs with the recording stand-in as $CC and $CXX (generating the
font and tables as it does); the compiles are replayed natively, host/sim.c's own replaced by adapters/gator.c (which
includes it) for the fm1c_* calls."""
import sys

from common import SRC
from recipes import _entry

ORDER = 30


def detect(d, fid):
    s, h = d / "tools/sim.py", d / "host/sim.c"
    if s.exists() and h.exists() and (d / "host/host_hal.h").exists() and "app_frame" in h.read_text(errors="replace"):
        return {"recipe": "gator", "entry": "host/sim.c"}
    return None


def build(fid, r, target, log, res):
    cmds = _entry.record(fid, [sys.executable, "tools/sim.py", "--no-sanitize"], cc_env=True, clean=["build"], log=log)
    return _entry.build_with(fid, cmds, target, log, res, SRC / fid / r["entry"], "gator.c")

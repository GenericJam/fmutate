"""Recipe "demake": Demake's browser build (web/build.sh: emcc on web/dmk_web.c, the platform-free core
firmware/src/dmk_core.c and its exports w_*). The script runs with the recording emcc; its compile is replayed natively
with adapters/demake.c in place of web/dmk_web.c (it includes it) for the fm1c_* calls."""
from common import SRC
from recipes import _entry

ORDER = 30


def detect(d, fid):
    w = d / "web/dmk_web.c"
    if w.exists() and (d / "web/build.sh").exists() and (d / "firmware/src/dmk_core.c").exists():
        return {"recipe": "demake", "entry": "web/dmk_web.c", "script": "web/build.sh"}
    return None


def build(fid, r, target, log, res):
    cmds = _entry.record(fid, ["sh", r["script"]], log=log)
    return _entry.build_with(fid, cmds, target, log, res, SRC / fid / r["entry"], "demake.c")

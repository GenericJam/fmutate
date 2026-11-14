"""Recipe "guitchordi": Guitchordi's simulator build (scripts/build-simulator.sh: emcc on the platform-free app,
firmware/app.c + dsp/engine.c, exporting fw_*). The script runs with the recording emcc (it generates the firmware bank
first); its compile is replayed natively and adapters/guitchordi.c links beside it for the fm1c_* calls."""
from common import SRC
from recipes import _entry

ORDER = 30


def detect(d, fid):
    s = d / "scripts/build-simulator.sh"
    if s.exists() and (d / "firmware/app.c").exists() and "_fw_render" in s.read_text(errors="replace"):
        return {"recipe": "guitchordi", "entry": "firmware/app.c", "script": "scripts/build-simulator.sh"}
    return None


def build(fid, r, target, log, res):
    d = SRC / fid
    cmds = _entry.record(fid, ["sh", r["script"]], log=log)
    return _entry.build_with(fid, cmds, target, log, res, d / r["entry"], "guitchordi.c", mode="beside",
                             adapter_flags=["-I", str((d / r["entry"]).parent)])

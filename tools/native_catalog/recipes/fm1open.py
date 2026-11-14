"""Recipe "fm1open": an application on M-VAVE's fm1_open SDK with its browser simulator (web/engine/Simulator.c) and
that simulator's native build (tools/<app>/sim/native/Makefile, -DFM1_OPEN_WEB: app/ minus app/board, web/,
third_party/synth; DX747's). The Makefile runs with the recording stand-in as $(CC); the compile is replayed natively
without the harness's own main unit, with adapters/fm1open.c in Simulator.c's place (it includes it)."""
from common import CAT, SRC
from recipes import _entry

ORDER = 30


def detect(d, fid):
    sim = d / "web/engine/Simulator.c"
    if not sim.exists():
        return None
    for mk in sorted(d.glob("tools/*/sim/native/Makefile")):
        if "FM1_OPEN_WEB" in mk.read_text(errors="replace"):
            return {"recipe": "fm1open", "entry": "web/engine/Simulator.c", "make": str(mk.parent.relative_to(d))}
    return None


def build(fid, r, target, log, res):
    d = SRC / fid
    cmds = _entry.record(fid, ["make", "-B", "-C", r["make"], f"CC={CAT / 'bin-rec/cc'}"], stand_ins=("cc",), log=log)
    harness = (d / r["make"]).resolve()
    return _entry.build_with(fid, cmds, target, log, res, d / r["entry"], "fm1open.c",
                             keep=lambda p: harness not in p.parents)

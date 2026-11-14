"""Recipe "adrift": Adrift's browser emulator (build.sh web: the core modules and src/platform/platform_web.c,
clang --target=wasm32 -nostdlib, then wasm-ld). build.sh runs with the recording stand-in as $WASM_CC and $WASM_LD
(it stops after the emulator, at the FM-1 package it can't build here); the compiles are replayed natively with
adapters/adrift.c in platform_web.c's place (it includes it), the backend's own memcpy / memmove / memset renamed."""
from common import CAT, SRC
from recipes import _entry

ORDER = 30
LIBC_RENAMES = ["-Dmemcpy=fm1n_memcpy", "-Dmemmove=fm1n_memmove", "-Dmemset=fm1n_memset"]


def detect(d, fid):
    w = d / "src/platform/platform_web.c"
    if w.exists() and (d / "build.sh").exists() and "adrift_web_render_audio" in w.read_text(errors="replace"):
        return {"recipe": "adrift", "entry": "src/platform/platform_web.c"}
    return None


def build(fid, r, target, log, res):
    stand = CAT / "bin-rec"
    cmds = _entry.record(fid, ["sh", "build.sh", "web"], stand_ins=("clang", "wasm-ld"),
                         env_extra={"WASM_CC": str(stand / "clang"), "WASM_LD": str(stand / "wasm-ld")},
                         clean=["build/web", "build/web_obj"], log=log)
    return _entry.build_with(fid, cmds, target, log, res, SRC / fid / r["entry"], "adrift.c", extra=LIBC_RENAMES)

#!/usr/bin/env python3
"""Check a native cartridge against the same firmware's Hub package in the emulator engine.

    python3 tools/native_catalog/verify.py <id> [--cart PATH] [--pkg PATH]

Both run through the engine protocol (docs/engine_protocol.md), each in its own engine process, driven by this
script as the mixer would be (it drains the audio ring as fast as the engine fills it, so a run takes less wall time
than firmware time): libfm1engine.so + the cartridge, and libfm1emu.so + the package at 240 MHz (JIT). The same
script for both, on firmware time: boot and settle BOOT_MS, hold a chord (keys 7 11 14) for CHORD_MS, release, tap
PLAY (a sequencer, drum machine or looper starts), tap it again PLAY_MS later. Measured per run: boot (wall ms to READY; firmware ms to the first screen), audio level (RMS, peak) idle and
during the chord and while playing, their spectra (1/3-octave bands), the screen after boot, in the chord and while
playing. Compared: level difference (dB), spectral similarity (cosine of the band levels in dB), screen difference
(mean absolute RGB difference at each of the three, 0-255), audio in the louder window of the native run. Writes native/build/catalog/verify/<id>.json and
the screens as PNG, prints a one-line verdict. Needs native/build/host/libfm1engine.so and libfm1emu.so
(native/build_host.sh, native/build_emu.sh). The package is fetched from the Hub once (its size and SHA-256 checked).
"""
import argparse
import hashlib
import json
import mmap
import os
import select
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CAT = ROOT / "native/build/catalog"
HOST = ROOT / "native/build/host"
PINS = json.loads((HERE / "pins.json").read_text())
HUB = "https://thefirmwarehub.com/"

FS = 44100
BOOT_MS = 4000
CHORD_MS = 2500
TAIL_MS = 1000
CHORD = (7, 11, 14)
RING_FRAMES = 4096
FB_PIX = 240 * 240


def package(fid):
    p = CAT / "pkg" / f"{fid}.fwsc"
    pin = PINS[fid]
    if p.exists() and hashlib.sha256(p.read_bytes()).hexdigest() == pin["sha256"]:
        return p
    p.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(HUB + pin["pkg"], headers={"User-Agent": "fmutate-native-catalog"})
    data = urllib.request.urlopen(req, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise SystemExit(f"{fid}: the Hub's package doesn't match the catalogue's SHA-256")
    p.write_bytes(data)
    return p


class Engine:
    def __init__(self, exe, file, env=None):
        self.dir = tempfile.mkdtemp(prefix="fm1v")
        self.prefix = os.path.join(self.dir, "e")
        self.t0 = time.monotonic()
        self.p = subprocess.Popen([str(exe), str(file), self.prefix, os.path.join(self.dir, "flash.bin"), "1024"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env={**os.environ, **(env or {})})
        self.buf = b""
        self.ready_ms = None
        self.status = None
        os.set_blocking(self.p.stdout.fileno(), False)
        deadline = time.monotonic() + 60
        while self.ready_ms is None:
            if self.p.poll() is not None:
                raise RuntimeError("engine exited %s before READY: %s" % (self.p.returncode, self.p.stderr.read().decode(errors="replace")[-800:]))
            if time.monotonic() > deadline:
                raise RuntimeError("no READY in 60 s")
            self.pump(0.05)
        self.ready_wall_ms = (time.monotonic() - self.t0) * 1000
        rf = open(self.prefix + ".ring", "r+b")
        self.ring = mmap.mmap(rf.fileno(), 64 + RING_FRAMES * 4)
        ff = open(self.prefix + ".fb", "r+b")
        self.fb = mmap.mmap(ff.fileno(), 8 + FB_PIX * 2 + 16)

    def pump(self, timeout=0):
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if r:
            try:
                self.buf += os.read(self.p.stdout.fileno(), 65536)
            except BlockingIOError:
                pass
        while len(self.buf) >= 2:
            n = self.buf[0] << 8 | self.buf[1]
            if len(self.buf) < 2 + n:
                break
            m, self.buf = self.buf[2:2 + n], self.buf[2 + n:]
            if m[0] == 0x81:
                self.ready_ms = struct.unpack(">I", m[1:5])[0]
            elif m[0] == 0x82:
                self.status = struct.unpack(">IIIIII", m[1:25])

    def send(self, *b):
        m = bytes(b)
        self.p.stdin.write(bytes([len(m) >> 8, len(m) & 255]) + m)
        self.p.stdin.flush()

    def drain(self, frames):
        """take `frames` frames of audio, as fast as the engine makes them"""
        out = []
        got = 0
        while got < frames:
            w, r = struct.unpack_from("<QQ", self.ring, 16)
            if w == r:
                if self.p.poll() is not None:
                    raise RuntimeError("engine died: %s" % self.p.stderr.read().decode(errors="replace")[-800:])
                self.pump(0)
                time.sleep(0.0002)
                continue
            n = min(w - r, frames - got)
            pos = r % RING_FRAMES
            first = min(n, RING_FRAMES - pos)
            a = np.frombuffer(self.ring, dtype="<i2", count=first * 2, offset=64 + pos * 4)
            out.append(a.copy())
            if n > first:
                out.append(np.frombuffer(self.ring, dtype="<i2", count=(n - first) * 2, offset=64).copy())
            struct.pack_into("<Q", self.ring, 24, r + n)
            got += n
        self.pump(0)
        return np.concatenate(out).reshape(-1, 2)

    def screen(self):
        seq = struct.unpack_from("<I", self.fb, 4)[0]
        px = np.frombuffer(self.fb, dtype="<u2", count=FB_PIX, offset=8).copy().reshape(240, 240)
        return seq, px

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()


def rgb(px):
    r = ((px >> 11) & 31) * 255 // 31
    g = ((px >> 5) & 63) * 255 // 63
    b = (px & 31) * 255 // 31
    return np.stack([r, g, b], -1).astype(np.uint8)


def bands(x):
    """1/3-octave band levels (dB) of a mono signal, 50 Hz .. 16 kHz"""
    x = x - x.mean()
    n = 1 << int(np.log2(len(x)))
    spec = np.zeros(n // 2 + 1)
    hop = 8192
    win = np.hanning(hop)
    k = 0
    for i in range(0, len(x) - hop, hop // 2):
        spec[: hop // 2 + 1] += np.abs(np.fft.rfft(x[i:i + hop] * win)) ** 2
        k += 1
    spec = spec[: hop // 2 + 1] / max(k, 1)
    freqs = np.fft.rfftfreq(hop, 1 / FS)
    out = []
    f = 50.0
    while f < 16000:
        lo, hi = f / 2 ** (1 / 6), f * 2 ** (1 / 6)
        m = (freqs >= lo) & (freqs < hi)
        out.append(10 * np.log10(spec[m].sum() + 1e-9))
        f *= 2 ** (1 / 3)
    return np.array(out)


def level(a):
    m = a.astype(np.float64).mean(1)
    rms = np.sqrt((m ** 2).mean()) if len(m) else 0
    return {"rms_db": round(20 * np.log10(rms / 32768 + 1e-12), 1), "peak": int(np.abs(a).max()) if len(a) else 0}


PLAY_AT = BOOT_MS + CHORD_MS + 500             # PLAY tapped (a sequencer, a drum machine, a looper starts) ...
PLAY_MS = 2500                                 # ... and tapped again after this long
END_MS = PLAY_AT + PLAY_MS + 500


def run(exe, file, env=None):
    e = Engine(exe, file, env)
    res = {"ready_wall_ms": round(e.ready_wall_ms), "ready_fw_ms": e.ready_ms}
    first_screen_ms = None
    audio = []
    shots = {}
    ms = 0
    step = 50
    t_run = time.monotonic()
    while ms < END_MS:
        if ms == BOOT_MS:
            for k in CHORD:
                e.send(0x01, k, 1)
        if ms == BOOT_MS + CHORD_MS:
            for k in CHORD:
                e.send(0x01, k, 0)
        if ms in (PLAY_AT, PLAY_AT + PLAY_MS):
            e.send(0x02, 12, 1)
        if ms in (PLAY_AT + 100, PLAY_AT + PLAY_MS + 100):
            e.send(0x02, 12, 0)
        audio.append(e.drain(FS * step // 1000))
        ms += step
        seq, px = e.screen()
        if first_screen_ms is None and seq > 0 and px.any():
            first_screen_ms = ms
        for name, at in (("boot", BOOT_MS), ("chord", BOOT_MS + CHORD_MS), ("play", PLAY_AT + PLAY_MS)):
            if ms == at - step:
                shots[name] = px
    wall = time.monotonic() - t_run
    e.close()
    a = np.concatenate(audio)
    f = lambda t: FS * t // 1000
    win = {"chord": a[f(BOOT_MS + 500):f(BOOT_MS + CHORD_MS)], "play": a[f(PLAY_AT + 500):f(PLAY_AT + PLAY_MS)]}
    res.update(first_screen_fw_ms=first_screen_ms, speed_x=round(END_MS / 1000 / wall, 2),
               idle=level(a[f(BOOT_MS - 1000):f(BOOT_MS)]), chord=level(win["chord"]), play=level(win["play"]),
               lit_screen=any(px.any() for px in shots.values()))
    return res, a, shots, {k: bands(w.astype(np.float64).mean(1)) for k, w in win.items()}


def compare(n, e):
    """the window where the native run is loudest (the chord, or PLAY for what keys alone don't sound)"""
    k = "chord" if n[0]["chord"]["rms_db"] >= n[0]["play"]["rms_db"] else "play"
    na, ea = n[3][k], e[3][k]
    out = {"window": k, "level_diff_db": round(n[0][k]["rms_db"] - e[0][k]["rms_db"], 1)}
    # spectral similarity: correlation of the band levels where either has energy within 60 dB of its loudest band
    mask = (na > na.max() - 60) | (ea > ea.max() - 60)
    if mask.sum() >= 3 and n[0][k]["peak"] >= 64 and e[0][k]["peak"] >= 64:
        out["spectrum_corr"] = round(float(np.corrcoef(na[mask], ea[mask])[0, 1]), 3)
    for s in ("boot", "chord", "play"):
        if s in n[2] and s in e[2]:
            out[f"screen_diff_{s}"] = round(float(np.abs(rgb(n[2][s]).astype(int) - rgb(e[2][s]).astype(int)).mean()), 1)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("id")
    ap.add_argument("--cart")
    ap.add_argument("--pkg")
    ap.add_argument("--no-emu", action="store_true")
    a = ap.parse_args()
    fid = a.id
    cart = Path(a.cart or CAT / "out/host" / f"libcart_{fid}.so")
    vdir = CAT / "verify"
    vdir.mkdir(parents=True, exist_ok=True)
    rep = {"id": fid}
    try:
        n = run(HOST / "libfm1engine.so", cart.resolve())
        rep["native"] = n[0]
    except Exception as ex:
        rep["native_error"] = str(ex)[-600:]
        n = None
    e = None
    if not a.no_emu:
        try:
            e = run(HOST / "libfm1emu.so", Path(a.pkg) if a.pkg else package(fid))
            rep["emu"] = e[0]
        except Exception as ex:
            rep["emu_error"] = str(ex)[-600:]
    if n and e:
        rep["compare"] = compare(n, e)
    try:
        from PIL import Image
        for tag, r in (("native", n), ("emu", e)):
            for k, px in (r[2].items() if r else []):
                Image.fromarray(rgb(px)).save(vdir / f"{fid}.{tag}.{k}.png")
    except ImportError:
        pass
    (vdir / f"{fid}.json").write_text(json.dumps(rep, indent=1) + "\n")
    c = rep.get("compare", {})
    print(f"{fid}: native {'ok' if n else 'FAILED'}"
          + (f" chord {n[0]['chord']['rms_db']} play {n[0]['play']['rms_db']} dB x{n[0]['speed_x']}" if n else "")
          + (f" | emu chord {e[0]['chord']['rms_db']} play {e[0]['play']['rms_db']} dB" if e else "")
          + (f" | {c.get('window')} dL {c.get('level_diff_db')} dB, spec {c.get('spectrum_corr')}, screens "
             f"{c.get('screen_diff_boot')}/{c.get('screen_diff_chord')}/{c.get('screen_diff_play')}" if c else ""))

if __name__ == "__main__":
    main()

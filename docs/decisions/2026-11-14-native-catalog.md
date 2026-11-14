# Native cartridges for the Hub catalogue (draft, phase A in progress)

Status: proposed. Numbers from the Mac host build of 2026-11-14 (`python3 tools/native_catalog/report.py`).

## Why

The emulator (fm1-emu, `:emu`) can't guarantee full speed: on a Moto G Power 5G 2024 Skiff and Clipper sit at
~1.0x real time and Melodee at 0.68x, so FMutate lowers the emulated CPU clock, which changes the firmware; iOS has no
JIT (0.4–0.7x on an iPhone SE). A native cartridge runs the firmware's own C at native speed: on this Mac 25–660x
real time (Melodee 71x, Skiff 660x, `cartbench`), and sample-exact against the emulator where the check matches.

## The pipeline

`tools/native_catalog/` (moves to GenericJam/fmutate-cartridges; FMutate keeps the engine and the loader):

1. **Pins** (`pins.py` → `pins.json`): a commit per Hub entry: the Hub's verified build provenance (55), its source
   ref (1), the release tag (136), else the default branch's HEAD on the day (21, flagged `head`). A pin moves only
   when the Hub entry's version moves.
2. **Fetch** (`fetch.sh`): shallow fetch of the pinned commit and its submodules; git data and media no build reads
   dropped (213 trees: ~3.7 GB).
3. **Classify** (`classify.py`): lineage, host builds present, build system, dual-core use, size.
4. **Build** (`build.py <id> --target …`, one firmware per call): the first recipe that recognises the tree builds
   it, without changing the firmware:
   - `dinghy`: zvenson's Dinghy platform (platform.c + the fake FM-1 tests/host.c), driven like native/engine/live.c.
   - `web`: the X0X lineage's browser builds (Felucca forks' felucca_web.c, fm1-base's emu_web.c, …): the firmware's
     own browser build script runs with an `emcc` stand-in that records the calls (its tables and fonts generated as
     for the browser), the calls are replayed with clang for each target, `adapters/web.c` maps `web_*` to `fm1c_*`.
   - more recipes for the remaining lineages (Felucca forks without a browser build, wasm32 clang/zig builds, …).
   Targets: host, android-arm64-v8a / x86_64 / armeabi-v7a (NDK 27, 16 KB pages, stripped), ios-device / ios-sim
   (a static `libcart_<id>.a` whose only global is the table `fm1c_<id>`, data and BSS in their own sections, as
   FMutate's native/build_ios.sh does).
   Generic shims (tried when a plain build fails): `shims/include` (ELF section names on Mach-O, emscripten.h).
   Per-firmware patches: `patches/<id>/*.patch` (none so far).
5. **Check** (`verify.py`): the cartridge in libfm1engine.so and the Hub package in libfm1emu.so (JIT, 240 MHz), same
   script on firmware time (boot 4 s, a chord, PLAY): audio level, 1/3-octave spectrum, the screens at three points.
   Verdicts (`report.py`): match / silent (neither sounds; screens equal) / diverges / no-ref / broken. The Dinghy
   line's native level is its USB level, +6 dB over the emulator's DAC (`o[i] <<= 7`: Q15 at −6 dBFS); expected.
   `emu_seed.json` gives the emulator what a firmware's installer writes besides the package (Melodee's factory
   sounds), so the reference is what a user's FM-1 runs.
6. **Publish** (`plan.py`, `publish.py`, `ci/cartridges.yml`): GitHub Actions, one job per firmware (Linux: host
   check + Android ABIs; macOS: iOS), daily diff against the published index plus workflow_dispatch. Only `match` and
   `silent` (or a reviewed `overrides.json` "accept") are published; the rest go to the index's `tried` list.

## Results so far (host, 213 firmwares)

| clean | generic shims | per-firmware patch | failed |
|---|---|---|---|
| 108 | 33 | 5 (1–19 lines each) | 67 (no recipe 56, compile 7, record 4) |

Checks of the 146 built: match 93, silent 10 (neither sounds from a chord or PLAY; screens equal), diverges 31,
no-ref 11 (emulator silent/missing package), broken 1. Divergences explained so far: the firmware's own randomness
(arcturus), the chord's three keys arriving in one pass vs the emulator's matrix scan (bytemania, drumtonic), Hub
packages missing what their installers write (carnac waves, choralroot presets). Must-haves: Melodee, Skiff,
OberVave, Dinghy, GR!MM, Frasil **match**; **Clipper and Sloop not built** (Felucca forks without a browser build:
need a host model of the Felucca HAL, designed in agent://NativeCatalog.FeluccaHarness, not written); JIANT diverges.
Can't build without more work: no source (mycelium, bb1), unpinned dependencies fetched at build time (atek303,
assid, kitten, manifold, fm1sid), firmwares on the bare HAL with no host layer (b1, beetle, beetleblue, etch, Felucca
forks), others in tools/native_catalog/causes/.

## The index (schema 1)

`https://genericjam.github.io/fmutate-cartridges/index.json`, with `index.json.sig` = base64 of the Ed25519 signature
over the exact bytes. Public key (base64, raw 32 bytes): `PlTQbGPmAqukMY78jvsMLR6BBxPQAa2E3T77ofuv8h8=`; the private
key lives only in the Actions secret `CARTRIDGE_SIGNING_KEY` (PEM).

```json
{"schema": 1, "generated": "…Z", "engine_abi": 1, "hub_updated": "2026-11-14",
 "firmwares": [{"id", "name", "version", "repo", "commit", "pin", "license", "recipe", "build", "patches",
   "parity": {"status", "level_diff_db", "spectrum_corr", "screen_diff", "notes"}, "added", "updated",
   "assets": {"android-arm64-v8a": {"url", "sha256", "size", "sig"}, "android-x86_64": {…}, "android-armeabi-v7a": {…},
              "ios-device": {…}, "ios-sim": {…}}}],
 "tried": [{"id", "version", "repo", "commit", "pin", "check", "reason", "date"}]}
```

A reader refuses an index whose signature, schema or engine_abi doesn't check, and keeps a cartridge only when its
size, SHA-256 and own `sig` (Ed25519 over the file) check. `engine_abi` 1 = the `fm1c_*` calls of
native/engine/live.c.

## Packaging

- **Android**: download per firmware on demand (dlopen from the app's files dir; only exec() is barred there).
  Cartridges are 0.6–1.8 MB each per ABI (~0.7 MB average): all of them bundled would add ~140 MB per ABI, so
  bundling is for a short list Kevin picks; both stay possible (`assets` per ABI).
- **iOS**: no downloaded native code. The app build pulls the `ios-*` static libraries it links; a firmware not
  linked into the installed app plays emulated with "Plays emulated on iPhone until the next app update".

## Still the emulator

Imports (stock M-VAVE firmware, any `.fwsc`), firmwares not built or not passing the check, and the Hub package of a
native firmware (`hub:<id>`, to compare). The library card says Native or Emulated.

## Needs Kevin

- Licences: GPL-3.0 (184 entries incl. -only/+exception) — the cartridges are GPL binaries: the release notes link
  each pinned source commit (the written offer is covered by the pinned public commit; keep the fmutate-cartridges
  repo public). MPL-2.0 (23) and MIT (2): fine with notices. Two entries have no licence (emb, vesper): not
  redistributable without the author's permission — skip in `overrides.json` until they say yes.
- Android: bundle list vs download only (app size above).
- Play Store policy forbids downloading native code; FMutate ships as an APK from GitHub releases today.

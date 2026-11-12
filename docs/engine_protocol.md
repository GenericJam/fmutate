# Engine protocol (tech spec)

How the app runs a firmware. Prototyped and measured in `../fmutate_spike` (desktop); this is the Android
version. When this file and the design handoff disagree on how something works, this file wins.

```
Elixir (BEAM, app process) ──Port──▶ libfm1engine.so <cart> <prefix> <flash> [fill]   (own OS process)
        │                                   │ dlopen
        │                                   ├─ libcart_<firmware>.so   the firmware, on its authors' fake FM-1
        │                                   ├─▶ <prefix>.ring          audio, int16 stereo, 44.1 kHz
        │                                   └─▶ <prefix>.fb            screen RGB565 + LEDs
        ├── fm1audio NIF (AAudio stream, app process) ◀── reads rings, writes clock fields back
        └── instrument view (Kotlin) ◀── reads <prefix>.fb at display rate
```

- **One OS process per running firmware.** A crash, hang or `exit()` in firmware code ends that process
  only; the BEAM sees a port exit and restarts it. Swapping firmware = start the new engine, crossfade in
  the mixer, close the old port.
- **Executables in the APK** have to be named `lib*.so` to be extracted to the native library dir (the
  only place an app may exec from): `libfm1engine.so` is a PIE executable. Cartridges are
  `libcart_<id>.so` beside it. `MOB_NATIVE_LIB_DIR` gives the directory. The emulator engine `libfm1emu.so`
  (below) is a second executable with the same protocol.
- Shared files live in `$MOB_DATA_DIR/run/` (app-private). The engine unlinks and recreates them on start
  so readers still mapping a previous engine's files keep valid (old) pages instead of SIGBUS.
- Flash (the firmware's saved settings and patches): `$MOB_DATA_DIR/flash/<instance>/<firmware>.bin`,
  loaded before boot, rewritten atomically whenever the firmware saves.

## Port messages (`{:packet, 2}`, one opcode byte, big-endian fields)

Elixir → engine:

| Op | Payload | Meaning |
|---|---|---|
| `0x01` | `key:u8 down:u8` | key 0..26 (0 = F3 … 26 = G5); FM-1 keys carry no velocity |
| `0x02` | `button:u8 down:u8` | 0 oct_down 1 oct_up 2 fx 3 sel 4 env 5 lfo 6 edit 7 glo 8 home 9 save 10 arp 11 seq 12 play 13 rec |
| `0x03` | `enc:u8 clicks:i8` | 0 select 1 algorithm 2-5 knob1-4 6 presets; + = clockwise |
| `0x04` | `status:u8 d1:u8 d2:u8` | MIDI into the firmware's MIDI in, now |
| `0x05` | `master:u16` | MASTER pot 0..1024 (1024 = unity) |
| `0x06` | `frame:u64 status:u8 d1:u8 d2:u8` | MIDI at mixer frame `frame` (see the clock below); delivered half a firmware block early so notes land on the nearest 256-frame block (desktop: −1.7…+3.6 ms) |
| `0x07` | `fill:u16` | target ring fill in frames, from now on (as the `[fill]` argument; clamped to 512..3840). Lowering it plays out what is queued; raising it renders ahead. Both engines |
| `0x10` | – | debug: crash (SIGSEGV in the firmware thread) |
| `0x11` | – | debug: hang (the firmware loop stops yielding) |

Engine → Elixir:

| Op | Payload | Meaning |
|---|---|---|
| `0x81` | `ms:u32` | READY |
| `0x82` | `ms:u32 fill:u32 fb_seq:u32 led_buttons:u32 led_keys:u32 glow_keys:u32` | STATUS every 100 ms of wall time. No STATUS for 1 s = hung: kill -9. `ms` against wall time is the firmware's speed, `fill` the ring's fill when sent |
| `0x84` | `bytes:u32` | FLASH_SAVED |

## `<prefix>.ring` (little-endian)

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | magic `0x464D3152` |
| 4 | u32 | capacity (4096 frames) |
| 8 | u32 | rate (44100) |
| 16 | u64 | write index (engine) |
| 24 | u64 | read index (mixer) |
| 32 | i64 | `mix_minus_r`: mixer frame at which ring index `r` plays, minus `r` (mixer) |
| 40 | u32 | `mix_valid` (mixer, 1 once attached) |
| 64 | i16[4096 × 2] | interleaved stereo |

## `<prefix>.fb` (little-endian)

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | magic `0x464D3146` |
| 4 | u32 | seq, bumped after each new frame |
| 8 | u16[240 × 240] | RGB565 (Android `Bitmap.Config.RGB_565` order), row-major |
| 115208 | u32 | button LEDs (bit n = button n) |
| 115212 | u32 | key LEDs (bit n = key n) |
| 115216 | u32 | key glow (the firmware's dim LED layer) |
| 115220 | u32 | firmware ms (written last) |

## The emulator engine (`libfm1emu.so`)

`libfm1emu.so <package.fwsc> <prefix> <flash> [fill]` runs any FM-1 firmware from its update package (the
`.fwsc` a real FM-1 installs) in [fm1-emu](https://github.com/joakimeriksson/fm1-emu) (MIT; both CPU cores, the
SoC, the screen, the panel matrix, the DAC), with everything above unchanged: arguments, port messages, ring,
`.fb`, pacing on the ring fill, STATUS, the watchdog's view of it. Source: `native/emu/` (Rust), fm1-emu pinned in
`native/build_emu.sh`, patches in `native/patches/fm1-emu/`. `FMutate.Firmware` picks it for `backend: :emu`.

What differs inside:

- **Panel**: keys go to fm1-emu's matrix ids 14 + key, buttons to the same numbers (fm1-emu's ids 0..13 are the
  wire's order), encoders the same numbers; MASTER 0..1024 sets the pot's ADC (channel 4) to 0..1023 and the
  firmware applies its own curve. MASTER is at unity until set, as in the native engine.
- **MIDI** goes in byte by byte through the emulated MIDI IN jack (a message's own length: a program change is
  two bytes). Timed MIDI is delivered when the emulator's output reaches the frame (less `MIDI_LEAD`), so it lands
  within a DMA half of the firmware's.
- **Audio** is what the firmware's DMA plays, at the DAC's 44117.6 Hz (fm1-emu's clock; written into a 44100 ring:
  0.04 % slow, inaudible). Where the firmware plays nothing (booting, or not at all) for more than 4096 frames of
  firmware time, silence stands in, so the ring and the clock still advance.
- **LEDs**: fm1-emu reports each LED's on-time over the multiplexed matrix (fully lit ≈ 1/11 of the time).
  ≥ half of that is lit (`led_buttons`, `led_keys`); more than 1/16 and less than half is the dim layer
  (`glow_keys`). Taken over at least 5 ms of firmware time.
- **Flash file**: the sectors the firmware changed against the package's own flash, as records of a 4-byte
  little-endian offset and the 4096-byte sector (fm1-emu's web saves' format; empty = nothing changed). Written
  when the flash has been quiet for 250 ms after a write (`FLASH_SAVED` = the file's size) and when the port
  closes. A file that isn't whole records is ignored (the package's flash is used, and replaced at the next save).
- **Exits**: a package that isn't an FM-1 update package (or is an SMK-37 one) exits 2 before READY; a firmware
  the emulator halts (it would have locked up a real FM-1) exits 3. Debug crash raises SIGSEGV, debug hang spins,
  as in the native engine.
- **Knobs** (environment; development): `FM1_NO_JIT=1` interprets instead of compiling to native code;
  `FM1_MHZ=N` clocks the CPU at N MHz instead of 240 (cheaper for firmwares that burn cycles waiting).
  `libfm1emu.so --bench <package> [seconds] [key …]` runs a package flat out with a chord held and prints its speed.

fm1-core compiles the firmware to native code on arm64 and x86_64 (x86_64 Android by our patch); armeabi-v7a only
interprets.

## The clock

The mixer (`c_src/fm1audio.c`) counts `frame`: frames mixed at 44.1 kHz since the stream started. The
device may run at another rate; the mixer resamples. Timed MIDI (`0x06`) and, later, sibling apps'
`midi_at` use this clock; `FMutate.Audio.stats/0` reports it.

## Speed and fill (`FMutate.Instance.Health`)

The instance judges its live engine from STATUS (`ms`) and `FMutate.Audio.stats/0` (`underruns` of its slot), over
windows of ≥ 1 s of wall time; the first two windows after READY are warm-up. Nothing is judged while the
output isn't running (firmware time stands still then).

| What | Rule |
|---|---|
| Speed (`clock_pct` in the view) | firmware ms per wall ms × 100, whole percent; the shown value moves when the measurement moves ≥ 2 points |
| Too slow (`slow`) | on after 3 windows in a row < 95 %; off after 3 in a row ≥ 98 % (in between keeps the state) |
| Auto fill (buffer `:auto`) | starts at `FMutate.Audio.engine_fill/0` (a crash restart keeps what the last engine reached). Underruns grew in 2 of the last 5 windows: +512 frames (op `0x07`), up to 3840, then 5 fresh windows judge again. 60 s without underruns: −512, not below the default; a step down that brings underruns back within 60 s is undone and stays the floor for that engine. Not saved: a new engine starts from the default |
| Fixed buffer | the I/O screen's choice (2048 / 3072 / 3840 frames), saved with the instance; set on the running engine at once |

More fill only absorbs jitter: an engine slower than real time underruns at any fill, so auto fill climbs to the
maximum and the instrument shows "Too slow" (with the speed) and points at the buffer in I/O.

## Measured

| Where | What |
|---|---|
| Moto G Power 2021 (SD662, Android 11) | OberVave holding a 3-note chord: 34 % of one core; no underruns, no xruns |
| Emulator (Android 17, x86_64, 16 KB pages) | Port spawn, AAudio playback, clock at 44.1 kHz |
| `libfm1emu.so`, x86-64 desktop (`--bench`, JIT) | Dinghy 4.5x real time (22 % of one core), OberVave's package 3.6x (28 %); interpreted 0.5x / 0.7x |
| `libfm1emu.so` in the app, emulator above (4 vCPUs) | Dinghy 31–33 % of one core; OberVave's package 37 % idle, 61 % with a 3-note chord; a few underruns while an engine starts (2–10; the native engine 2), none after |
| `libfm1emu.so` arm64, Moto G Power 2021 (`--bench` from `/data/local/tmp`) | Dinghy 1.1x real time (91 % of one core); OberVave's package 0.78–0.85x: **slower than real time** at the FM-1's 240 MHz; 1.39x (72 %) at `FM1_MHZ=120`, 1.70x at 80, same audio peak. Little cores: 0.31x. armeabi-v7a (interpreter): 0.11x |

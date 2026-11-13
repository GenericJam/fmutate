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
- Flash (the firmware's saved settings and patches): `$MOB_DATA_DIR/flash/<instance>/<firmware>.bin` for a
  native cartridge, `$MOB_DATA_DIR/flash/<instance>/emu/<firmware>.bin` for a package in the emulator engine
  (`FMutate.Paths.flash/3`; the two formats differ, so a firmware id never shares a file across backends).
  Loaded before boot, rewritten atomically whenever the firmware saves.

## Port messages (`{:packet, 2}`, one opcode byte, big-endian fields)

Elixir → engine:

| Op | Payload | Meaning |
|---|---|---|
| `0x01` | `key:u8 down:u8` | key 0..26 (0 = F3 … 26 = G5); FM-1 keys carry no velocity. Spaced per key (panel edges, below) |
| `0x02` | `button:u8 down:u8` | 0 oct_down 1 oct_up 2 fx 3 sel 4 env 5 lfo 6 edit 7 glo 8 home 9 save 10 arp 11 seq 12 play 13 rec. Spaced per button (panel edges, below) |
| `0x03` | `enc:u8 clicks:i8` | 0 select 1 algorithm 2-5 knob1-4 6 presets; + = clockwise |
| `0x04` | `status:u8 d1:u8 d2:u8` | MIDI into the firmware's MIDI in, now |
| `0x05` | `master:u16` | MASTER pot 0..1024 (1024 = unity) |
| `0x06` | `frame:u64 status:u8 d1:u8 d2:u8` | MIDI at mixer frame `frame` (see the clock below); delivered half a firmware block early so notes land on the nearest 256-frame block (desktop: −1.7…+3.6 ms) |
| `0x07` | `fill:u16` | target ring fill in frames, from now on (as the `[fill]` argument; clamped to 512..3840). Lowering it plays out what is queued; raising it renders ahead. Both engines |
| `0x08` | `mhz:u16` | the emulated CPU's clock, from now on (clamped to 20..240; 240 = the FM-1's). Emulator engine only (below) |
| `0x10` | – | debug: crash (SIGSEGV in the firmware thread) |
| `0x11` | – | debug: hang (the firmware loop stops yielding) |

Engine → Elixir:

| Op | Payload | Meaning |
|---|---|---|
| `0x81` | `ms:u32` | READY |
| `0x82` | `ms:u32 fill:u32 fb_seq:u32 led_buttons:u32 led_keys:u32 glow_keys:u32` [`mhz:u16 stale:u32 cpu_ms:u32`] | STATUS every 100 ms of wall time. No STATUS for 1 s = hung: kill -9. `ms` against wall time is the firmware's speed, `fill` the ring's fill when sent. The emulator engine adds its CPU clock, the DMA halves its firmware left stale so far and the process's CPU time so far (ms) |
| `0x84` | `bytes:u32` | FLASH_SAVED |

### Panel edges (`0x01`, `0x02`)

The engine reads whatever port messages have arrived at once, so a press and its release (a quick tap, a busy
phone, a slow firmware) can reach it together, between two of the firmware's looks at its panel; applied as they
come, the firmware would never see the press. Both engines therefore queue each key's and each button's edges in
order and put each on the panel only once that input's previous edge has been there for **16 ms of firmware time**
(the native engine counts the firmware's main-loop passes, one per millisecond; the emulator engine the emulated
CPU clock), so a slow engine spaces them as a fast one does. An edge with nothing queued before it, on an input
steady for 16 ms, is applied at once: no added latency. Inputs are independent: OCT− and OCT+ tapped together
are down in the same scan (OberVave's and Shine On's "both: octave 0"). An edge that doesn't change the state the
input is heading to is dropped; past 32 queued edges on one input, a new one cancels the last one queued (the
state still ends where the port left it).

Why 16 ms: the firmwares debounce their own matrix (`hal/fm1_input.h`, Felucca's): a press counts after
`FM1_DEB_PRESS` (2) frames of the 11-column scan (~1.1 ms a frame) closed, a release after `FM1_DEB_RELEASE` (8)
frames open, up to ~10 ms with the scan's phase. In the emulator engine the firmware runs that scan on fm1-emu's
matrix, which shows a key exactly from its press to its release (`fm1-soc` `periph.rs`), so a release shorter than
that is never seen and a quick second tap merges with the first. The native cartridges read `fm1_in` every pass,
and 16 passes give each edge what the device gives it (a debounced key is down ≥ ~9 ms however short the touch).
16 ms leaves a margin over both and is shorter than any human double tap. Code: `native/engine/live.c` (in the
cartridge, before each pass; it replaces the cartridge's old tap latch for buttons) and `native/emu/src/edges.rs`.

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
`native/build_emu.sh` (local changes to it would be patches in `native/patches/fm1-emu/`; none at present: FMutate's
one, the JIT on x86-64 Android, is upstream as fm1-emu #171). `FMutate.Firmware` picks it for `backend: :emu`.

What differs inside:

- **Panel**: keys go to fm1-emu's matrix ids 14 + key, buttons to the same numbers (fm1-emu's ids 0..13 are the
  wire's order), spaced as above (between emulator slices, on the emulated clock); encoders the same numbers;
  MASTER 0..1024 sets the pot's ADC (channel 4) to 0..1023 and the firmware applies its own curve. MASTER is at
  unity until set, as in the native engine.
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
  It lives under `flash/<instance>/emu/` (above): a native cartridge's flash of the same id is a whole image.
- **Exits**: a package that isn't an FM-1 update package (or is an SMK-37 one) exits 2 before READY; a firmware
  the emulator halts (it would have locked up a real FM-1) exits 3. Debug crash raises SIGSEGV, debug hang spins,
  as in the native engine.
- **The CPU clock** (op `0x08`, `FM1_MHZ` at start): fm1-soc counts time in CPU cycles at `Periph::hz` (240 MHz)
  and converts them for every timer, the DAC, the OS tick and the firmware's milliseconds (`periph.rs`:
  `ms()`, `audio_frames_at`, `half_period`, `t5_period`, …); one instruction is one cycle (`Soc::add_ticks`,
  `Periph::tick`). Changing `hz` while running would rescale none of the deadlines already scheduled
  (`alnk_next`, `t5_next`, `tick_next`, the UART's, the watchdog's are absolute cycles), which is why fm1-emu's
  own plugin reboots the machine for a new clock (`fm1-plugin` `engine.rs`). So the engine leaves `hz` at 240 MHz
  and stalls the CPU instead (`native/emu/src/machine.rs` `Machine::run`): below 240 MHz, each instruction
  owes (240 − mhz) / mhz ticks in which both cores stand still, paid between runs of the cores (at least 2048
  instructions, as many as fit before the SoC's next timed event with their stalls) and never past that event,
  as fm1-soc's own idle skip (`skip_idle`) jumps; time the firmware spent idling (TIMER4 polling, polling loops
  skipped: `Periph::skipped`, `LoopSkip::skipped`) owes nothing. The firmware gets mhz million instructions per
  second of its time; its time, timers and audio stay right, nothing restarts, and the op takes effect at once.
  No fm1-emu change. Measured (`--bench`, x86-64 desktop, OberVave's package with a chord): 240 MHz 3.7x real
  time, 180 4.0x, 120 4.8–5.1x (as fast as a 120 MHz `Periph::hz`), 80 7.1x.
- **Stale DMA halves** (`stale` in STATUS): the DAC plays the firmware's buffer in two halves, and the firmware
  refills each while the other plays. A half that plays again exactly as it played last time (and isn't
  quiet: its samples span ≥ 512) is one the firmware didn't refill in time: on a real FM-1 a glitch, here the
  sign of a clock too slow for the firmware. OberVave's package with a 3-note chord: none at 240, 180 or 120 MHz,
  ~43 a second at 80 MHz (its audio peak unchanged, so the peak alone doesn't show it); silent at 60 MHz.
- **Knobs** (environment; development): `FM1_NO_JIT=1` interprets instead of compiling to native code (on this
  computer a slow phone's speed: Dinghy 0.65x real time at 240 MHz, 1.8x at 80); `FM1_MHZ=N` starts the CPU at
  N MHz instead of 240. `FMutate.Engine`'s `:env` passes them; the app's `:emu_env` (`Application.put_env(:fmutate_app,
  :emu_env, [{"FM1_NO_JIT", "1"}])` over `tools/rpc.exs`) applies to the next emulator engine an instance starts.
  `libfm1emu.so --bench <package> [seconds] [key …]` runs a package flat out with a chord held and prints its
  speed, its stale halves and the instructions run per second.

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
| Auto fill (buffer `:auto`) | starts at `FMutate.Audio.engine_fill/0` (a crash restart keeps what the last engine reached). Underruns grew in 2 of the last 5 windows (and the engine isn't too slow): +512 frames (op `0x07`), up to 3840, then 5 fresh windows judge again. 60 s without underruns: −512, not below the default; a step down that brings underruns back within 60 s is undone and stays the floor for that engine. Not saved: a new engine starts from the default |
| Fixed buffer | the I/O screen's choice (2048 / 3072 / 3840 frames), saved with the instance; set on the running engine at once |
| Emulated CPU, Auto (emulator engine) | starts at the clock kept for the firmware (240 the first time). Too slow (3 windows in a row < 95 %): one step down 240 → 180 → 120 → 80 MHz (op `0x08`), never below 80 or the firmware's floor; 2 windows settle after each change, so the next step comes 3 windows after the last. The firmware's audio starving (`stale` grew by ≥ 2 in a window): one step back up, and that clock becomes the firmware's floor. 60 s after the last change, not too slow, and the engine's CPU use × next clock / clock ≤ 70 % of a core: one step up is tried; a try that turns out too slow is undone and is this engine's ceiling. The clock, its mode and the floor are saved per firmware with the instance (`cpu`) |
| Emulated CPU, fixed | the I/O screen's 240 / 180 / 120 / 80 MHz, saved per firmware; set on the running engine at once |

More fill only absorbs jitter: an engine slower than real time underruns at any fill (measured: OberVave's package
at 81–84 % underran ~66/s at 1024 frames and ~60/s at 3840), so auto fill holds while the engine is too slow, and
the instrument says what is true (`FMutate.Instance.Health.advice/1`): "Too slow · N % speed" with "Slowing the
emulated CPU · N MHz…" while auto steps down, "Lower the emulated CPU in I/O" on a fixed clock that could go lower,
"This phone can't run it in real time" when nothing is left (a native engine, or the floor). "Raise the buffer in
I/O" (under "Audio dropouts") only for an engine fast enough that underruns on a fixed buffer below the largest.

## Measured

| Where | What |
|---|---|
| Moto G Power 2021 (SD662, Android 11) | OberVave holding a 3-note chord: 34 % of one core; no underruns, no xruns |
| Emulator (Android 17, x86_64, 16 KB pages) | Port spawn, AAudio playback, clock at 44.1 kHz |
| `libfm1emu.so`, x86-64 desktop (`--bench`, JIT) | Dinghy 4.5x real time (22 % of one core), OberVave's package 3.6x (28 %); interpreted 0.5x / 0.7x |
| `libfm1emu.so` in the app, emulator above (4 vCPUs) | Dinghy 31–33 % of one core; OberVave's package 37 % idle, 61 % with a 3-note chord; a few underruns while an engine starts (2–10; the native engine 2), none after |
| `libfm1emu.so` arm64, Moto G Power 2021 (`--bench` from `/data/local/tmp`) | Dinghy 1.1x real time (91 % of one core); OberVave's package 0.78–0.85x: **slower than real time** at the FM-1's 240 MHz; 1.39x (72 %) at `FM1_MHZ=120`, 1.70x at 80, same audio peak. Little cores: 0.31x. armeabi-v7a (interpreter): 0.11x |

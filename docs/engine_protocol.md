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
  `libcart_<id>.so` beside it. `MOB_NATIVE_LIB_DIR` gives the directory.
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
| `0x10` | – | debug: crash (SIGSEGV in the firmware thread) |
| `0x11` | – | debug: hang (the firmware loop stops yielding) |

Engine → Elixir:

| Op | Payload | Meaning |
|---|---|---|
| `0x81` | `ms:u32` | READY |
| `0x82` | `ms:u32 fill:u32 fb_seq:u32 led_buttons:u32 led_keys:u32 glow_keys:u32` | STATUS every 100 ms of wall time. No STATUS for 1 s = hung: kill -9 |
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

## The clock

The mixer (`c_src/fm1audio.c`) counts `frame`: frames mixed at 44.1 kHz since the stream started. The
device may run at another rate; the mixer resamples. Timed MIDI (`0x06`) and, later, sibling apps'
`midi_at` use this clock; `FMutate.Audio.stats/0` reports it.

## Measured

| Where | What |
|---|---|
| Moto G Power 2021 (SD662, Android 11) | OberVave holding a 3-note chord: 34 % of one core; no underruns, no xruns |
| Emulator (Android 17, x86_64, 16 KB pages) | Port spawn, AAudio playback, clock at 44.1 kHz |

# FMutate

FMutate runs the community firmwares of the **M-VAVE FM-1** pocket synthesizer on an Android phone, and lets you
rearrange the instrument around them. The firmware is the real thing (its own code, screen, sounds and saves);
the panel is yours: a classic FM-1 layout to start, then any arrangement of keys, knobs, pads, sliders and pages
you like.

It is built with [Mob](https://github.com/GenericJam/mob) (Elixir on the phone, native Compose views), and it is
early: Android, as a sideloaded APK or built from source (an iOS port is in testing).

<p align="center">
  <img src="docs/media/instrument.png" width="720" alt="The classic layout on a phone: the firmware's screen, knobs, buttons and the 27 keys">
  &nbsp;
  <img src="docs/media/library.png" width="190" alt="The firmware library with the FM-1 Firmware Hub catalogue">
</p>

## What it does

- **Runs FM-1 firmwares** in two ways:
  - **Native cartridges**: firmwares built from source for the phone, fast and sample-exact. This build ships
    [OberVave](https://github.com/zvenson/obervave) 3.3.2 and [Shine On](https://github.com/zvenson/shineon) 3.0.1.
  - **The emulator**: any firmware's own update package (`.fwsc`) runs in
    [fm1-emu](https://github.com/joakimeriksson/fm1-emu), including binary-only ones.
- **A firmware library**: the [FM-1 Firmware Hub](https://thefirmwarehub.com/) catalogue (download, check,
  delete), import of your own `.fwsc` files (stock M-VAVE firmware is bring-your-own), one-tap switching with
  undo. A firmware that crashes twice in a minute is quarantined until you choose "Run anyway".
- **A playable surface**: multitouch where every finger owns the control it touched, glissando, knobs that never
  jump, fine mode, a firmware screen drawn as large as it fits and kept sharp.
  - **Velocity** from where you strike a key (front loud, back soft), on by default; it plays the synth over MIDI
    channel 1, so keep the synth's MIDI channel on OMNI (its default) or 1. A strip can play the firmware's own
    fixed-velocity key presses instead, on any channel.
  - **Note level**: with FMutate's OberVave, a held note's volume follows your finger: slide back from where you
    struck to fade it, forward to bring it back. On by default; switch it from a button on the surface (bind it to
    "note level on/off") or in the keyboard strip's settings.
  - **Bend** a held note by sliding sideways, and a long-release **sustain**.
- **Your own layouts**, edited in place: drag, resize, add controls, pages, bindings to firmware inputs, MIDI notes
  and CCs, portrait or landscape. Saved per firmware.
- **I/O**: low-latency audio (AAudio), a virtual MIDI port `FMutate A`, USB and Bluetooth MIDI devices, MIDI clock
  in and out.
- **Plays in the background**: while a firmware plays, the notification "FMutate is playing" keeps it running
  with the screen off or another app in front. Its **Quit** button stops the firmware (its settings saved) and
  ends FMutate.
- **MIDI controllers**: an MPK mini's knobs and pads drive the FM-1's knobs and buttons out of the box (automap,
  any of the mk2's factory programs; other controllers by the order you touch them). I/O shows what each knob
  drives as you turn it, lines up your knobs one by one ("turn the knob you want for KNOB1"), pins a knob to a
  synth parameter by name (OberVave, Shine On), and says what an unmapped knob does to the synth. Any hardware
  knob, fader, pad or key can also be learned onto a control in the layout editor.
- **Sibling apps** (planned separately: a pattern sequencer, voice control, …) drive FMutate over Erlang
  distribution, after you allow them ([docs/design/protocol.md](docs/design/protocol.md)).

Tested on a Moto G Power 2021 (Android 11), a Moto G Power 5G 2024 and Android 17 emulators.

## How it works

```mermaid
flowchart LR
  subgraph app["App process (BEAM, Mob)"]
    I["FMutate.Instance<br/>firmware, health, inputs"]
    A["FMutate.Audio<br/>AAudio mixer NIF"]
    V["Instrument view<br/>Kotlin / Compose"]
  end
  I -- "Port" --> E["Engine process<br/>libfm1engine.so + cartridge<br/>or libfm1emu.so + .fwsc"]
  E -- "audio ring (shared memory)" --> A
  E -- "screen + LEDs (shared memory)" --> V
  V -- "touch events" --> I
```

Each firmware runs in its own OS process, so a crash, a hang or an exit ends only that process; the instance
restarts it. Audio and the screen never pass through the BEAM: the engine writes shared memory that the mixer and
the view read directly. Details: [docs/architecture.md](docs/architecture.md) and
[docs/engine_protocol.md](docs/engine_protocol.md). The design (screens, layout model, touch rules, the Opling
creature) is in [docs/design/](docs/design/HANDOFF.md).

## Installing

Download [`FMutate.apk`](https://github.com/GenericJam/fmutate/releases/latest/download/FMutate.apk) (always the
latest release; each [release](https://github.com/GenericJam/fmutate/releases) also has it as
`fmutate-<version>.apk`) and open it on the phone (allow installs from your browser or file manager when Android
asks), or from a computer: `adb install FMutate.apk`.

- Android 9 or newer; arm64 phones (most), 32-bit ARM, and x86-64. On 32-bit ARM the built-in firmwares and the
  native builds of Hub firmwares play, but a Hub package that only runs in the emulator doesn't (the emulator
  needs 64-bit).
- Releases are signed with FMutate's release key, so a later release installs over an earlier one and keeps your
  layouts and saves. A copy built from source is signed with your own debug key: Android won't install a release
  over it (or the other way round) until the other is uninstalled, which deletes its data.
- 0.2.0 changed the release key: if you installed 0.1.0, uninstall it first (that deletes its layouts and saves).
- Downloaded firmwares come from the [FM-1 Firmware Hub](https://thefirmwarehub.com/) and their native builds
  from [fmutate-cartridges](https://github.com/GenericJam/fmutate-cartridges), so the Library needs the internet;
  the instrument itself doesn't.

## Building

You need Linux or macOS with:

- [mise](https://mise.jdx.dev) (it installs the pinned Erlang 29, Elixir 1.20, Java 17, Zig 0.17 and Rust from
  `.tool-versions`: `mise install`)
- the Android SDK with NDK 27.2 (`~/Android/Sdk/ndk/27.2.12479018`, or set `ANDROID_NDK_HOME`) and `adb`
- a phone with USB debugging on, or an emulator

```sh
mise install
mise exec -- mix deps.get
mise exec -- rustup target add aarch64-linux-android x86_64-linux-android

# native parts: the engine and cartridges per ABI, the same for this computer (tests), the emulator engine
sh native/build_android.sh
sh native/build_host.sh
mise exec -- sh native/build_emu.sh

mise exec -- mix test

# build, install and start on a device (serial from `adb devices`)
mise exec -- mix mob.deploy --native --android --device <serial>
```

The firmware sources and fm1-emu are fetched at pinned commits into `native/build/` (git-ignored), with
FMutate's patches from `native/patches/` applied.

## Repository

| Path | What |
|---|---|
| `lib/fmutate/` | the app: instances, engines, audio, library, layouts and editor, MIDI, distribution, screens |
| `android/app/src/main/java/com/example/fmutate_app/fmutate/` | the native instrument surface (Compose), edit mode, the Opling, MIDI and I/O bridges |
| `c_src/` | the AAudio mixer and I/O NIFs |
| `native/engine/` | the engine executable and cartridge harness (C) |
| `native/emu/` | the emulator engine around fm1-emu (Rust) |
| `native/patches/` | FMutate's patches to the firmwares it builds (OberVave) |
| `priv/layouts/` | the preset layouts; `priv/layout.schema.json` is their format |
| `docs/` | architecture, engine protocol, design handoff |
| `tools/` | `rpc.exs` (evaluate Elixir in the running app), a sibling-app probe, MIDI latency measurement |

Working on the code (with or without an AI agent): [AGENTS.md](AGENTS.md).

## Licence and credits

FMutate's original app code is licensed under the **MIT License** ([LICENSE](LICENSE)). The GPL components
listed below are exceptions, not relicensed by that file. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for the source boundary, pinned upstream sources and redistribution requirements.

- [OberVave](https://github.com/zvenson/obervave) and [Shine On](https://github.com/zvenson/shineon) by zvenson
  and their upstream contributors remain **GPL-3.0-only**, as do the derivative cartridge harness
  `native/engine/live.c` and the OberVave patches in `native/patches/obervave/`. FMutate patches OberVave to
  take MIDI polyphonic aftertouch as a note's level.
- [fm1-emu](https://github.com/joakimeriksson/fm1-emu) by Joakim Eriksson (MIT).
- The firmware list comes from the [FM-1 Firmware Hub](https://thefirmwarehub.com/) (CC BY 4.0; card texts and
  pictures belong to each firmware's maker). Every firmware belongs to its author and is downloaded from where
  they publish it.

The native build compiles GPL firmware into cartridges and dynamically loads them into the engine. Distributing
those cartridges or a GPL-covered combined work requires GPL compliance, including corresponding source and
notices; the shipped APK is **not MIT-only**. The app uses a separate engine process with Port/shared-memory
communication, but that technical separation is not a blanket exemption from GPL obligations. The MIT grant for
FMutate-owned code remains available independently.

FMutate is not affiliated with or endorsed by M-VAVE. "FM-1" names the hardware the firmwares are written for.

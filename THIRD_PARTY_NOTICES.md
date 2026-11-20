# Licensing scope and third-party notices

## FMutate-owned code: MIT

The root [LICENSE](LICENSE) grants the MIT License for original FMutate code, copyright (c) 2026 GenericJam.
This includes FMutate's Elixir app, instrument views, mixer/I/O code, build scripts, original presets and docs,
`native/engine/fm1engine.c`, and the Rust wrapper in `native/emu/`, except for third-party or derivative material
identified below or by its own notices. It does not replace any upstream copyright, attribution or licence.

`native/emu/src/machine.rs` adapts code from fm1-emu (its package boot, stepping and flash-sector diff follow
fm1-emu's `crates/fm1-plugin/src/engine.rs` and `crates/fm1-live/src/main.rs`): those parts are copyright (c) 2026
Joakim Eriksson under the MIT licence in [LICENSES/fm1-emu-MIT.txt](LICENSES/fm1-emu-MIT.txt), which must
accompany them.

## GPL firmware and derivative code

The following are **GPL-3.0-only**, not covered by FMutate's MIT grant:

| Component | Source used by this checkout |
|---|---|
| OberVave 3.3.2 | [zvenson/obervave at `792535d23ef4265475b1c2f9895ca30e857fe596`](https://github.com/zvenson/obervave/tree/792535d23ef4265475b1c2f9895ca30e857fe596) |
| Shine On 3.0.1 | [zvenson/shineon at `2f37738d690a628e0ae1d23d07ea5ee3eeda2de7`](https://github.com/zvenson/shineon/tree/2f37738d690a628e0ae1d23d07ea5ee3eeda2de7) |
| `native/engine/live.c` | Cartridge harness; copies and adapts the simulator's `web/sim/sim.c` (copyright (C) 2026 zvenson) and runs on the firmwares' `tests/host.c` platform; modified by GenericJam from 2026-11-10 |
| `native/patches/obervave/host-build-without-mirror.patch` | Changes to OberVave's host build |
| `native/patches/obervave/poly-aftertouch.patch` | Changes to OberVave's MIDI handling and synth engine |

The GPL v3 text previously at the repository root is preserved unchanged in
[LICENSES/GPL-3.0-only.txt](LICENSES/GPL-3.0-only.txt). The patches and the firmware sources they modify remain
GPL-licensed; the root MIT licence does not relicense their upstream content.

The synths and simulator are copyright (C) 2026 zvenson. Their platform includes work copyright (C) 2026
Leo Kuroshita (@kurogedelic), Hügelton Instruments (Felucca), with SLOOP changes by isod89, and SMK-37 work
copyright (C) 2026 M. Geisler (genkigenki/makkuro). Preserve the complete upstream credits and individual notices:

- [OberVave LICENSING.md at the build pin](https://github.com/zvenson/obervave/blob/792535d23ef4265475b1c2f9895ca30e857fe596/LICENSING.md)
- [Shine On LICENSING.md at the build pin](https://github.com/zvenson/shineon/blob/2f37738d690a628e0ae1d23d07ea5ee3eeda2de7/LICENSING.md)

Those inventories also identify separately licensed material, including the Terminus font (SIL OFL 1.1,
`assets/fonts/Terminus-LICENSE.txt`) and OberVave's screen-mirror code (MIT,
`firmware/src/screen_mirror/LICENSE`). Their own notices still apply wherever that material is included;
GPL licensing of the firmware does not erase them. The source inventories also cover assets and tools not
necessarily included in FMutate's native cartridges.

## Emulator: MIT, firmware packages separate

The emulator engine uses [fm1-emu by Joakim Eriksson at
`42c7fef9ae4ef0496e73b3cab9ebaea6d93c310f`](https://github.com/joakimeriksson/fm1-emu/tree/42c7fef9ae4ef0496e73b3cab9ebaea6d93c310f),
fetched by `native/build_emu.sh`. Its MIT notice, copyright (c) 2026 Joakim Eriksson, is reproduced in
[LICENSES/fm1-emu-MIT.txt](LICENSES/fm1-emu-MIT.txt) and must accompany copies or substantial portions of that
software. FMutate's own MIT notice is not a substitute for it.

Running a firmware update package (`.fwsc`) in this emulator does not relicense that package. Downloaded,
imported and test firmware packages retain their authors' terms, whether GPL, another licence or proprietary.
Stock M-VAVE firmware is bring-your-own; FMutate's licence grants no rights to redistribute it.

## Other dependencies and data

- The firmware list is from the [FM-1 Firmware Hub](https://thefirmwarehub.com/), licensed CC BY 4.0
  ([licence text](https://creativecommons.org/licenses/by/4.0/)); attribute it as "Firmware list: The Firmware
  Hub – https://thefirmwarehub.com" and identify any changes when redistributing its list data. Per the Hub's
  terms, card texts and pictures are **not** under that licence: they belong to each firmware's maker (its
  `fmhub.json` and repository); name the maker and link its repository wherever they are shown. The short
  descriptions of the built-in firmwares in `lib/fmutate/firmware.ex` follow zvenson's card texts for OberVave and
  Shine On. Nor does the Hub's licence cover the listed firmware downloads.
- Mob, its plugins, Elixir/Erlang, Android libraries and other dependencies retain their own licences and
  copyright notices. Generated or copied framework code is not newly owned by FMutate merely because it is
  present in this repository or APK. Preserve the notices supplied by each dependency.
- `android/gradlew` retains its Apache-2.0 header, copyright 2015 the original authors
  ([licence text](https://www.apache.org/licenses/LICENSE-2.0)).

## Distribution of native builds and APKs

`native/build_android.sh` and `native/build_host.sh` compile `native/engine/live.c` with the selected firmware's
source into `libcart_<firmware>.so`. `libfm1engine.so`, built from `native/engine/fm1engine.c`, loads the cartridge
with `dlopen`; that engine/cartridge combination runs in a separate OS process from the Elixir app. The app and
engine communicate over an Erlang Port and shared audio/screen memory. The APK built with the native cartridges
therefore contains GPL components: it is **not an MIT-only distribution**.

Native cartridges the app downloads through the cartridge index (`FMutate.Cartridges`) are not in the APK: the
[fmutate-cartridges](https://github.com/GenericJam/fmutate-cartridges) repository builds, signs and distributes
them, each from its firmware's pinned source and under that firmware's own licence (the index lists each one's
`license`, `repo` and `commit`). Downloading one does not relicense it.

When conveying GPL cartridges or a GPL-covered combined work, comply with GPL v3 for that work, including:

- retaining copyright/licence notices and supplying the GPL text;
- providing complete corresponding source through a GPL-compliant distribution method, including the exact
  upstream revisions, FMutate's patches and derivative harness, build scripts, and any other required source;
- preserving required notices for separately licensed material, and providing installation information where
  GPL v3 requires it.

The source links and pins above identify inputs; links alone are not a substitute for meeting GPL source-delivery
requirements. Distribute notices and licence texts with the relevant binaries, not just in a development checkout.

How FMutate's builds do this:

- **Notices in the APK.** The Android build copies `LICENSE`, `THIRD_PARTY_NOTICES.md` and `LICENSES/` into the
  APK's assets under `licenses/` (`copyLicenseAssets` in `android/app/build.gradle`).
- **Source with each release.** Every GitHub release's notes state where its corresponding source is: this
  repository at the release's tag (which contains `native/patches/`, `native/engine/live.c` and the build
  scripts with the pinned upstream commits), plus the pinned upstream repositories listed above. Keep the tag
  and those upstream commits available for as long as the release is offered.

MIT permits FMutate-owned code to be included in a GPL-covered combined work while its original MIT grant and
notice remain available. Neither dynamic linking, a process boundary, shared memory nor packaging in one APK
by itself resolves whether the wider app is a combined work or mere aggregation. This notice does not assert
that the app/engine boundary exempts the rest of a distributed build from GPL. Assess the actual combination
before redistribution; comply with GPL for any covered combined work rather than labelling it solely MIT.

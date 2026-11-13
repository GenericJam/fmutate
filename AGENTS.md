# AGENTS.md: FMutate

FMutate runs M-VAVE FM-1 community firmwares on Android with a customisable touch surface. It is a
[Mob](https://hexdocs.pm/mob) app: Elixir on the BEAM, running on the phone, with native Jetpack Compose views.
This file is for anyone changing the code, human or AI agent.

## Read first

1. [README.md](README.md): what the app is.
2. [docs/architecture.md](docs/architecture.md): processes, code map, technical decisions, measurements, how inputs
   can go missing and how to see it.
3. [docs/engine_protocol.md](docs/engine_protocol.md): the engine executables, their Port messages, the shared
   memory (audio ring, screen and LEDs), panel edge timing.
4. [docs/design/HANDOFF.md](docs/design/HANDOFF.md) and the rest of `docs/design/`: screens, layout model, touch
   rules, the creature, the sibling-app protocol. Where the design and the technical docs disagree on *how*, the
   technical docs win; design items marked "not designed yet" need a decision, not an invention.

## Toolchain

Always run mix through mise, so the pinned versions in `.tool-versions` are used (Erlang 29, Elixir 1.20, Java 17,
Zig 0.17, Rust):

```sh
mise exec -- mix ...
```

The Android NDK is 27.2 (`~/Android/Sdk/ndk/27.2.12479018` or `ANDROID_NDK_HOME`).

## Build, test, run

| What | Command |
|---|---|
| Engine + cartridges for the phone (all ABIs into `jniLibs`) | `sh native/build_android.sh` |
| The same for this computer (the tests run them) | `sh native/build_host.sh` |
| The emulator engine (`libfm1emu.so`; host, arm64-v8a, x86_64; also fetches test packages) | `mise exec -- sh native/build_emu.sh` |
| Tests | `mise exec -- mix test` |
| Compile check | `mise exec -- mix compile --warnings-as-errors` |
| Kotlin check | `cd android && ./gradlew -q :app:compileDebugKotlin` |
| Install and start (after native, Kotlin or NIF changes) | `mise exec -- mix mob.deploy --native --android --device <serial>` |
| Push Elixir only | `mise exec -- mix mob.deploy --android --device <serial>` |

Native outputs and the fetched sources live in `native/build/` (git-ignored); run the native scripts once per
checkout or worktree, and again after changing `native/`. The engine tests run real firmwares on the host; the
emulator engine's tests skip themselves until `native/build_emu.sh` has run.

**After every deploy, restart the app.** An Elixir-only deploy hot-loads modules and unloads the audio NIF:

```sh
adb -s <serial> shell am force-stop com.genericjam.fmutate
adb -s <serial> shell am start -n com.genericjam.fmutate/com.example.fmutate_app.MainActivity
```

(The application id is `com.genericjam.fmutate`; the Kotlin package stays `com.example.fmutate_app` because the
JNI symbols in Mob's generated code follow it.)

## Looking at the running app

- **Screenshots**: `adb -s <serial> shell screencap -p /sdcard/s.png && adb -s <serial> pull /sdcard/s.png
  tmp_shots/<name>.png` (`tmp_shots/` is git-ignored). Drive it with `adb shell input tap|swipe`; for a key held
  or slid, `adb shell input motionevent DOWN|MOVE|UP x y` (a held `input swipe` doesn't press keys).
- **Evaluate Elixir on the device**: `mise exec -- mix run --no-start tools/rpc.exs <serial> '<expr>'`, e.g.
  `FMutate.Audio.stats()`, `FMutate.Instance.view("a")`, `FMutate.Instance.journal("a", 50)` (the last inputs),
  `FMutate.Instance.held("a")`. The app is the node `fmutate_a@127.0.0.1` on the device's port 9150 (no EPMD).
  Calls time out after 30 s: for longer sampling, spawn a sampler on the device and read it with a second call.
- **Performance**: `adb shell dumpsys gfxinfo com.genericjam.fmutate reset`, play, then `dumpsys gfxinfo …`; the
  procedure and past numbers are in docs/architecture.md "Measured".
- **A package on a device** (emulator backend): push it to `/data/local/tmp/`, `run-as com.genericjam.fmutate cp`
  it into `files/`, then `FMutate.Library.import_package/2` and `FMutate.Instance.switch_firmware/2` over rpc.
- **A slow phone on a fast device** (emulator backend): `Application.put_env(:fmutate_app, :emu_env, [{"FM1_NO_JIT",
  "1"}])` over rpc, then start the package again (switch to it, or `FMutate.Instance.debug("a", :kill9)`): the
  emulator engine interprets and runs slower than real time, so the instance lowers its emulated CPU clock
  (`docs/engine_protocol.md` "Speed and fill"). `Application.delete_env(:fmutate_app, :emu_env)` undoes it.
- **From outside**: `tools/android_probe` is a second app (same debug key) that plays MIDI into `FMutate A` and
  reads the sibling cookie; `tools/sibling_probe.exs` is a sibling node; `tools/midi_latency.exs` measures MIDI
  latency; `tools/pair_probe.exs` pairs a node with the Pair screen (QR link or typed code, through
  `adb forward` or over Wi-Fi) using mob_pair's joining client, then connects and calls `:fmutate_instance`.
- **Pairing** (menu › Pair an app; `docs/design/protocol.md` §7 "Pairing") is built on the shared package
  [mob_pair](https://github.com/GenericJam/mob_pair): the protocol, its security model and what stays in FMutate
  are in that package's DECISIONS.md. Change protocol behaviour there, not here (Humdinger and Magpie use it
  too); FMutate keeps the screen (`FMutate.PairScreen`), the service (`FMutate.Pairing`) and admission
  (`FMutate.Dist` follows `MobPair.Pairings`). Over rpc: `FMutate.Pairing.info()` (shows the live secret),
  `MobPair.Pairings.list()` (shows every paired app's cookie): keep their output out of logs and issues.

## Conventions

- **Per instance, no singletons**: everything a firmware has (layout, saves, MIDI port, distribution name) is keyed
  by instance id. v1 has one instance, `"a"`.
- **Pixels and audio never pass through the BEAM**: they go through shared memory between the engine, the mixer
  NIF and the Kotlin view. Keep it that way.
- **Firmware changes are patches**: FMutate's changes to firmwares or fm1-emu are files in `native/patches/<name>/`,
  applied by the build scripts to sources pinned by commit. Regenerate a patch from a clean checkout of the pinned
  commit with the earlier patches applied.
- **Firmware capabilities** (pitch bend, octave reset, per-note pressure) are `caps` in `FMutate.Firmware`; the UI
  greys out what a firmware doesn't support.
- **The instrument surface is performance-critical** (`InstrumentView.kt`): controls are drawn on layers that
  re-record only when what they show changes (rest of the controls, playing keys, firmware screen, creature,
  overlay). Keep fast-changing state out of the controls layer, never allocate per frame, and measure with
  gfxinfo after changing it. The pointer loop runs once for the surface's lifetime and checks every event for
  fingers it lost; keep that invariant.
- **Mob screens**: UI with the `~MOB` sigil. Node colours must be ARGB integers or theme atoms (Mob's Android
  renderer drops `"#RRGGBB"` strings): use `FMutate.Style.argb/1` or pipe the tree through
  `FMutate.Style.native_colors/1`. Canvas drawing takes hex. Load slow data with `Mob.Socket.start_async/3`,
  long lists with `<LazyList>`, and subscribe to servers through `FMutate.Subscription` so a restarted server
  is re-subscribed.
- **Tests** cover behaviour a player or a sibling app would notice: boundaries, transitions, errors, timing. No
  tests of wiring, copies or wording. Engine tests run real firmwares (`FMutate.PanelEdgesTest.Rig` drives an
  engine and reads its audio ring).
- **Docs**: a change in behaviour updates docs/architecture.md (decisions, measurements) or
  docs/engine_protocol.md in the same commit.

## Gotchas

- Don't run two `mix` commands that touch Hex at the same time; a concurrent write once corrupted
  `~/.hex/hex.config`.
- A firmware's behaviour is its own: OberVave's ARP button on the arp page is HOLD (a latch), so notes can keep
  playing by design. Check the input journal before suspecting FMutate.
- Parallel work: give each stream its own `git worktree` with its own `deps/`, `_build/`, `native/build/`,
  `android/local.properties` and its own device or emulator.
- In the background the app stays alive only through `FMutate.Background`'s foreground service (while a firmware
  plays): `FMutate.Background.state()`, `adb shell dumpsys activity services com.genericjam.fmutate`. A fresh
  install asks for notifications over the instrument at the first engine start; the background check and its
  numbers are in docs/architecture.md "Background".

## Mob documentation

Read the docs for the Mob version in `mix.lock`: `deps/mob/guides/*.md` and `deps/mob/usage-rules.md` after
`mix deps.get`; https://hexdocs.pm/mob/llms.txt lists every page (each also as Markdown at
`https://hexdocs.pm/mob/<page>.md`). Start with `components`, `events`, `screen_lifecycle`, `navigation` and
`native_extensions`.

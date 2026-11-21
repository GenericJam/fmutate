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
| iOS (in progress, `docs/decisions/2026-11-13-ios-port.md`): engines, the built-in cartridges, every published iOS cartridge pinned in `native/ios_cartridges.lock` (~100 MB per target; it warns about any it leaves out) and the emulator as one archive per target, linked into the app | `mise exec -- sh native/build_ios.sh` (`TARGETS="sim device host"`; `host` = macOS, the built-ins only, for `test/fmutate/inproc_engine_test.exs`). `IOS_CARTRIDGES_REFRESH=1` re-pins the lock from the signed index; commit it |
| Tests | `mise exec -- mix test` |
| Compile check | `mise exec -- mix compile --warnings-as-errors` |
| Kotlin check | `cd android && ./gradlew -q :app:compileDebugKotlin` |
| Kotlin unit tests | `cd android && ./gradlew :app:testDebugUnitTest` |
| Swift tests (macOS, no app build: the UIKit-free `ios/*.swift`, symlinked into `ios/Tests`; `test/fixtures/strike_math.json` is shared with `StrikeMathTest.kt`) | `swift test --package-path ios/Tests` |
| Install and start (after native, Kotlin or NIF changes) | `mise exec -- mix mob.deploy --native --android --device <serial>` |
| Push Elixir only | `mise exec -- mix mob.deploy --android --device <serial>` |

Native outputs and the fetched sources live in `native/build/` (git-ignored); run the native scripts once per
checkout or worktree, and again after changing `native/`. The engine tests run real firmwares on the host; the
emulator engine's tests skip themselves until `native/build_emu.sh` has run.

**CI** (`.github/workflows/test.yml`, every push to master and every pull request) runs the same: the Elixir
tests on Linux and on macOS, each with the native scripts above run first (macOS adds `TARGETS=host
native/build_ios.sh`, so the in-process engine tests run there and skip on Linux, as does `AudioNifTest`, which
is macOS only), the Kotlin compile and unit tests, and the Swift tests. A test that depends on the host's speed
must hold on a CI runner too (slower than an Apple-silicon Mac, on 3 or 4 cores) and on a busy Mac: where it can,
measure what doesn't depend on the host (CPU time per firmware ms, the firmware's clock against its audio, STATUS
stopping) rather than wall-clock speed.

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
  A physical iPhone: pass its UDID instead of a serial (through `iproxy`, to Mob's development node); launch the
  app with `MOB_NODE_HOST=127.0.0.1` first (the command is in `tools/rpc.exs`'s header). Files into the app:
  `xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier com.genericjam.fmutate`.
- **Performance**: `adb shell dumpsys gfxinfo com.genericjam.fmutate reset`, play, then `dumpsys gfxinfo …`; the
  procedure and past numbers are in docs/architecture.md "Measured".
- **A package on a device** (emulator backend): push it to `/data/local/tmp/`, `run-as com.genericjam.fmutate cp`
  it into `files/`, then `FMutate.Library.import_package/2` and `FMutate.Instance.switch_firmware/2` over rpc.
- **A slow phone on a fast device** (emulator backend): `Application.put_env(:fmutate_app, :emu_env, [{"FM1_NO_JIT",
  "1"}])` over rpc, then start the package again (switch to it, or `FMutate.Instance.debug("a", :kill9)`): the
  emulator engine interprets and runs slower than real time, so the instance lowers its emulated CPU clock
  (`docs/engine_protocol.md` "Speed and fill"). `Application.delete_env(:fmutate_app, :emu_env)` undoes it.
- **From outside**: `tools/android_probe` is a second app (same debug key) that plays MIDI into `FMutate A`,
  reads the sibling cookie, registers a sibling node name (`--es do register`) and floods the distribution port
  with unknown names (`--es do atoms`: FMutate should refuse every one); `tools/sibling_probe.exs` is a sibling
  node (register its name first); `tools/midi_latency.exs` measures MIDI
  latency; `tools/pair_probe.exs` pairs a node with the Pair screen (QR link or typed code, through
  `adb forward` or over Wi-Fi) using mob_pair's joining client, then connects and calls `:fmutate_instance`.
- **Pairing** (menu › Pair an app; `docs/design/protocol.md` §7 "Pairing") is built on the shared package
  [mob_pair](https://github.com/GenericJam/mob_pair): the protocol, its security model and what stays in FMutate
  are in that package's DECISIONS.md. Change protocol behaviour there, not here (Humdinger and Magpie use it
  too); FMutate keeps the screen (`FMutate.PairScreen`), the service (`FMutate.Pairing`) and admission
  (`FMutate.Dist` follows `MobPair.Pairings`). Over rpc: `FMutate.Pairing.info()` (shows the live secret),
  `MobPair.Pairings.list()` (shows every paired app's cookie): keep their output out of logs and issues.

## Publishing an Android release

Sideloaded APKs on [GitHub Releases](https://github.com/GenericJam/fmutate/releases), signed with FMutate's release
key: certificate SHA-256 `56676adfba1c2092a6150e1bfd513853443a5a16f1402348f5b8c35df16d9fa9` (alias `fmutate`,
from v0.2.0; v0.1.0 used a key that is lost). The keystore is `~/.config/fmutate/android-release.jks` on Kevin's
Mac, with its properties in `~/.config/fmutate/android-release.properties`; copy that file to
`android/keystore.properties` (git-ignored, mode 600) in the checkout you build from. Never commit either.
Installed copies only accept an update signed with the same certificate: losing this key again means every player
uninstalls (and loses their layouts and saves), so keep a backup of both files off this Mac.

1. **Version** (in a PR): `version` in `mix.exs` and `versionName` in `android/app/build.gradle` match; raise
   `versionCode` there by one. iOS's `CFBundleShortVersionString` follows `version` at the next TestFlight build.
2. **Build** from merged master, in a fresh worktree. Its setup: `mise exec -- mix deps.get`;
   `android/local.properties` copied from another checkout with `mob.mob_dir` pointing at this one's `deps/mob`;
   `android/keystore.properties` (above); the Rust targets once (Building in README.md). Then
   `sh native/build_android.sh` (engine and built-in cartridges, all three ABIs) and
   `mise exec -- sh native/build_emu.sh` (`libfm1emu.so`: without it the APK can't run downloaded packages), then
   `mise exec -- mix mob.release --android` (stages `android/app/src/release/assets/otp.zip`, builds the AAB) and
   `cd android && ./gradlew assembleRelease` → `android/app/build/outputs/apk/release/app-release.apk`.
3. **Check** it: `apksigner verify --print-certs` shows the certificate above; `aapt dump badging` shows the
   version and `native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'`, and `unzip -l` lists `libfm1emu.so` for
   arm64-v8a and x86_64. Install it on an emulator or phone and play.
4. **Publish**: copy the APK to `fmutate-<version>.apk` and `FMutate.apk` (identical; `FMutate.apk` keeps
   `releases/latest/download/FMutate.apk` working), write `shasum -a 256 fmutate-<version>.apk >
   fmutate-<version>.apk.sha256`, then `gh release create v<version> -R GenericJam/fmutate --target <master sha>
   --title "FMutate <version>" --notes-file <notes> fmutate-<version>.apk fmutate-<version>.apk.sha256
   FMutate.apk`. The notes follow the last release's: install line, what's new, certificate and APK SHA-256, and
   the source paragraph (tag, commit, and the OberVave and Shine On commits `native/build_android.sh` pins and
   the fm1-emu commit `native/build_emu.sh` pins).

## Publishing to TestFlight (iOS)

Bundle id `com.genericjam.fmutate`, team Q89CW299G8; App Store Connect app "FMutate" (id 6837075931), SKU
`fmutate`. TestFlight only, never the App Store (don't use the version page's "Add for Review"). Groups:
"Internal" (internal, every build, Kevin) and "Public" (external, needs Beta App Review; its public link stays off
until the firmware authors agree to wider distribution). Beta description, feedback email, privacy policy
(`PRIVACY.md` on master) and the review contact are set on the app.

1. **Build number**: bump `CFBundleVersion` in `ios/Info.plist` to an integer above every build App Store Connect
   has seen for the app (it refuses a number twice, even after a failed upload; gaps are fine).
   `CFBundleShortVersionString` follows `version` in `mix.exs` (Android's `versionName`); mob_dev doesn't stamp it.
2. `mise exec -- sh native/build_ios.sh` (at least `TARGETS=device`), then `mise exec -- mix mob.release --ios` →
   `_build/mob_release/FmutateApp.ipa`, signed with the Apple Distribution certificate and the "FMutate App
   Store" profile (both auto-detected; the profile expires with the certificate, 2027-05-02). It links
   `priv/generated/driver_tab_ios.c` and regenerates both C tables; commit them if they change.
3. `xcrun altool --validate-app --type ios --file _build/mob_release/FmutateApp.ipa --apiKey <key_id> --apiIssuer
   <issuer_id>` (altool finds the key only in `~/.appstoreconnect/private_keys/`, where `mix mob.publish` copies
   it), then `mise exec -- mix mob.publish --ios` (or `mix mob.republish --ios`: bump, build, upload). Apple
   processes the build for 5–30 min; "Internal" gets it automatically. For "Public": add the build to the group,
   set its "What to Test" (betaBuildLocalizations), and submit it (betaAppReviewSubmissions); Apple reviews the
   first build of a version, later builds of the same version usually pass automatically.

The App Store Connect API key is configured in `mob.local.exs` (git-ignored, imported by `mob.exs`):
`config :mob_dev, app_store_connect: [key_id:, issuer_id:, key_path: "~/.appstoreconnect/AuthKey_<id>.p8"]`, the
team key the other GenericJam apps use. Never commit the `.p8`.

A release build keeps only the usage descriptions in `ios/Info.plist`: mob_dev 0.7.31 doesn't merge the plugins'
`plist_keys` into the IPA (a dev build does). Keep every string there, including camera, microphone and photo
library, which FMutate never asks for: Mob core's NIFs reference those APIs, and Apple's post-upload scanner
(ITMS-90683) demands a string for each one referenced. A release build has no Erlang distribution and none of
Mob's test harness NIFs (`:mob_nif.screen_info/0`, `ui_tree/0`, …): don't call them from app code. Prove a release
on a dev build (`mix mob.deploy --native --slim --device <udid>`), since `tools/rpc.exs` can't reach a release
build.

## Conventions

- **Per instance, no singletons**: everything a firmware has (layout, saves, MIDI port, distribution name) is keyed
  by instance id. v1 has one instance, `"a"`.
- **Pixels and audio never pass through the BEAM**: they go through shared memory between the engine, the mixer
  NIF and the Kotlin view. Keep it that way.
- **Firmware changes are patches**: FMutate's changes to firmwares or fm1-emu are files in `native/patches/<name>/`,
  applied by the build scripts to sources pinned by commit (every run of `build_android.sh`, `build_host.sh` and
  `build_ios.sh` checks the sources out again and applies them, so no build compiles a tree from before a patch).
  Regenerate a patch from a clean checkout of the pinned commit with the earlier patches applied.
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

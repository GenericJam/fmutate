# AGENTS.md: fmutate_app

FmutateApp is a [Mob](https://hexdocs.pm/mob) app: Elixir on the BEAM,
running on the phone, rendering native SwiftUI / Jetpack Compose views. Screens
live in `lib/fmutate_app/`; `lib/fmutate_app/app.ex` starts the app.

## Where Mob's docs are

Read the docs for the mob version this app actually uses, in this order:

1. **`deps/mob/guides/*.md` and `deps/mob/usage-rules.md`**, after `mix deps.get`.
   These match the installed version exactly. (With a `path:` dependency on
   mob, read that checkout's `guides/` instead.)
2. **https://hexdocs.pm/mob/llms.txt**, the index of every page. Each page is
   also served as Markdown at `https://hexdocs.pm/mob/<page>.md`, e.g.
   https://hexdocs.pm/mob/screen_lifecycle.md. Hexdocs shows the latest
   release; check `mix.lock` if behaviour differs.
3. **`mix hex.docs fetch mob`** for offline docs, written to
   `~/.hex/docs/hexpm/mob/<version>/`.
4. **IEx**: `iex -S mix`, then `h Mob.Socket.start_async` (any module or
   function).

Guides to start with: `getting_started`, `screen_lifecycle` (including async
loading with `start_async/3` / `handle_async/3`), `components`, `events`,
`navigation`, `testing` (`Mob.ScreenCase`), `coming_from_liveview`.

## Rules for this app

- Load data asynchronously with `Mob.Socket.start_async/3` and handle the result
  in `handle_async/3` (LiveView's `start_async`; `assign_async` is a `:loading`
  assign plus `start_async`). Never a bare `Task.async` in a screen.
- Long or paginated lists use `<LazyList>` with `on_end_reached`. Mob has no
  `stream`.
- Write UI with the `~MOB` sigil.
- Test screens with `Mob.ScreenCase` (`mount_screen`, `render_event`,
  `render_info`, `render_async`).

If you use [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/mob/usage-rules.md`.

## FMutate: working on this app

Read `docs/architecture.md`, `docs/engine_protocol.md` and `docs/design/HANDOFF.md` first.

- **Toolchain**: always run mix through mise so the pinned Erlang/Elixir/Zig/Java are used:
  `mise exec -- mix ...`. Zig 0.17.0 is required for native builds.
- **Native libs** (engine + cartridges, gitignored): `native/build_android.sh` (all ABIs into jniLibs) and
  `native/build_host.sh` (for tests). Run them once per checkout/worktree and after changing `native/`.
  The emulator engine (`libfm1emu.so`, Rust; Rust comes from mise, add the Android targets once with
  `mise exec -- rustup target add aarch64-linux-android x86_64-linux-android`): `mise exec -- sh
  native/build_emu.sh` (host + arm64-v8a + x86_64; also fetches test packages into `native/build/packages/`).
- **Tests**: `mise exec -- mix test` (needs `native/build_host.sh`; runs real firmwares on the host; the host
  Audio drains rings in real time so firmware time advances). The emulator engine's tests skip themselves
  until `native/build_emu.sh` has run.
- **Deploy**: `mise exec -- mix mob.deploy --native --android --device <serial>` after native/Kotlin/NIF
  changes, `mise exec -- mix mob.deploy --android --device <serial>` for Elixir only. After a native deploy,
  restart the app: `adb -s <serial> shell am force-stop com.genericjam.fmutate && adb -s <serial> shell am
  start -n com.genericjam.fmutate/com.example.fmutate_app.MainActivity`.
- **Look at it**: `adb -s <serial> shell screencap -p /sdcard/s.png && adb -s <serial> pull /sdcard/s.png <abs path>`
  (into `tmp_shots/`, gitignored). Drive it with `adb shell input tap|swipe` (pixels).
- **Inspect it**: `mise exec -- mix run --no-start tools/rpc.exs <serial> '<elixir expr>'` evaluates on the
  device (e.g. `FMutate.Audio.stats()`, `FMutate.Instance.view("a")`). The app is node `fmutate_a@127.0.0.1` on
  the device's 127.0.0.1:9150 (`FMutate.Dist`, no EPMD; `mix mob.connect` and dist hot-loads don't find it, deploys
  push files and restart). Several rpc runs can target different devices at once.
- **Drive I/O from outside**: `tools/android_probe` is a second app (same debug key) that reads the sibling cookie,
  plays MIDI into `FMutate A`, listens to it, and offers a `FMutate Probe` MIDI device;
  `tools/sibling_probe.exs` is a sibling node (Allow / key press / events / Disconnect);
  `tools/midi_latency.exs` measures MIDI note → engine Port.
- **Worktrees**: each parallel stream works in its own `git worktree` with its own `deps/`, `_build/`,
  `android/local.properties` (copy from the main checkout) and its own device/emulator.

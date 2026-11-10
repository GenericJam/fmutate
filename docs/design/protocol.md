# FMutate ↔ sibling apps: Erlang distribution contract (v1 draft)

Sibling apps (voice app, host app with agent + rig + Strudel) drive FMutate over Erlang
distribution on the same phone. Everything a touch control can do, a remote message can do.

## 1. Discovery and naming

- Each instance runs as node `fmutate_<instance>@127.0.0.1` (v1: `fmutate_a@127.0.0.1`).
- One registered process per instance: `:fmutate_instance` (global name `{:fmutate, "a"}`).
- Distribution listens on 127.0.0.1 only (`-kernel inet_dist_use_interface {127,0,0,1}`).
- All messages carry a protocol version: `{:fmutate, 1, instance_id, payload}`.

## 2. Inputs (sibling → FMutate)

Same events the on-screen controls produce. Fire-and-forget casts.

```elixir
{:key, n, :down, velocity}        # n 0..26, velocity 1..127
{:key, n, :up}
{:encoder, id, clicks}            # id in [:select, :presets, :algorithm, :knob1..:knob4], clicks ±int
{:pot, :master, value}            # value 0.0..1.0 (absolute)
{:button, id, :down | :up}        # 14 ids, see HANDOFF §2
{:midi, bytes}                    # raw MIDI into the firmware's MIDI in
```

Remote input and touch input merge by the same rules as two on-screen controls
(HANDOFF §6 rule 7). While any remote input arrived in the last 2 s, the instrument shows an
"externally driven" indicator (not designed yet).

## 3. Subscriptions and outputs (FMutate → sibling)

```elixir
# call
{:subscribe, pid, topics}         # topics ⊆ [:screen, :leds, :midi_out, :status, :layout]
{:unsubscribe, pid}
```

Events sent to subscribers:

```elixir
{:screen, seq, frame}             # 240×240, pixel format as the emulator gives it (assume RGB565, 115 200 bytes)
                                  # send only changed frames; coalesce to ≤ 30 fps per subscriber
{:leds, keys_bitmap, buttons_map} # keys: 27-bit integer; buttons: %{id => :off | :on | :blink}
{:midi_out, bytes}
{:status, status}                 # :booting | :running | :crashed | :safe_mode | {:slow, clock_pct}
{:layout_changed, layout_id}
```

Audio is **not** sent over distribution. Sibling apps get audio through the system (or later a
dedicated path); distribution is for control and screen data.

## 4. Layout and firmware calls (sibling → FMutate)

```elixir
{:list_layouts, firmware_id}                 # → {:ok, [%{id, name, made_by}]}
{:get_layout, layout_id}                     # → {:ok, json_binary}
{:put_layout, json_binary, opts}             # → {:ok, layout_id} | {:error, reasons}
                                             #   validated against layout.schema.json
                                             #   opts: [activate: bool, trial: bool]
{:list_firmware}                             # → {:ok, [%{id, name, version, status}]}
{:switch_firmware, firmware_id}              # → :ok | {:error, :not_installed | :quarantined}
{:install_firmware, fwsc_binary, meta}       # → {:ok, firmware_id}
```

Anything that changes what the player sees or loads new code into the emulator
(`put_layout` with `activate`, `switch_firmware`, `install_firmware`) asks the player first on
the FMutate side: a sheet naming the app and the change, approved with the device screen lock
(same pattern as Operator). `trial: true` applies a layout that reverts automatically if the
player leaves the app without keeping it.

## 5. Trust and security (decide before shipping)

Plain Erlang distribution is **full trust**: a connected node can spawn processes and run any
code on the other node. A facade process does not prevent that. So:

- v1: only connect to **sibling apps signed with the same key** (verify the peer package's signing
  certificate via Android before handing over the cookie). Cookie is random per install, never
  user-visible.
- The I/O screen lists connected apps with Disconnect; first connection needs an Allow tap.
- Anything else (third-party apps, network, laptop): use a separate socket protocol carrying
  only the messages above (e.g. length-prefixed `:erlang.term_to_binary/2` decoded with
  `binary_to_term(bin, [:safe])`, or JSON over WebSocket) with explicit pairing. Not in v1.

## 6. Instances

All calls name the instance. v1 rejects anything but `"a"` with `{:error, :no_such_instance}`.
A later second emulator adds `fmutate_b@127.0.0.1` and the same API.

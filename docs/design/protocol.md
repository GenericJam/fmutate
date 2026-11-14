# FMutate ↔ sibling apps: Erlang distribution contract (v1 draft)

Sibling apps (voice app, host app with agent + rig + Strudel) drive FMutate over Erlang
distribution, on the same phone or (after pairing, §7) from another phone on the same Wi-Fi.
Everything a touch control can do, a remote message can do.

## 1. Discovery and naming

- Each instance runs as node `fmutate_<instance>@127.0.0.1` (v1: `fmutate_a@127.0.0.1`).
- One registered process per instance: `:fmutate_instance` (global name `{:fmutate, "a"}`).
- Distribution listens on 127.0.0.1 only (`-kernel inet_dist_use_interface {127,0,0,1}`); apps paired from
  another phone come in through a TLS front (§7 "Pairing").
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
- **Pairing** (QR code or typed code, the player's Allow, a per-app cookie, TLS from another phone) is the
  path for sibling apps that aren't signed with FMutate's key or run on another phone: §7.

## 6. Instances

All calls name the instance. v1 rejects anything but `"a"` with `{:error, :no_such_instance}`.
A later second emulator adds `fmutate_b@127.0.0.1` and the same API.

## 7. As implemented (FMutate side, v1)

- **Node and port.** `FMutate.Dist` starts `fmutate_a@127.0.0.1` ~3 s after launch (Android's UI start races
  distribution, see `Mob.Dist`), listening on `127.0.0.1:9150` (instance b: 9151) with **no EPMD**: Android
  has none, and OTP's `erl_epmd` with `erl_epmd_node_listen_port` runs without one. This replaces Mob's
  development node; `tools/rpc.exs` reaches the app the same way.
- **Connecting** needs only OTP:
  `erl -name <app>@127.0.0.1 -setcookie <cookie> -start_epmd false -erl_epmd_port 9150 -dist_listen false`
  (a hidden node that only connects out). Retry `Node.connect/1` about once a second until the player
  allows the app.
- **Cookie handover (§5).** `content://com.genericjam.fmutate.siblings/node` returns `node, port, cookie,
  protocol`. It is guarded by `com.genericjam.fmutate.permission.SIBLING` (protectionLevel `signature`), so
  Android checks that the reading app is signed with FMutate's key. The cookie is random per install.
- **Allow / Disconnect.** An app that isn't allowed is refused **at the handshake**: this node's default
  cookie isn't the sibling cookie, and allowed nodes get the sibling cookie per node
  (`Node.set_cookie/2`). The refusal is logged by OTP; `FMutate.Dist.Knock` hears it and the I/O screen lists
  the app as "wants to connect" with Allow. Allow sets its cookie (kept across restarts). Disconnect gives
  the node a throwaway cookie and cuts the connection; it has to be allowed again. The state machine is
  `FMutate.Dist.Access`.
- **Facade.** `FMutate.Remote`, registered as `:fmutate_instance` (and globally as `{:fmutate, "a"}`; global
  names don't reach hidden nodes, so use the local name). §2 inputs, §3 subscribe/unsubscribe with `:status`,
  `:leds`, `:screen`; §4 `list_firmware`, `list_layouts`, `get_layout`.
- **Not yet:** `put_layout`, `switch_firmware`, `install_firmware` (they need the player-approval sheet with
  the screen lock, not designed, and a layout store) answer `{:error, :unsupported}`. `:midi_out` and
  `:layout` subscriptions are accepted but produce nothing: the engine protocol has no firmware MIDI out, and
  layouts don't change from outside the editor yet. The "externally driven" indicator isn't designed; the
  I/O screen shows "controlling this instance" for 2 s after remote input.
- **Trust (decided):** an allowed app has full Erlang trust (it can run code here); Allow is consent, and the
  I/O screen says so. Two ways in: the signature-protected sibling cookie (same key, same phone), or pairing
  (below), where the single-use code or QR, the player's Allow and the per-app cookie (plus, across phones,
  both pinned certificates) are the boundary. Third-party apps that pair get the same full trust: the Allow
  sheet names the app as it claims to be ("says it is …", from this phone or another). App display names come
  from the pairing (`app_name`), else from the node name.

### Pairing (menu › Pair an app)

Implemented with the shared package [mob_pair](https://github.com/GenericJam/mob_pair) (`service: "fmutate"`;
its DECISIONS.md is the security model). The wire format is Humdinger's `design/fmutate/protocol.md` §1.5,
byte for byte; the link adds `app=fmutate`.

- **Screen.** `FMutate.PairScreen`: the QR code (the link `fmutate://pair?v=1&app=fmutate&inst=a&node=fmutate_a
  &host=<Wi-Fi IP>&port=<pairing port>&fp=…&t=…`), the code (`KQ7M-X2PD`), a countdown, Copy code, Copy link
  (the same link with `host=127.0.0.1`, for an app on this phone), New code; expired, used and
  too-many-attempts states offer New code. Pairing runs only while it is open (`FMutate.Pairing` starts a
  `MobPair.Host` on 127.0.0.1 and the Wi-Fi address, never mobile data, port chosen by the system; mDNS
  `_fmutate._tcp` where the BEAM can bind 5353, see "Not yet"). When the Wi-Fi address changes (checked every
  30 s) the Host starts again on the new one, with a new secret; a request on the Allow sheet is gone with
  the old Host, so the sheet closes ("… stopped asking").
- **Secret.** One per screen: code (40 bits) and token (128 bits), single use, 5 minutes, 5 failed attempts
  kill both. A typed code is proven with SRP-6a bound to FMutate's certificate and the TLS session. Copy code
  and Copy link put the secret on the clipboard, which other apps can read. On Android 9 (API 28, below 29)
  any background app can listen for clipboard changes and use the secret before the player reaches the real
  app, so there the screen has no Copy buttons and tells the player to type the code in the other app
  (`FMutate.Pairing.copy_safe?/0`, from `ro.build.version.sdk`). On Android 10+ (where only the keyboard and
  clipboard tools can read it) the screen empties the clipboard, if it still holds what it copied, once the
  secret is used, expired, dead or replaced, and when the screen closes.
- **Allow.** A sibling that proves the secret gets a sheet. The name is the requester's claim, wherever it
  connects from: "An app on this phone says it is Humdinger · this phone · on moto e" (loopback) or "An app on
  another phone says it is Humdinger · Wi-Fi 192.168.1.40 · on Pixel 7"; "Replaces …" when an app is already
  paired under the same node name. Don't allow, swiping the sheet away and the sibling hanging up all refuse.
  One request at a time: another app asking while the sheet shows is refused at once. A node name that a
  sibling-cookie app has (allowed, connected or disconnected in I/O; a merely pending knock doesn't count) is
  refused before the sheet (`bad_node`), so pairing can't take it over.
- **Grant.** `MobPair.Pairings` makes a per-app cookie (32 random bytes) for exactly the node name the sibling
  declared and pins its client certificate; `FMutate.Dist` follows it and allows the node at once (no knock).
  A sibling on this phone gets `dist_host 127.0.0.1`, `dist_port 9150`, `inet_tcp` (the existing node). A
  sibling on another phone gets the Wi-Fi address, `dist_port 9250` (instance b: 9251), `inet_tls`.
- **TLS front.** FMutate's node starts at runtime on plain `inet_tcp` (`-proto_dist` is a boot argument), so
  `MobPair.Front` serves TLS distribution: TLS 1.3 with FMutate's certificate, only pinned client
  certificates, the first handshake message must name the node paired with that certificate, then the
  handshake is reframed and forwarded to `127.0.0.1:9150`. It listens on the Wi-Fi address only, and only
  while an `inet_tls` pairing exists (checked on every change and every 30 s, so it follows a new address).
- **Storage.** FMutate's certificate and key: `files/…/dist/pair_cert.json`; pairings (cookies, pinned
  fingerprints, names): `pairings.json`; both 0600 in app-private storage, like `sibling_cookie`, written
  through a synced temporary file. Reinstalling FMutate makes a new certificate: paired apps must pair again.
  So does a certificate file that doesn't decode (replaced by a new one); one that can't be read leaves
  FMutate running with pairing off (the Pair screen says the certificate can't be read). The whole `files/dist`
  directory (these files and the sibling cookie) is kept out of Android 12+ cloud backup and device-to-device
  transfer (`res/xml/data_extraction_rules.xml`, `android:dataExtractionRules`; `allowBackup="false"` covers
  older Android): a new phone gets a new certificate and new cookies, and siblings pair again.
- **Disconnect / unpair.** I/O lists paired apps with their name and "paired · this phone" or "paired · Wi-Fi ·
  <device>"; Disconnect revokes the pairing (connection cut, cookie replaced, certificate unpinned): the app
  must pair again. A sibling forgetting FMutate calls `{:unpair, its_own_node}` on `:fmutate_instance` → `:ok`,
  then the same revocation.
- **Both paths coexist.** The signature-permission content provider (Android, same key) still works as above;
  pairing doesn't replace it. An app could use either; a node name is either a sibling-cookie app or a paired
  app, never both: pairing refuses a sibling-cookie app's name, and I/O's Allow refuses a paired name.
- **Not yet:** mDNS on Android through `NsdManager` (the Erlang responder shares 5353 with the system responder
  where the kernel allows it and the phone delivers multicast without a `MulticastLock`; otherwise only the QR
  code / link pairs from another phone, and a typed code needs the sibling to know FMutate's address); iOS
  (the Elixir side is platform-neutral, but needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  `_fmutate._tcp` in Info.plist, and the same-phone loopback path doesn't exist between iOS apps); keeping
  pairings and the certificate key in Android Keystore (`mob_secure_store`) instead of a 0600 file; keeping
  the secret off the clipboard altogether (handing the link to the sibling with an explicit intent) or at
  least marking it sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`, which `Mob.Clipboard` can't set yet).

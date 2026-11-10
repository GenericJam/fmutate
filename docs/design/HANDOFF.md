# FMutate: design handoff (v1)

FMutate is a phone app that runs M-VAVE FM-1 community firmwares in an emulator and lets
each player rearrange the controls. Built on Mob (Elixir on the phone). Android first.

This folder:

| File | What it is |
|---|---|
| `HANDOFF.md` | This spec. Read first. |
| `style.ex` | `FMutate.Style` tokens (flat skin). Copy into the project. |
| `layout.schema.json` | JSON Schema for layout files. The editor, presets and other apps all use it. |
| `layouts/*.layout.json` | Three example layouts: classic, drum pads, sound designer. |
| `protocol.md` | Erlang distribution contract with sibling apps. |
| `creature.md` | The Opling mascot: geometry, forms, moods, animation. |
| `boards/*.dc.html` | Design boards as HTML. Reference for measurements and colours only; not code to ship. |

---

## 1. Scope

**FMutate is the instrument only:** the emulator, every control a firmware needs, layouts,
the firmware library, and I/O. It must work fully with no account or subscription.

In v1:
- Emulator running one firmware (one **instance**).
- Classic layout (the FM-1 panel) plus custom layouts, edited in place.
- Firmware library: browse, download, import `.fwsc`, switch, quarantine.
- I/O: audio out, MIDI in/out (USB, Bluetooth, virtual ports), Erlang distribution to sibling apps.

Not in v1 (design so these are possible later, don't build them):
- A second emulator instance. Everything is already per instance, see §3.
- Audio in. The FM-1 has none, so no firmware can use it. Leave a slot in the I/O model for a
  phone-only "virtual line-in".
- Network pairing (laptop, browser). Distribution is localhost only.
- Voice input, the agent, Strudel patterns, the rig. These are **sibling apps** that drive
  FMutate through `protocol.md`. Do not build them here.

## 2. The core idea: bindings

```
what the player touches  ──►  binding  ──►  what the firmware sees
(any control, any page)                      27 keys, 7 encoders, 1 pot, 14 buttons, MIDI in
                                             out: 240×240 screen, key LEDs, audio, MIDI out
```

Every on-screen control has one or more bindings to firmware inputs, MIDI, or app actions
(go to page). The classic layout binds one-to-one. Sibling apps send the same inputs through
distribution, so a remote key press and a touch key press are the same event.

Firmware inputs (take exact IDs from fm1-emu's input map; these names are the design's):
- **Keys:** `key_0` … `key_26`, low to high. 16 white, 11 black, grouped 3-2-3-2-1 (F to G).
  Black keys double as OP1–OP6, PIT, GLO, MONO, POLY on stock firmware: firmware's business.
- **Encoders (endless, relative):** `select`, `presets`, `algorithm`, `knob1`–`knob4`.
- **Pot (absolute):** `master`.
- **Buttons (14):** `oct_down`, `oct_up`, `fx`, `sel`, `env`, `lfo`, `edit`, `glo`, `home`,
  `save`, `arp`, `seq`, `play`, `rec`.
- **Outputs:** screen frames, key LEDs (one per key), button LEDs where the firmware drives them,
  audio, MIDI out.

## 3. Instances

Everything belongs to an instance: firmware, layout set, saves, MIDI port names, distribution
name. v1 has exactly one, `a`. Don't hardcode singletons; key state by instance id so a second
emulator later is another process plus a switcher.

## 4. Screens (P1)

Boards are in `boards/`. All instrument screens use the flat skin.

| Screen | Board | Notes |
|---|---|---|
| Instrument, classic layout (landscape) | `Flat-Instrument.dc.html` | All 27 keys at 49 pt, no scroll on 844 pt width. |
| Firmware library (portrait OK) | `Flat-Library.dc.html` | Cards, search, tag filter, statuses, import, switch with undo. |
| Custom layout examples | `Layout-Drums`, `Layout-Harp`, `Layout-Sound` | Ship as presets. |
| Edit in place: drag | `Edit-Drag.dc.html` | Grid overlay, footprint lime, overlap red, ghost at origin. |
| Edit in place: add/resize/pages | `Edit-Add.dc.html` | Tap empty cell → "Add here" menu; corner handles; page pill. |
| Binding sheet | `Editor.dc.html` | Opened by tapping a control in edit mode. Top canvas area is outdated; the sheet is current. |
| Keyboard strip settings | `Editor-Keys.dc.html` | Range presets, custom from–to, octave arrows, wobble. |
| Pages | `Pages.dc.html` | Switcher looks, page grid, layout settings. Ignore "Hold any way" for v1. |
| Portrait page example | `Portrait-Groove.dc.html` | Side keyboard + colour rail. Ignore the pattern tile (host app feature). |
| I/O and instance | `IO.dc.html` | Audio out, MIDI ports, connected apps. |
| Components and tokens | `Tokens.dc.html` | Every control state. |
| Touch rules | `Interaction.dc.html` | §6 in pictures. |

Not designed yet (ask before inventing): system states (booting, crashed, too slow, safe mode,
real FM-1 connected and installing to it), an "externally driven" indicator on the instrument,
layout share/import, first run, tablet.

Instrument chrome: the creature button is the only app chrome on the instrument. Tap: menu
(Library, Edit layout, I/O). Long-press: page grid. In layout files it is a `menu` control in the
dock (one per layout, 1×1, movable but not deletable).

## 5. Layout model and the grid

See `layout.schema.json`. A layout belongs to one firmware and one instance.

- **Frame:** each layout is `portrait` or `landscape`. It never rotates while playing (lock
  orientation while the instrument is shown).
- **Pages:** a layout has 1..n pages. A page is exactly one screen and **never scrolls**; only
  controls scroll inside themselves (keyboard strips via octave arrows or the colour rail).
  All pages share the frame. Switching pages never stops held notes.
- **Dock:** optional controls drawn at the same place on every page.
- **Grid:** computed from the device at runtime.
  - Usable area = screen minus 28 pt side gutters (Android back gesture, both sides in both
    orientations) minus 12 pt top/bottom.
  - Gap 8 pt. `cols = floor((usable_w + gap) / (48 + gap))`, same for rows. Cell size fills the
    remainder. On 844×390: 14 × 6, cells ≈ 48.9 × 54.3.
  - Every cell ≥ 48 dp, so every placed control is a safe touch target.
- **Positions are stored in cells of the authoring grid**, with that grid's `cols`/`rows`
  recorded. On a device with a different grid, scale positions proportionally and round; if a
  control would fall below its minimum size or overlap, show the layout with a "doesn't fit
  this phone" banner and offer the classic layout. (Open question: auto-reflow.)
- **Minimum sizes** (cells): button/knob/label 1×1; slider 1×2; XY pad 2×2; pad grid 2×2;
  strum strip 1×3; keyboard strip 4×2; firmware screen sized by integer scale (see §7).

Edit in place, home-screen style:
- Enter: long-press empty space on the instrument (600 ms) or menu → Edit layout.
- Grid appears; controls stop sending input; a pill shows page name, ‹ › page arrows, + Page, Done.
- Drag a control: it follows the finger; its origin shows a dashed ghost; target cells tint
  lime (free) or red (overlap). Drop on red = snap back.
- Drag onto the side edge for ~500 ms: moves it to the next page (creates one if needed).
- Tap a control: select (lime ring, four corner handles, size badge); tap again: binding sheet.
  Resize snaps to whole cells, never below the minimum.
- Tap an empty cell: "Add here" menu listing control types that fit the free run of cells;
  ones that don't fit are disabled with their minimum size.
- Presets: each firmware can ship layouts as data. "New page from a preset" in the page strip.

## 6. Touch rules

1. **A finger belongs to the control it first touched until it lifts.** It may slide anywhere
   without affecting other controls. Needs per-pointer events with IDs; if Mob lacks them, the
   instrument surface is a native view.
2. **Exception: keys, pad grids, strum strips.** Every finger plays; sliding onto the next
   key/string plays it (glissando). With **wobble** on (keyboard strips), sideways slide bends
   the held note instead (range ±1/2/7/12 st, one key width = full range, sends MIDI pitch bend;
   disabled on firmwares that ignore bend).
3. **Knobs:** delta = right + up − left − down. Touch never jumps the value.
   Pot: full range over ~200 pt, haptic bump at 0 and 100, no double-tap reset.
   Encoder: 1 click per 6 pt, light haptic per click; bubble shows clicks sent (e.g. "+3").
4. **Fine mode:** touch, hold still 0.4 s (haptic tick, bubble says "fine"), then drag at ¼ speed
   (encoder: 1 click per 24 pt). No global multi-finger gestures.
5. **Sliders are the default** control in new layouts. They move relative to where you land (no
   jump). Jump-to-position is an option for MIDI CC bindings only. Bound to an encoder, a
   slider sends clicks for distance moved.
6. **XY pad:** each axis bound separately; relative; on lift either stays or springs back
   (spring back sends the reverse clicks).
7. **Two controls bound to one input:** encoder deltas add. Absolute targets (pot, MIDI CC):
   last move wins, the other control greys out and uses pickup on its next touch.
8. **Empty space does nothing.** Out of room: lift and re-grab (all drags are relative).
9. **Visual press feedback on touch-down, before audio.** Pressed key moves 2 pt and turns lime;
   a ring marks each finger.
10. Accessibility: knobs/sliders are adjustable controls (one step per swipe).

## 7. Firmware screen

- 240 × 240 pixels drawn by the firmware. Render as a **native view** at **integer device-pixel
  scale only** (nearest-neighbour). 160 pt on a 3× phone = 480 px = 2×; 240 pt = 3×.
- 6 pt bezel (`screen_bezel`), nothing drawn over it.

## 8. Keyboard strips

- Range: 1, 2, 3 octaves or custom from–to. Show resulting key width; warn (amber) below
  ~40 pt. New layouts pick the most octaves that keep white keys ≥ 60 pt.
- Octave arrows slide the window over the 27 firmware keys; past either end they press the
  firmware's `oct_down` / `oct_up`.
- Key caps can carry the 88-key colour (see `style.ex` `pitch_color/1`), used by the portrait
  side keyboard and its rail. The rail is the scroll handle; dragging keys never scrolls.

## 9. Library

- Statuses: available, on phone (downloaded), running, "doesn't run here yet", quarantined
  (crashed the emulator twice; won't autostart; "Run anyway").
- Switching: one tap; toast "Your <old> saves and layout are kept" with Undo.
- Import `.fwsc` from files. Stock M-VAVE firmware is bring-your-own.
- No M-VAVE logo or trade dress. Not affiliated.

## 10. I/O

- Audio out: speaker / headphones / USB, level meter, honest latency figure.
- MIDI: system MIDI API; expose a virtual port per instance (`FMutate A`). USB/BLE inputs map to
  keys by default (channel selectable), pitch bend to wobble. MIDI clock: follow / send / off.
- Distribution: see `protocol.md`. I/O screen lists connected sibling apps with Allow/Disconnect.

## 11. Mob constraints

- Canvas has no gradients, no rotation, no hard offset shadows. Glows = 2–3 stacked translucent
  circles. Pressed = 2 pt move, not a shadow. Everything in the boards obeys this.
- Native views likely needed: firmware screen (certain), instrument surface if per-pointer touch
  is missing.
- Fixed geometry on the instrument; dynamic type only for chrome (library, sheets, I/O).

## 12. Open questions

1. Auto-reflow of a layout onto a smaller grid, or just warn?
2. Exact firmware input IDs and LED map from fm1-emu.
3. Screen pixel format from the emulator (assumed RGB565).
4. Trust model for non-sibling apps over distribution (see `protocol.md` §4).
5. App icon: masters (1024², adaptive layers) are designed on `Main.dc.html` but not yet exported.

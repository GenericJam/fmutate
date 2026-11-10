# The Oplings (mascot)

Small creatures made of FM operators. Each of the 32 algorithms is a body form. The species
name is **Oplings** (placeholder alternates: Modlings, FuMbles). Never "Tamagotchi"; say
"virtual pet". It never dies, starves or sulks.

Working reference: `boards/Creature.dc.html` (its script computes every shape below; port the
maths, not the HTML). Mascot sheet: `boards/Mascots.dc.html`.

## Anatomy (all values × scale `s`; `s = 1` → an operator is 22 × 14 pt)

| Part | Shape | Size |
|---|---|---|
| Operator | rounded rect | 22 × 14, radius 4 |
| Vertical gap between stacked ops | | 2.5 |
| Gap between columns | | 3 |
| Carrier (bottom op of a column) | same rect, darker fill | |
| Feet (2 per carrier) | rounded rect | 6 × 3.2, radius 1.6, row width = op width − 6 |
| Eyes (on the head op) | white circle | Ø 8, centres at 30 % and 70 % of op width, top at −2 (pokes above the op) |
| Pupil | dark circle | Ø 3.8 |
| Antenna (feedback loop, on the head op) | one stroked curl, 1.7 wide, round caps | 9 × 11 box at x = 56 % of op, y = −10.5 |
| Mouth (sing/breath/wave moods) | dark rounded rect | 6 × 5 (sing), 4.5 × 3 (others), centred, 1.6 above the op's bottom |

"Twins" puts one eye on each of the two top ops instead of two on one.
Pixel variant: same geometry, radius 0, square caps.

## Colours (flat)

| Tint | Body | Carrier | Feet | Antenna |
|---|---|---|---|---|
| lime (default) | `#C6F24E` | `#93CF32` | `#5E8F1A` | `#A98BFF` |
| violet | `#B9A2FF` | `#8F72F0` | `#5B44B8` | `#C6F24E` |
| coral | `#FF9A7A` | `#F2705A` | `#B9442F` | `#A98BFF` |
| sky | `#8FD8FF` | `#58B6EC` | `#2C7DB0` | `#FFB547` |

Eye white `#FFFFFF`, pupil `#17141F`.

## Forms

A form is a list of column heights (ops per column, carriers at the bottom) and the column
holding the head (eyes + antenna):

| Form | Columns | Head |
|---|---|---|
| tower | [4] | 0 |
| twins | [2, 2] | split (one eye each) |
| crab | [2, 3, 2] | 1 |
| spire | [6] | 0 |
| caterpillar | [1, 1, 1, 1, 1, 1] | 5 |
| lopsy | [4, 2] | 0 |
| stairs | [3, 2, 1] | 0 |
| trident | [1, 3, 1] | 1 |

**Deriving all 32 from the firmware's algorithm table:** one column per carrier; modulators
stack on the carrier they feed (an op feeding two ops sits on the left one); the op with
feedback is the head. Bodies taller than 6 ops cap at 6. Unlocked forms collect in a gallery.

## Moods

| State | Pose |
|---|---|
| Idle | blinks every 3–6 s; pupils follow tilt |
| Playing | bobs to tempo; small motion ticks either side |
| Agent/app thinking | pupils up-right; 3 stacked translucent violet circles behind the antenna (glow) |
| Proposal | before → after pair with an arrow |
| On trial | dashed violet outline around the body |
| Reverted | old form, previous one faded to 40 % |
| Booting | sitting in a zig-zag eggshell (lower 58 % of the body) |
| Crashed | pupils crossed inward; three amber dots circling above |
| Safe mode | eyes closed (thin bars); "zZ" |
| Too slow | pupils down; mouth open; sweat drop; puffs |
| Real FM-1 connected | waving arm (body-coloured bar beside the head) |
| Singing (voice app) | mouth open; violet notes beside the head |

Voice and agent moods are for sibling apps; FMutate itself needs idle, playing, booting,
crashed, safe mode, too slow, FM-1 connected and the trial/revert pair for layout changes made
by another app.

## Animation (move and scale only; no rotation, no gradients)

- **Pupils:** offset = tilt vector × (eye r − pupil r) × 0.85, spring with ~120 ms settle.
- **Blink:** eye height → 20 % → 100 % over 90 ms.
- **Bob:** on each beat, each column drops 4 % of body height and springs back; columns
  staggered 30 ms.
- **Flinch:** on a loud transient, scale 1.06 × 0.94 for 80 ms.
- **Mutate:** (1) ops that persist slide to their new column; (2) removed ops scale y 1 → 0,
  added ops 0 → 1; (3) eyes and antenna ride the head op; (4) feet pop in last.
- **Antenna "spin" while thinking:** fade the glow circles in sequence (no rotation).

## Where it appears in FMutate

- The 48 pt menu button on every layout (form follows the current algorithm if the firmware
  reports it; otherwise the twins). Mood reflects instrument state.
- Library header, empty states, the I/O instance card, first run (hatching).
- Never over the firmware screen or a control.

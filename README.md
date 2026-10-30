# Seventh Bowl — TouchOSC bridge

Sensor-to-MIDI bridge for *Seventh Bowl*, a tea-ceremony performance. ESP32 modules (HX711 load cells under the gaiwan and four cups, an IMU in the pitcher) send **OSC** to **TouchOSC**; a Lua script in the layout turns the readings into **MIDI** for Ableton Live and TouchDesigner.

The module firmware is not part of this repository.

```
ESP32 modules --OSC/UDP--> TouchOSC (this layout) --MIDI ch.1--> Ableton / TouchDesigner
```

## What it reports

For the gaiwan and each cup, three on/off states, each a CC that ramps 0 ↔ 127 with its own rise/fall time (3 s by default):

- **PRESENT** — the vessel is on the scale
- **FULL** — more full than empty
- **DRUNK** — an empty vessel that was drunk, as opposed to one waiting for tea

The amount of tea is deliberately not reported: a load cell reads weight × lever arm, so the same vessel gives very different numbers depending on where it stands. FULL and DRUNK are detected from *events* (a pour, a put-down that is lighter) instead.

Also: the **pitcher** tilt as a CC (angle from a captured ZERO pose, 0 below 10°) and a **round counter** that sends a MIDI note per change (+1 each time water goes into the gaiwan, or by hand; may go below 0 for a warming round).

## MIDI map (channel 1)

| | gaiwan | pitcher | cup 1 | cup 2 | cup 3 | cup 4 |
|---|---|---|---|---|---|---|
| FULL | CC 20 | CC 22 (tilt) | CC 23 | CC 24 | CC 25 | CC 26 |
| PRESENT (127 = on the scale) | CC 5 | – | CC 1 | CC 2 | CC 3 | CC 4 |
| DRUNK | CC 10 | – | CC 13 | CC 14 | CC 15 | CC 16 |

Rounds: one note-on per change, velocity 127, note = `note` (0) + max(count, 0). No note-off, no CC.

## OSC inputs

`/okuma/gaiwan`, `/okuma/cup1` … `/okuma/cup4` (raw HX711 counts), `/okuma/imu1/tilt` and `/okuma/imu1/dir` (pitcher), each with `…/battery`. Receive port is set in TouchOSC (10000 in the tests).

## Build

Only the Python standard library is needed.

```
python3 build_okuma_layout.py          # writes okuma_bridge.tosc and okuma_bridge.lua
python3 build_okuma_layout.py --xml    # also the readable XML
```

Open `okuma_bridge.tosc` in TouchOSC. The committed `okuma_bridge.tosc` is the built layout. All sensors, CCs, timings and thresholds are in the CONFIG section of `build_okuma_layout.py`; behaviour is in `okuma_bridge.template.lua`. TouchOSC's Lua is a small Lua 5.1 (no `setmetatable`, `pcall`, `require` …), see the header of the template.

## Use

1. Per vessel, with the scale empty press **NO**, then with the empty vessel standing press **EMPTY** (any order). The pour size per vessel is a setting in the config (in counts).
2. Press **ZERO** on the pitcher in its resting pose.
3. The big fader of each vessel is the input: OSC moves it, and a hand-drag feeds the logic the same way, so a whole ceremony can be played from the screen without sensors. Bottom = away, middle line = the empty vessel as it stands this round, top = one pour.

## Status

v6 is tested in a Lua 5.1 simulation and by replaying a recorded 40-minute ceremony log (6 rounds found at the right moments); testing on the real hardware is in progress. Pour sizes and thresholds come from one log and will need tuning.

Design notes and open points: [`docs/notes.md`](docs/notes.md). How OSC reaches the TouchOSC scripts (probe results): [`docs/osc-routing-probes.md`](docs/osc-routing-probes.md); the probe scripts are in the v4 commit.

## History

Earlier versions are in the git history, one commit per version (v1, v2, v3, v12, v4, v5, v6); `git log -p` shows what changed. v5's notes, with the fixes made during its tests, are in the v5 commit (`docs/notes.md`).

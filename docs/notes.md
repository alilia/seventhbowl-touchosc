# Design notes — v6 (2026-10-30)

## Why
After the first real ceremony (log 2026-10-29, 40 min, timestamped) the cup template was rethought: the amount of tea doesn't matter, only on/off states with configurable ramps. The log also showed that "full vs empty" can't be read from the level (cup3: empty -3.03..-3.22M, full -2.87..-3.01M overlap; wobble ~190k vs tea ~150–200k), only from changes at pour / put-down.

## Outputs (MIDI map, channel 1, remapped as little as possible)
| | gaiwan | round | pitcher | cup1 | cup2 | cup3 | cup4 |
|---|---|---|---|---|---|---|---|
| FULL (more full than empty) | CC 20 | – | CC 22 (tilt) | CC 23 | CC 24 | CC 25 | CC 26 |
| PRESENT (on the scale) | CC 5 | – | – | CC 1 | CC 2 | CC 3 | CC 4 |
| DRUNK (empty after drinking) | CC 10 | – | – | CC 13 | CC 14 | CC 15 | CC 16 |
| round | | note-on 0+count (below 0 -> note 0), velocity 127, no note-off, no CC | | | | | |

- FULL keeps the v5 fill CCs, PRESENT keeps the v5 lift CCs but 127 now means ON the scale (was: lifted). DRUNK is new: 10 + position in the fill order.
- Each vessel output is on/off and ramps linearly 0 <-> 127: PRESENT_RISE_S / PRESENT_FALL_S, FULL_*, DRUNK_* (all 3 s to start, 0 = jump); a reversal mid-ramp turns around from where it is. All 15 CCs are sent as 0 once at start.
- Each output has a tap toggle (shows the target, lit = on); a tap ramps the same way; the logic takes over at its next change.

## Logic (one template for gaiwan and cups, runs every frame)
- Units: w = (raw - N) / dE (0 = nothing, 1 = empty vessel as captured). Captures: NO and EMPTY only, any order. N is live (tare). Without a calibration everything still works with NO = 0, EMPTY = 1 (simulation).
- Level fader = the input: 0 away, 0.5 = the empty vessel as it stands this round (the reference), 1 = reference + one pour. OSC drives it; a hand drags it (simulation, OSC ignored while held). Same mapping for both, so the logic sees the same thing. The reference is re-taken every round, so the empty vessel sits on the middle line whatever spot it is on.
- PRESENT: w >= 0.5 (PRESENT_AT) for 100 ms (PRESENT_MS); off below 0.45. Measured latency on the log: median 0.13 s, max 0.25 s (incl. the 50 ms test step).
- Settled: still within STILL_BAND 0.03 for SETTLE_MS 300.
- States: waiting -> full -> drunk -> (round) -> waiting.
  - POUR: standing, still for pour_hold (cups 0.5 s, gaiwan 1.0 s), rise >= POUR_FRACTION 0.5 × pour (per-vessel setting in counts: gaiwan 100k, cup1 170k, cup2 125k, cup3 185k, cup4 1.2k, from the log) above the base; cups also need the pitcher gate. -> FULL (also a top-up from full / drunk). While full, any further settled rise raises the full weight (pours in steps).
  - DRUNK: a FULL vessel settles after being away, lighter than its full weight by >= DRINK_FRACTION 0.5 of what was poured. Less = stays full (sips add up).
  - ROUND change (gaiwan pour, +1, −1, reset): cups -> waiting, reference re-taken now (or at the next put-down if away). Undrunk cups also go to waiting.
  - An empty vessel (waiting / drunk) that settles re-anchors the reference.
- Pitcher gate (cups, `gate='pitcher'`): open while the pitcher is above POUR_THRESHOLD (or its fader is dragged above 0) and GATE_S 5 s after; a pitcher silent and untouched for GATE_SILENT_S 10 s opens it (weight alone). Note: before ZERO is captured the pitcher reads its own tilt (~76°) as pouring, so the gate is open.
- Rounds: +1 when the gaiwan goes from not-full to full (a second step of the same pour is a top-up, not a round). May go below 0 (warming round); below 0 sends note 0. Every change resets the cups (this works with no OSC too: the logic runs every frame).
- Tare: away, |w| <= tare band (0.4; gaiwan 0.3), still 5 s -> N takes the reading, remembered weights shift (no restart).

## Tested (Lua 5.1, stubbed TouchOSC)
- Whole round from the screen with no OSC: drag empty -> present; +1 -> waiting + note 1; drag full 0.3 s -> nothing, 4 s -> FULL; lift; back at 3/4 -> stays FULL; back empty -> DRUNK; top-up -> FULL; −1 −1 -> round −1, note 0, cups waiting; present ramp 127 -> 0 in 2.9 s.
- Pitcher gate: rise while the pitcher rests (after ZERO) -> no FULL; 2–3 s after a pour -> FULL; 9 s after -> no; pitcher silent 12 s -> FULL. Gaiwan not gated.
- Replay of the 2026-10-29 log (calibration from its plateaus): exactly 6 rounds at 102, 304, 598, 1414, 2018, 2376 s; cups 1–3 FULL right after each of the 5 pitcher pours and DRUNK after drinking; nothing during the first 90 s (cups lifted before tea) or at the unexplained pitcher tilt at ~1290 s.
- Old tags: v5 and v4 calibrations load; negative round count restores.
- 300-run random fuzz (OSC, drags, captures, clears, rounds, taps, pitcher): clean (found and fixed one nil after capture).

## Found in the replay and fixed
- R3 / R4 counted twice: water went in in two steps -> rounds only on not-full -> full.
- R6 missed: the gaiwan's empty scale drifted 330k -> 247k (83k = 0.47 w) in 40 min, the 0.10 tare band couldn't follow, lifting the lid then read as "away". Gaiwan tare band 0.3.
- Gaiwan not DRUNK after the last pour-out: its full weight was taken at the first step of the pour -> full weight follows later settled rises.

## Open
- Not yet tried on the real hardware.
- Cup4 cell to be replaced (1.5–2k signal vs 3k drift); `pour` for cup4 must be re-measured then.
- Pour sizes and DRINK_FRACTION are from one log; tune on the next ceremony.
- A vessel placed already full (never seen empty) stays waiting until the next pour.
- Unexplained event at ~1290 s in the log (pitcher tilted, no gaiwan water, cup1 lifted ~10×); v6 does nothing there.
- The Ableton side: CC 1–5 now mean "present" (127 = on the scale), new CCs 10, 13–16 (drunk), round CC 21 gone (since v5 fix 9).

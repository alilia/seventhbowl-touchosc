# Design notes — v7 (2026-11-01)

## What changed from v6
The vessel logic (below) is v6's. v7 changes what goes out and what is on screen:
- Cups get their own MIDI channel (cup N → channel N). CC 1 = FULL (127 while poured and not drunk), CC 2 = LIFTED (127 off the scale). Both ramp.
- Notes on the cup channel, note-on + note-off together: 36 when lifted, 37 when put back (first 48 / 60, changed by Ilia 2026-11-02); `NOTE_LIFT` / `NOTE_PUT` in the builder.
- Gaiwan sends nothing; its FULL still counts the rounds. Rounds = note-on on channel 16, as before. Pitcher on channel 16, CC 30.
- Gone: the PRESENT and DRUNK CCs, all gaiwan CCs, the old CC numbers (20–26, 1–5, 10–16). DRUNK is still a state: it sends CC 1 = 0.
- SETTINGS column: FULL (fraction of a pour = "half full"), DRUNK (fraction of what was poured), CC 1 rise / fall, CC 2 rise / fall (0–10 s). Faders, quantised; saved in the layout tag (`settings=full,drunk,r1,f1,r2,f2,gfull`). Pitcher gate time and pour hold stay in the builder.
- Every output has a button: the CC 1 and CC 2 toggles (tap = force, ramped). Tapping LIFTED also fires the notes (on = lift note 36, off = put note 37); there are no separate note buttons.
- LIFTED = not present after having been present once, so a cup that was never on the scale does not send CC 2 = 127. The put-back note is only sent after a lift (the first put-down is silent).
- A round change resets CC 1 to 0 (ramped) because the cups go back to waiting. CC 2 is unaffected.

## Changes after the first v7 build (2026-11-02, from the 11-01 and 11-02 ceremony logs)
- **Gaiwan rounds by level** (option A): full = settled weight >= GAIW (0.6) × pour (140k) above the empty level; re-armed when back below empty + REARM (0.25) × pour (no need to hold still: 0.2 s), or when emptied while away. The old state-based count got stuck "full".
- **Empty level** = highest settled non-full weight of the last EMPTY_WIN_S 60 s (kept in tare-shifted units). A lid off-and-on (about -40k, back) or a +45k residue after putting it back no longer counts.
- **Push guard**: a rise above PUSH_POURS 1.4 pours is ignored (pressing read 5–9× the empty weight). A finger resting gave +71k, a small real fill +75k: GAIW 0.6 rejects the finger and misses the 75k fill (the 2026-10-29 fill at 2017 s); GAIW is a fader.
- **Lift / put detected from the movement** (LIFT_STEP 0.2 within LIFT_WIN_MS 400): the note comes 0.02–0.15 s after the hand moves, was 0.3–0.6 s (the reading falls over 0.7 s).
- Status line under the round number shows the reason of the last count ("level up", "arrived full", "ignored (too soon)"); the gaiwan shows "+N% of a pour above empty".
- Replays: 2026-10-29 log 5 rounds (6 before; see above); 11-01 log 5 rounds, the lid events and the "put back empty" are not counted; 11-02 log 5 rounds, the finger push (494 s) and the pressing (614–650 s) are not counted.

## Tested (Lua 5.1, stubbed TouchOSC)
- A whole round from the screen: lift → CC 2 ramps 0→127 in 2.9 s, note 36 on ch 1; put back → note 37, CC 2 → 0; a sip (3/4) stays FULL, CC 1 stays 127; back empty → DRUNK, CC 1 → 0; round change → CC 1 → 0; round notes on ch 16. Nothing on channels 5–15; the gaiwan sends no CC / note.
- Settings faders and their save / restore through the tag.
- Replay of the 2026-10-29 log: rounds 1…6 as in v6; each cup CC 1 = 127 after a pitcher pour and 0 after it was drunk; lift / put notes pair up.
- 300-run fuzz (OSC, drags, captures, clears, rounds, toggles, settings, pitcher): clean; every message is a CC/note on channels 1–4 or 16.

## Not yet done (see the requirements doc)
Show a pour while it happens (O.5); full and drunk never on together is satisfied by construction (one state) but not shown as such; "lid on" note next to EMPTY (C.2); steadiness readout (C.3).

## Logic (one template for gaiwan and cups, runs every frame; unchanged from v6)
- Units: w = (raw - N) / dE (0 = nothing, 1 = empty vessel as captured). Captures: NO and EMPTY only, any order. N is live (tare). Without a calibration everything still works with NO = 0, EMPTY = 1 (simulation).
- Level fader = the input: 0 away, 0.5 = the empty vessel as it stands this round (the reference), 1 = reference + one pour. OSC drives it; a hand drags it (simulation, OSC ignored while held). Same mapping for both, so the logic sees the same thing. The reference is re-taken every round, so the empty vessel sits on the middle line whatever spot it is on.
- PRESENT: w >= 0.5 (PRESENT_AT) for 100 ms (PRESENT_MS); off below 0.45. Measured latency on the log: median 0.13 s, max 0.25 s (incl. the 50 ms test step).
- Settled: still within STILL_BAND 0.03 for SETTLE_MS 300.
- States: waiting -> full -> drunk -> (round) -> waiting.
  - POUR: standing, still for pour_hold (cups 0.5 s, gaiwan: judged by level, see above), rise >= the FULL setting (0.5) × pour (per-vessel setting in counts: gaiwan 140k, cup1 170k, cup2 125k, cup3 185k, cup4 1.2k, from the log) above the base; cups also need the pitcher gate. -> FULL (also a top-up from full / drunk). While full, any further settled rise raises the full weight (pours in steps).
  - DRUNK: a FULL vessel settles after being away, lighter than its full weight by >= DRINK_FRACTION 0.5 of what was poured. Less = stays full (sips add up).
  - ROUND change (gaiwan pour, +1, −1, reset): cups -> waiting, reference re-taken now (or at the next put-down if away). Undrunk cups also go to waiting.
  - An empty vessel (waiting / drunk) that settles re-anchors the reference.
- Pitcher gate (cups, `gate='pitcher'`): open while the pitcher is above POUR_THRESHOLD (or its fader is dragged above 0) and GATE_S 5 s after; a pitcher silent and untouched for GATE_SILENT_S 10 s opens it (weight alone). Note: before ZERO is captured the pitcher reads its own tilt (~76°) as pouring, so the gate is open.
- Rounds: +1 when the gaiwan goes from not-full to full (a second step of the same pour is a top-up, not a round). May go below 0 (warming round); below 0 sends note 0. Every change resets the cups (this works with no OSC too: the logic runs every frame).
- Tare: away, |w| <= tare band (0.4; gaiwan 0.3), still 5 s -> N takes the reading, remembered weights shift (no restart).

## Changes after the first v7 build (2026-11-02, from the 11-01 and 11-02 ceremony logs)
- **Gaiwan rounds by level** (option A): full = settled weight >= GAIW (0.6) × pour (140k) above the empty level; re-armed when back below empty + REARM (0.25) × pour (no need to hold still: 0.2 s), or when emptied while away. The old state-based count got stuck "full".
- **Empty level** = highest settled non-full weight of the last EMPTY_WIN_S 60 s (kept in tare-shifted units). A lid off-and-on (about -40k, back) or a +45k residue after putting it back no longer counts.
- **Push guard**: a rise above PUSH_POURS 1.4 pours is ignored (pressing read 5–9× the empty weight). A finger resting gave +71k, a small real fill +75k: GAIW 0.6 rejects the finger and misses the 75k fill (the 2026-10-29 fill at 2017 s); GAIW is a fader.
- **Lift / put detected from the movement** (LIFT_STEP 0.2 within LIFT_WIN_MS 400): the note comes 0.02–0.15 s after the hand moves, was 0.3–0.6 s (the reading falls over 0.7 s).
- Status line under the round number shows the reason of the last count ("level up", "arrived full", "ignored (too soon)"); the gaiwan shows "+N% of a pour above empty".
- Replays: 2026-10-29 log 5 rounds (6 before; see above); 11-01 log 5 rounds, the lid events and the "put back empty" are not counted; 11-02 log 5 rounds, the finger push (494 s) and the pressing (614–650 s) are not counted.

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

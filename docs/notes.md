# okuma bridge v5 (2026-10-29)

The layout is the same as v4; only texts and the snap fader default (±50 %) differ.

## Why
Load cells read weight x lever arm: the same vessel gives very different numbers depending on where it stands (up to ~29x between sides, dead spot on the gaiwan low side). The fill level can't be read from the number any more. In the ceremony vessels are placed "as centred as possible", so readings wobble around the centred capture on every put-down.

## Behaviour (after fix 9)
- Calibration: one capture per state (NO / EMPTY / WITH TEA), vessel in the middle, buttons in any order. Stored as N plus steps dE = EMPTY-N and dF = TEA-EMPTY, so a tare or a NO recapture moves all three points.
- Weight w = (reading-N)/dE is used only to see events. Every event is measured from where the vessel settled this time (base), never from the captured numbers.
- Off the scale: w below the snap band (default 50 % of the empty step). Robust to drift up to half an empty vessel; an empty vessel on a light spot still reads above it.
- Fill is event-based, 0..100 %, capped (snaps to 0 / 100 within 2 %):
  - POUR: still rise (FULL_HOLD_S 1.5 s) of >= POUR_FRACTION (0.5) x tea step x seat -> 100 % (gaiwan: round +1). seat = how heavy the spot reads vs the capture, measured at put-down, clamped POUR_SEAT_MIN 0.5 .. 1 (threshold only shrinks).
  - SIP: off the scale >= MIN_LIFT_S (2 s) and back -> fill - sip. Cups 0.33 (three sips -> 0), gaiwan 1.0. Never rises on a return.
  - Gaiwan `pour_on_return`: comes back heavier than it left -> pour.
  - Never left the scale (hand on it, slid, lid lifted): the base is kept, so a pour made meanwhile still counts; no sip.
  - EVERY ROUND CHANGE (gaiwan pour or the round buttons, any direction) sets all cups' fill to 0 (`reset_on_round`). The sips are only a heuristic, so the round count re-syncs them. The gaiwan itself is not reset.
- Round notes (fix 8, 9): every change of the round count sends ONE MIDI message: note-on, channel 1, velocity 127, note number = the round count (note 0 = reset, also when pressed at 0; note 1 = round 1; +1 per round, up to 127). No note-off and no CC are sent. The `note` of the rounds line in SENSORS (now 0) shifts the range. The round fader on the screen only mirrors the count and no longer carries a CC.
- Fill CC movement (unchanged from v4): falls linearly over FALL_S (5 s), rises with a smoothing time constant RISE_TAU (0.6 s). Holds while the vessel is lifted.
- Lift CC (fix 5, reworked in fix 6, 7): a ramp, not a switch. The TARGET is 127 while the vessel is away (below the snap band, until it has settled again) and 0 while it stands. The script sends the CC itself with sendMIDI, moving linearly to the target: LIFT_RISE_S (0 -> 127) and LIFT_FALL_S (127 -> 0), both start at 3 s, 0 = jump. Cups CC 1–4, gaiwan CC 5. Slides, hands and lid lifts do not move it. The lift toggle under each column shows the target (lit = lifted) and carries no MIDI message itself. A hand tap on it sets the target the same way and ramps identically, also with no sensor connected and nothing calibrated; the sensor takes over again at its next lift / put-down. The label under the column shows the target.
- Tare: all cells, whenever the vessel is away (NOT at the round change itself: cups stand there empty), within TARE_BAND (0.4; gaiwan tare_band 0.10 so a lid alone isn't tared) and still TARE_HOLD_S 5 s. Covers long sips and empty-scale periods. Does not restart the state machine (shifts remembered weights instead).
- Status line shows `seat x.xx` = the current spot's reading vs the centred capture (use it to measure wobble).
- Tag: `id=v5:N,dE,dF,fill`; v3/v4 tags `N,E,F` are converted. Captures waiting for NO / EMPTY are not saved in the tag.

## Ceremony facts (2026-10-29)
- Cups stand EMPTY on the scale at round start (not off the scale).
- Tea is never poured into a cup while it is held.
- Cups are emptied (fill 0) on each round count.
- The lag (3 s up, 3 s down) is wanted on the LIFT value, not on the fill, and also when the lift toggle is tapped by hand.
- Round notes: channel 1, start at note 0, +1 per round, reset jumps back to note 0 and sends it. Only note-on with velocity 127: no note-off, no CC.

## Fix 1 (wobble review before first test)
Bugs found in the first v5 build:
- Gaiwan lifted > 5 s (pouring out) was auto-tared mid-lift; the tare restarted the state machine and the return was lost -> gaiwan stayed at 127 after pouring out.
- Same for a cup sip > 5 s right after a round change -> sip lost.
- Third sip left fill at 1 % (MIDI 1), not 0.
Wobble changes: off-band 50 %, seat-scaled pour threshold, base kept when the vessel never left, lift CC only for real lifts, tare on every empty still period (replaces round-start arming; TARE_AT_ROUND / TARE_GUARD removed).

## Fix 2 (first real test)
EMPTY (and WITH TEA) were silently ignored unless NO was captured first (v4 allowed any order). Now any order works: a value captured before its reference waits and is converted when NO / EMPTY arrives. Recapturing EMPTY keeps WITH TEA's absolute value.

## Fix 3 (second real test: "freezes, values don't update")
Runtime error in the update loop: with NO and EMPTY captured but no WITH TEA yet, the pour watcher did arithmetic on a missing tea step (nil) once the weight had been still for 1.5 s. update() threw every frame, so the whole script stopped (values frozen, OSC still arriving). Now the watcher just follows the weight until a tea step exists. Found by a random-sequence fuzz test (300 runs) that now runs clean. Lesson: test partial calibration states, not only complete ones.

## Fix 4
Cups are emptied on each round count (see Behaviour). New per-sensor flag `reset_on_round` (cups).

## Fix 5
Lag on the LIFT CC in both directions (`LIFT_RISE_S`, `LIFT_FALL_S`, 3 s each). First built by mistake on the fill CCs (misread request); reverted the same day, so FALL_S 5 / RISE_TAU 0.6 stay as in v4.

## Fix 6
A manual tap on the lift toggle must ramp too. The toggle can't ramp a tap itself (it jumps to 0/1 and sends at once), so the toggle no longer carries the CC; the script sends it with sendMIDI for sensor and tap alike. Changes the MIDI source of CC 1–5 and the toggle's role: the CC map is unchanged, the toggle's own MIDI message is gone.

## Fix 7 (third real test: "sends nothing when opening the file and clicking the toggle")
The ramp only started once the cell had been calibrated and had received a reading, so on a freshly opened file with nothing connected the tap did nothing. The ramp now runs on every frame from the start (initial target 0, on the scale). Tested with nothing connected and nothing calibrated: tap on = CC 5 ramps 0 -> 127 in 3 s, tap off ramps back. Lesson: test the empty / fresh-open state too.

## Fix 8
Round notes now start at note 0 instead of 60 (`note=0` of the rounds line in SENSORS). Changes the MIDI map: the Ableton side must listen to notes 0, 1, 2 … on channel 1 instead of 60, 61, 62 ….

## Fix 9
Round counter sends only the note-on, velocity 127: the note-off after 150 ms and the round CC 21 are removed. The round fader lost its MIDI message (it still mirrors the count on screen; the title now reads "note 0+" instead of "CC 21"), the note-off timer and the `ROUND_NOTE_MS` setting are gone. Tested: +1, +1, −1, reset (two presses) sends exactly note-on 1, 2, 1, 0 on channel 1 (status 0x90, velocity 127) and nothing else.

## Config
POUR_FRACTION 0.5, DRIFT_FRACTION 0.15, POUR_SEAT_MIN 0.5, MIN_LIFT_S 2, FULL_HOLD_S 1.5, FALL_S 5, RISE_TAU 0.6, LIFT_RISE_S 3, LIFT_FALL_S 3, SNAP_DEFAULT 0.5 (SNAP_MAX 1.0), TARE_BAND 0.4, TARE_HOLD_S 5; per sensor: sip, pour_on_return, tare_band, reset_on_round; rounds: note 0 (its `cc` value is no longer sent).

## Known limits / open
- Needs real wobble numbers: seat range for each vessel placed "centred" (empty and full).
- A spot reading below half the empty step looks like an empty scale (gaiwan dead side!).
- A cup slid to a heavier spot by more than the pour rise (~0.25 empty step on cup1) counts as a pour.
- Cup4 (50 kg half-bridge): at session start press NO; drift above half its empty step looks like a cup.
- A vessel placed already full (never seen empty) shows 0 % until the next pour.
- Lift CC numbering clashes beyond four cups.
- Note 0 is C-2 in Ableton; C0 would be note 24 (one setting).

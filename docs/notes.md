# okuma bridge v4 — TouchOSC layout

v3 structure (Python builder + Lua template, battery, layout order, v3 control names) merged with Greg's v12 fill behaviour, lift CCs and round notes. Built by `build_okuma_layout.py` from `okuma_bridge.template.lua`; all settings live in the Python CONFIG section.

## MIDI map (channel 1, MIDI connection 1)

| What | MIDI |
|---|---|
| Gaiwan fill | CC 20 |
| Round count | CC 21 (value = round number) |
| Pitcher tilt | CC 22 |
| Cup 1–4 fill | CC 23–26 |
| Lift (127 = lifted, 0 = on the scale) | cup1–4 = CC 1–4, gaiwan = CC 5 |
| Round notes | note 60 + round (60 = reset, 61 = round 1 …), short note (150 ms) |

## Behaviour

- **Fill (from v12):** empty = 0 … with tea = 127, capped. The three capture buttons (NO, EMPTY, WITH TEA) only calibrate the weight.
- **Lift detection (from v3):** state machine. A drop of more than `LIFT_DROP` below the settled weight = lifted, at once; settled again after `SETTLE_MS` of stillness.
- **While lifted / placing / empty scale:** fill CC holds; lift CC = 127.
- **After a put-down:** less tea → glides down linearly over `FALL_S` (default 5 s); more tea → follows with `RISE_TAU` smoothing (default 0.6 s).
- **Lift toggle** under each load-cell column carries the lift CC; hand taps send it too; the sensor overwrites it only at its next lift / put-down.
- **Rounds (from v3):** +1 when the gaiwan settles at 95 % of the tea point; re-arms below 75 %; 3 s minimum gap; no cap. Every change (full, +1, −1, reset) fires the note; reset needs two presses within 3 s and always fires note 60. Dragging the gaiwan fader does NOT count rounds.
- **Pitcher:** unchanged from v3 (tiltx / tilty, ZERO, 10° gate, range fader).
- **OSC in:** root `onReceiveOSC` only; status / battery labels are display-only.
- Calibration and round count persist in the root tag; v3 tags are read back.

## Not carried over from v12

`/okuma/reset` OSC address, the old single `/okuma/imu1/tilt` address, the 10-round cap.

# TouchOSC OSC routing — probe results (2026-10-14)

Question: how does incoming OSC reach the scripts, and does v4's "backup OSC route" (receiver labels → root:notify) cause double handling?

Setup: load-cells-v2 firmware unchanged, only cup1 connected (/okuma/cup1, ESP32) → TouchOSC on Windows, OSC UDP receive port 10000. TouchOSC version: not recorded.
Files (removed after v4, they use that builder's helpers; see the v4 commit): `build_osc_probes.py` (A/B/C, `--receiver /okuma/cup1` for the cup1 variants), `make_probe_d.py` (real layout + handleOsc counter; `--template okuma_bridge.template.lua`).

| probe | root got cup1 | label got cup1 | counts (root / label) | notes |
|---|---|---|---|---|
| A — root only, no receiver | yes | n/a | 42 / – | root onReceiveOSC gets addresses no control listens on |
| B_cup1 — receiver label, root returns false | yes | yes | 20 / 20 | every message handled twice; always root first, then label (pairs root>label 20) |
| C_cup1 — receiver label, root returns true | yes | no | 18 / 0 | returning true from root stops delivery to controls |
| D — real v3 layout + counter | yes | no | 33 calls (33 / 0), 0 dups | root returns handleOsc() = true for known paths → route 2 never fires |

(B's receiver label showed its own count 21 vs 20: its local counter isn't cleared by RESET, so one message from before the reset.)

## Findings
- The root script gets every incoming OSC message first, whether or not any control has a matching receive message.
- If the root returns false, TouchOSC then delivers the message to matching receive-enabled controls → the label route fires too, so each reading is handled twice.
- If the root returns true, controls don't get the message.
- v3/v4 return true for routed paths, so the label route is dead code today. It would only fire (and double the capture average) for messages the root rejects, or if the root ever returned false.

## Decision
Keep route 1 only: root onReceiveOSC → handleOsc. Remove the receive message and RECEIVER_SCRIPT from the status/battery labels (make them display-only); drop the `osc:` branch in onReceiveNotify.

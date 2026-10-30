#!/usr/bin/env python3
"""
okuma interactive — TouchOSC layout generator (v6)
==================================================

Builds  okuma_bridge.tosc  (the TouchOSC layout) and
        okuma_bridge.lua   (readable copy of the root script)
from the CONFIG section below and the Lua template next to this file.

    python build_okuma_layout.py            # writes both files next to this script
    python build_okuma_layout.py --xml      # also writes the readable XML (debugging)

Only the Python standard library is used.

v6 = vessels as on/off states (present / full / drunk) with ramps, the level fader as
input (OSC or a hand), pitcher gate, negative rounds.
v5 = v4 + fill by EVENTS (pour / sip) instead of by weight, steps stored as offsets,
tare whenever the scale is empty and still, wobble-proof events (v5 fix 1).
v4 = v3 structure + from Greg's v12: fill CC 0 (empty) … 127 (full) that holds
while lifted and glides, lift CCs + lift toggles, round notes.

How a .tosc file works
----------------------
A .tosc file is XML, zlib-compressed. The XML is a tree of <node>s:
a GROUP (the root) with <children> — faders, buttons, labels, text.
Each node has <properties> (frame, colour, name, script, …), <values>
(x, touch, text …) and optionally <messages> (MIDI / OSC it sends).
The helpers below write exactly those pieces; the layout functions
place them on screen.

TouchOSC's Lua is restricted
----------------------------
Lua 5.1 with only: error ipairs next pairs print select tonumber tostring
unpack type + table / math (+ math.clamp) / string. No setmetatable, pcall,
assert, require, load. Scripts that touch any other global fail at start with
"attempt to call global ... (a nil value)". Keep the template and the small
scripts in this file within that list.

Single source of truth
----------------------
SENSORS below drives both the layout AND the script: the generator writes
the sensor list into the Lua template (at --@@CONFIG@@), so the two never
disagree. To add a load cell, add one line to SENSORS and rebuild.
"""

import argparse
import uuid
import zlib
from pathlib import Path

# ============================================================================
#  CONFIG — edit here
# ============================================================================

OUTPUT_NAME  = 'okuma_bridge'                 # -> .tosc and .lua
LUA_TEMPLATE = 'okuma_bridge.template.lua'

MIDI_CHANNEL = 1                                 # 1–16
MIDI_CONNECTION = 1                              # TouchOSC connection used for MIDI out

# Order = order on screen (follows the performance).
#   kind     'loadcell', 'tilt' or 'rounds'
#   id       internal name, used in control names (letters/digits only)
#   title    shown on top of the group
#   noun     load cells: used on the first button ("NO <noun>")
#   osc      incoming value address (load cells; not for 'rounds' / 'tilt')
#   osc_tilt, osc_dir   'tilt' only: the module's total tilt (0–180°) and lean direction (0–360°)
#   battery  incoming battery address (0–100 %) — placeholder until decided
#   source   'rounds' only: the id of the load cell whose "full" it counts
#   cc       vessels: CC of FULL (on = more full than empty); pitcher: CC of its tilt fader;
#            rounds: not sent (kept for the order). Fixed accessories first (gaiwan 20,
#            rounds 21, pitcher 22), cups last (23+) — the v4 / v5 fill numbers
#   present_cc  vessels: CC of PRESENT (on = on the scale) — the v4 / v5 lift numbers
#               (cups 1–4, gaiwan 5); note: 127 now means ON the scale
#   drunk_cc    vessels: CC of DRUNK (on = an empty vessel that was drunk) — new:
#               10 + the vessel's position in the fill order (gaiwan 10, cups 13–16)
#   pour     vessels: the weight of one pour in counts (the rise a pour gives). From the
#            2026-10-29 log; a pour counts at POUR_FRACTION of it
#   pour_hold  optional: own POUR_HOLD_S (the gaiwan waits longer: lid and hands)
#   gate     'pitcher': this vessel can only become full while the pitcher pours (or
#            GATE_S after). Cups only: the gaiwan's water comes from the kettle
#   reset_on_round  every round change sets this vessel to WAITING and re-takes its
#                   reference (cups)
#   tare_band       optional: own TARE_BAND. Gaiwan 0.3: its empty scale drifted 83k counts in the
#                   40-minute log (0.47 of the gaiwan), 10–30k between two pour-outs
#   note     'rounds' only: the note of round 0; round n sends note + n, below 0 sends
#            note (note-on, velocity 127, channel MIDI_CHANNEL; no note-off, no CC)
#   color    hex colour of the group
SENSORS = [
    dict(kind='loadcell', id='gaiwan',  title='GAIWAN',  noun='GAIWAN',
         osc='/okuma/gaiwan',    battery='/okuma/gaiwan/battery', color='#d39b4a',
         cc=20, present_cc=5, drunk_cc=10, pour=100000, pour_hold=1.0, tare_band=0.3),
    dict(kind='rounds',   id='rounds',  title='ROUNDS',  source='gaiwan',
         cc=21, note=0, color='#e6c84d'),
    dict(kind='tilt',     id='pitcher', title='PITCHER',
         osc_tilt='/okuma/imu1/tilt', osc_dir='/okuma/imu1/dir',
         battery='/okuma/imu1/battery',                          cc=22, color='#9a80f2'),
    dict(kind='loadcell', id='cup1',    title='CUP 1',   noun='CUP',
         osc='/okuma/cup1',      battery='/okuma/cup1/battery',   color='#33bfb3',
         cc=23, present_cc=1, drunk_cc=13, pour=170000, gate='pitcher', reset_on_round=True),
    dict(kind='loadcell', id='cup2',    title='CUP 2',   noun='CUP',
         osc='/okuma/cup2',      battery='/okuma/cup2/battery',   color='#8ccc4d',
         cc=24, present_cc=2, drunk_cc=14, pour=125000, gate='pitcher', reset_on_round=True),
    dict(kind='loadcell', id='cup3',    title='CUP 3',   noun='CUP',
         osc='/okuma/cup3',      battery='/okuma/cup3/battery',   color='#e66673',
         cc=25, present_cc=3, drunk_cc=15, pour=185000, gate='pitcher', reset_on_round=True),
    dict(kind='loadcell', id='cup4',    title='CUP 4',   noun='CUP',
         osc='/okuma/cup4',      battery='/okuma/cup4/battery',   color='#4d9ae6',
         cc=26, present_cc=4, drunk_cc=16, pour=1200, gate='pitcher', reset_on_round=True),
]

# Vessels (gaiwan, cups). Weights in empty-vessel units w: 0 = nothing on the scale,
# 1 = the empty vessel as captured (NO and EMPTY buttons).
#   PRESENT_AT     on the scale from this weight (half an empty vessel); off below
#                  PRESENT_AT - PRESENT_HYST. PRESENT_MS = how long before it flips
#                  (ignores single-reading glitches)
#   STILL_BAND     "still" = the weight stays within this band
#   SETTLE_MS      still this long after a put-down = settled (the drunk test and the
#                  reference are taken then)
#   POUR_HOLD_S    a rise must stay still this long to count as a pour
#   POUR_FRACTION  a pour = a rise of at least this fraction of the vessel's `pour`
#   DRIFT_FRACTION a still rise below this fraction of `pour` is drift (the base follows)
#   DRINK_FRACTION a FULL vessel back from the lips lighter by at least this fraction of what
#                  was poured = DRUNK
#   GATE_S         the pitcher gate stays open this long after the pitcher stops pouring
#   GATE_SILENT_S  a pitcher that has sent nothing (and was not touched) this long opens the
#                  gate, so the cups still work on weight alone
PRESENT_AT     = 0.5
PRESENT_HYST   = 0.05
PRESENT_MS     = 100
STILL_BAND     = 0.03
SETTLE_MS      = 300
POUR_HOLD_S    = 0.5
POUR_FRACTION  = 0.5
DRIFT_FRACTION = 0.15
DRINK_FRACTION = 0.5
GATE_S         = 5
GATE_SILENT_S  = 10

# Output ramps: every vessel output is on/off and moves linearly to its new value.
# Seconds for 0 -> 127 (RISE) and 127 -> 0 (FALL); 0 = jump. Shared by all vessels.
PRESENT_RISE_S, PRESENT_FALL_S = 3.0, 3.0
FULL_RISE_S,    FULL_FALL_S    = 3.0, 3.0
DRUNK_RISE_S,   DRUNK_FALL_S   = 3.0, 3.0

# Auto-tare (all vessels): away, within TARE_BAND of NO and still for TARE_HOLD_S seconds ->
# that reading becomes the new NO; everything remembered moves with it. A vessel's
# tare_band overrides it. Keep it below PRESENT_AT - PRESENT_HYST. 0 seconds = off
TARE_BAND   = 0.4
TARE_HOLD_S = 5

# Round counter (+1 every time water is poured into the gaiwan, +1 / −1 / reset by hand).
# It may go below 0 (a warming round). Every change resets the cups (reset_on_round).
#   ROUND_MIN_GAP_S   ignore a gaiwan pour less than this many seconds after the last count
#   RESET_CONFIRM_S   the reset button must be pressed twice within this time
ROUND_MIN_GAP_S = 3
RESET_CONFIRM_S = 3

# Pitcher. total tilt = angle between the pitcher's current direction and its ZERO direction,
# built from the module's tilt + dir. ZERO button = pitcher resting; the range fader = pour
# angle (max).
#   POUR_THRESHOLD    below this tilt the output is 0 (and the cups' gate does not open)
#   RANGE_*           range fader: the angle that gives MIDI 127 (min, max, step, start)
POUR_THRESHOLD = 10
RANGE_MIN, RANGE_MAX, RANGE_STEP = 10, 180, 5
RANGE_DEFAULT = 90

# Note shown in the pitcher column (TEXT control, multi-line)
NOTE = """MIDI ch {ch}. Pitcher: tilt from the
ZERO pose; below {thr}° -> 0. ZERO with
the pitcher resting. Pouring opens the
cups' gate for {gate:g} s.

Vessels: capture NO and EMPTY, vessel
in the MIDDLE. The big fader is the
input: 0 away, middle = empty (this
round), top = one pour. Drag it to test
without sensors. PRESENT / FULL /
DRUNK = CCs, ramped; tap to force.
Battery: 0–100 on <module>/battery"""

# Look
COL_W, COL_GAP, MARGIN = 230, 10, 20
CANVAS_H   = 800
BACKGROUND = '#0f0f12'
DIM_TEXT   = '#8c99a6'
WHITE      = '#ffffff'
PARAM      = '#999999'
POINT_COLORS = {'none': '#596169', 'empty': '#cccccc'}

# ============================================================================
#  END CONFIG
# ============================================================================


# ---------------------------------------------------------------------------
#  XML building blocks
# ---------------------------------------------------------------------------
def cdata(s):
    return '<![CDATA[' + str(s).replace(']]>', ']]]]><![CDATA[>') + ']]>'


def rgba(hex_color, a=1):
    h = hex_color.lstrip('#')
    return tuple(round(int(h[i:i + 2], 16) / 255, 3) for i in (0, 2, 4)) + (a,)


def prop(kind, key, value):
    """One <property>. kind: b(ool) i(nt) f(loat) s(tring) c(olour) r(ect)."""
    if kind == 'b':
        v = int(bool(value))
    elif kind in ('i', 'f'):
        v = value
    elif kind == 's':
        v = cdata(value)
    elif kind == 'c':
        r, g, b, a = value
        v = f'<r>{r}</r><g>{g}</g><b>{b}</b><a>{a}</a>'
    elif kind == 'r':
        x, y, w, h = value
        v = f'<x>{x}</x><y>{y}</y><w>{w}</w><h>{h}</h>'
    else:
        raise ValueError(kind)
    return f"<property type='{kind}'><key>{cdata(key)}</key><value>{v}</value></property>"


def value(key, default, locked_default_current=0):
    return (f'<value><key>{cdata(key)}</key><locked>0</locked>'
            f'<lockedDefaultCurrent>{locked_default_current}</lockedDefaultCurrent>'
            f'<default>{cdata(default)}</default><defaultPull>0</defaultPull></value>')


TOUCH_VALUE = value('touch', 'false')


def base_props(name, frame, color, interactive=True, outline=True, background=True):
    """Properties every control has."""
    return ''.join([
        prop('b', 'background', background), prop('c', 'color', color),
        prop('f', 'cornerRadius', 1), prop('r', 'frame', frame),
        prop('b', 'grabFocus', True), prop('b', 'interactive', interactive),
        prop('b', 'locked', False), prop('s', 'name', name),
        prop('i', 'orientation', 0), prop('b', 'outline', outline),
        prop('i', 'outlineStyle', 1), prop('i', 'pointerPriority', 0),
        prop('i', 'shape', 1), prop('b', 'visible', True),
    ])


def text_props(size, text_color, align):
    """Extra properties for LABEL / TEXT. align: 0 left, 2 centre."""
    return ''.join([
        prop('i', 'font', 0), prop('i', 'textAlignH', align), prop('i', 'textAlignV', 2),
        prop('b', 'textClip', True), prop('c', 'textColor', rgba(text_color)),
        prop('i', 'textLength', 0), prop('i', 'textSize', size),
    ])


def node(kind, properties, values, messages=''):
    return (f"<node ID='{uuid.uuid4()}' type='{kind}'><properties>{properties}</properties>"
            f'<values>{values}</values>{messages}</node>')


def midi_cc_message(cc):
    """MIDI CC on MIDI_CHANNEL, value = control x scaled 0–127, sent on any change."""
    connections = ''.join('1' if i == MIDI_CONNECTION else '0' for i in range(10, 0, -1))
    return (
        '<messages><midi><enabled>1</enabled><send>1</send><receive>0</receive>'
        f'<feedback>0</feedback><noDuplicates>1</noDuplicates><connections>{connections}</connections>'
        f'<triggers><trigger><var>{cdata("x")}</var><condition>ANY</condition></trigger></triggers>'
        f'<message><type>CONTROLCHANGE</type><channel>{MIDI_CHANNEL - 1}</channel>'
        f'<data1>{cc}</data1><data2>0</data2></message><values>'
        f'<value><type>CONSTANT</type><key>{cdata("")}</key><scaleMin>0</scaleMin><scaleMax>15</scaleMax></value>'
        f'<value><type>CONSTANT</type><key>{cdata("")}</key><scaleMin>0</scaleMin><scaleMax>1</scaleMax></value>'
        f'<value><type>VALUE</type><key>{cdata("x")}</key><scaleMin>0</scaleMin><scaleMax>127</scaleMax></value>'
        '</values></midi></messages>')


# ---------------------------------------------------------------------------
#  Controls
# ---------------------------------------------------------------------------
def fader(name, frame, color, default=0.0, cc=None, grid=False, grid_steps=10):
    """Vertical fader. With cc it sends MIDI; touchable either way."""
    props = base_props(name, frame, rgba(color)) + ''.join([
        prop('b', 'bar', True), prop('i', 'barDisplay', 0), prop('b', 'cursor', True),
        prop('i', 'cursorDisplay', 0), prop('b', 'grid', grid),
        prop('c', 'gridColor', (0, 0, 0, 0.25)), prop('i', 'gridSteps', grid_steps),
        prop('i', 'response', 0), prop('i', 'responseFactor', 100),
    ])
    return node('FADER', props, value('x', default) + TOUCH_VALUE,
                midi_cc_message(cc) if cc is not None else '')


def label(name, frame, text, size=14, color=WHITE, align=2, background=None):
    """Single-line, non-interactive, display-only text.
    (Incoming OSC is handled by the root script only — see touchosc/osc-routing-probes.md.)"""
    bg = rgba(background) if background else (0, 0, 0, 0)
    props = base_props(name, frame, bg, interactive=False, outline=False,
                       background=background is not None) + text_props(size, color, align)
    return node('LABEL', props, value('text', text, 1) + TOUCH_VALUE)


def text_box(name, frame, text, size=12, color=DIM_TEXT, background='#1a1a1f'):
    """TEXT control — used for the multi-line note."""
    props = base_props(name, frame, rgba(background), interactive=False, outline=False) + \
        text_props(size, color, 0)
    return node('TEXT', props, value('text', text, 1) + TOUCH_VALUE)


def button(name, frame, color, notify_key, background=True):
    """Momentary button that tells the root script '<notify_key>, <its own name>' on press.
    background=False: only outline + press highlight, so text drawn underneath stays visible."""
    script = ("function onValueChanged(key)\n"
              "  if key == 'x' and self.values.x > 0.5 then   -- on press only\n"
              f"    root:notify('{notify_key}', self.name)\n"
              "  end\n"
              "end")
    props = base_props(name, frame, color if isinstance(color, tuple) else rgba(color),
                       background=background) + ''.join([
        prop('i', 'buttonType', 0), prop('b', 'press', True), prop('b', 'release', True),
        prop('b', 'valuePosition', False), prop('s', 'script', script),
    ])
    return node('BUTTON', props, value('x', 0) + TOUCH_VALUE)


def toggle(name, frame, color, cc=None):
    """Toggle button (on press) that carries its own MIDI CC: on = 127, off = 0.
    No background, so the text underneath stays readable; lit (filled) when on."""
    props = base_props(name, frame, color, background=False) + ''.join([
        prop('i', 'buttonType', 2), prop('b', 'press', True), prop('b', 'release', True),
        prop('b', 'valuePosition', False),
    ])
    return node('BUTTON', props, value('x', 0) + TOUCH_VALUE, midi_cc_message(cc) if cc is not None else '')


def labelled_button(name, frame, color, notify_key, texts):
    """A button with text on it.
    Z-order matters: TouchOSC sends a touch to the TOPMOST control, so labels
    placed over a button swallow the press. We draw a coloured box and the
    text first, then a transparent button on top of everything.
    texts: list of (control_name, (dx, dy, h), text, size, text_color)."""
    x, y, w, h = frame
    items = [label(f'{name}_box', frame, '', 12, WHITE, background=color)]
    for tname, (dx, dy, th), text, size, tcolor in texts:
        items.append(label(tname, (x + dx, y + dy, w - 2 * dx, th), text, size, tcolor))
    items.append(button(name, frame, rgba(WHITE, 0.35), notify_key, background=False))
    return items


# ---------------------------------------------------------------------------
#  Groups (one column per sensor)
# ---------------------------------------------------------------------------
def header(s, x, with_clear):
    """Title, clear button, battery and status lines — shared by all columns."""
    sid = s['id']
    title_w = COL_W - 70 if with_clear else COL_W
    title = s['title'] if s['kind'] == 'loadcell' else f"{s['title']}   CC {s['cc']}"
    out = [label(f'{sid}_title', (x, 15, title_w, 36), title, 18, s['color'], align=0)]
    if with_clear:
        out += labelled_button(f'clr_{sid}', (x + COL_W - 60, 18, 60, 30), '#4d4d4d', 'clear',
                               [(f'{sid}_clr_lbl', (0, 0, 30), 'clear', 12, '#d9d9d9')])
    out += [label(f'{sid}_bat', (x, 54, COL_W, 22), 'battery —', 12, DIM_TEXT, align=0),
            label(f'{sid}_status', (x, 78, COL_W, 22), '—', 12, DIM_TEXT, align=0)]
    return out


def output(s, x):
    """The big MIDI fader and its value line."""
    sid = s['id']
    if s['kind'] == 'loadcell':        # the level fader: input, no MIDI; line at the middle (= empty)
        return [fader(f'{sid}_out', (x + 5, 138, 100, 320), s['color'], 0, grid=True, grid_steps=2),
                label(f'{sid}_outval', (x, 464, COL_W, 28), '—', 13, WHITE, align=0)]
    return [fader(f'{sid}_out', (x + 5, 138, 100, 320), s['color'], 0, cc=None if s['kind'] == 'rounds' else s['cc']),
            label(f'{sid}_outval', (x, 464, COL_W, 28), 'MIDI —', 14, WHITE, align=0)]


def loadcell_column(s, x):
    """Vessel: level fader (input), PRESENT / FULL / DRUNK tap toggles (CC ramps), state,
    NO / EMPTY captures."""
    sid = s['id']
    rx, rw = x + 112, COL_W - 112
    items = header(s, x, with_clear=True) + output(s, x) + [
        label(f'{sid}_lv_full', (x + 108, 132, 46, 16), '← full', 10, DIM_TEXT, align=0),
        label(f'{sid}_lv_empty', (x + 108, 290, 46, 16), '← empty', 10, DIM_TEXT, align=0),
        label(f'{sid}_lv_away', (x + 108, 442, 46, 16), '← away', 10, DIM_TEXT, align=0),
    ]
    for k, (out, cc) in enumerate([('present', s['present_cc']), ('full', s['cc']),
                                   ('drunk', s['drunk_cc'])]):
        frame = (x + 154, 156 + k * 82, COL_W - 154, 72)
        items += [label(f'{sid}_{out}_box', frame, '', 12, WHITE, background='#26262c'),
                  label(f'{sid}_{out}_name', (frame[0], frame[1] + 8, frame[2], 24), out.upper(), 12, WHITE),
                  label(f'{sid}_{out}_val', (frame[0], frame[1] + 38, frame[2], 22), f'CC {cc} = 0', 10, DIM_TEXT),
                  toggle(f'{sid}_{out}', frame, rgba(s['color'], 0.55))]
    items.append(label(f'{sid}_state', (x + 108, 404, COL_W - 108, 30), 'WAITING', 14, s['color']))
    points = [('none', f"NO {s['noun']}"), ('empty', f"EMPTY {s['noun']}")]
    for k, (point, title) in enumerate(points):
        y = 500 + k * 80
        text_color = '#000000' if point == 'empty' else WHITE
        items += labelled_button(f'cap_{sid}_{point}', (x, y, COL_W, 72), POINT_COLORS[point], 'capture',
                                 [(f'{sid}_{point}_lbl', (0, 8, 28), title, 15, text_color),
                                  (f'{sid}_{point}_val', (0, 38, 24), '—', 13, text_color)])
    gate = '   gate: pitcher' if s.get('gate') else ''
    items.append(text_box(f'{sid}_info', (x, 664, COL_W, 120),
                          f"pour {s['pour']} counts{gate}\n"
                          f"FULL CC {s['cc']} · PRESENT CC {s['present_cc']}\n"
                          f"DRUNK CC {s['drunk_cc']}" +
                          ("\nresets every round" if s.get('reset_on_round') else ""), size=11))
    return items


def tilt_column(s, x):
    """Pitcher: readouts, range fader, ZERO button."""
    sid = s['id']
    px, pw = x + 112, 60
    rx = x + 178
    steps = (RANGE_MAX - RANGE_MIN) // RANGE_STEP
    range_default = round((RANGE_DEFAULT - RANGE_MIN) / RANGE_STEP) / steps
    note = NOTE.format(ch=MIDI_CHANNEL, thr=f'{POUR_THRESHOLD:g}', gate=GATE_S)
    items = header(s, x, with_clear=False) + output(s, x) + [
        label(f'{sid}_in_tilt', (px, 138, pw, 22), 'in —', 11, DIM_TEXT, align=0),
        label(f'{sid}_in_dir', (px, 162, pw, 22), 'dir —', 11, DIM_TEXT, align=0),
        label(f'{sid}_tilt_lbl', (px, 200, pw, 20), 'tilt', 11, DIM_TEXT, align=0),
        label(f'{sid}_tilt', (px, 220, pw, 32), '—', 18, s['color'], align=0),
        label(f'{sid}_pour', (px, 256, pw, 22), '—', 11, DIM_TEXT, align=0),
        label(f'{sid}_range_lbl', (rx - 7, 110, 60, 24), 'range', 12, DIM_TEXT),
        fader(f'{sid}_range', (rx, 138, 46, 270), PARAM, range_default, grid=True),
        label(f'{sid}_range_val', (rx - 17, 412, 80, 20), f'0 … {RANGE_DEFAULT}°', 11, DIM_TEXT),
    ]
    items += labelled_button(f'cap_{sid}_zero', (x, 500, COL_W, 64), '#596169', 'capture',
                             [(f'{sid}_zero_lbl', (0, 6, 28), 'ZERO  (resting)', 15, WHITE),
                              (f'{sid}_zero_val', (0, 34, 24), '—', 13, WHITE)])
    items.append(text_box('note', (x, 576, COL_W, 208), note, size=12))
    return items


def rounds_column(s, x):
    """Round counter: big number, +1 / -1 / reset, MIDI fader (mirrors the count)."""
    sid = s['id']
    bx, bw = x + 112, COL_W - 112
    items = [
        label(f'{sid}_title', (x, 15, COL_W, 36), f"{s['title']}   note {s['note']}+", 18, s['color'], align=0),
        label(f'{sid}_status', (x, 78, COL_W, 22), '—', 12, DIM_TEXT, align=0),
    ] + output(s, x) + [
        label(f'{sid}_count_lbl', (bx, 110, bw, 20), 'round', 12, DIM_TEXT),
        label(f'{sid}_count', (bx, 132, bw, 96), '0', 64, s['color']),
    ]
    for k, (op, text, color) in enumerate([('inc', '+1', '#4d4d4d'), ('dec', '−1', '#4d4d4d'),
                                           ('zero', 'reset', '#7a2e2e')]):
        items += labelled_button(f'rnd_{sid}_{op}', (bx, 244 + k * 72, bw, 62), color, 'round',
                                 [(f'{sid}_{op}_lbl', (0, 16, 30), text, 18 if op != 'zero' else 15, '#f2f2f2')])
    items.append(text_box(f'{sid}_note', (x, 500, COL_W, 280),
                          f"""+1 each time water is poured
into the {s['source']}. Starts at 0;
−1 below 0 = a warming round.

Every change sends one MIDI
note-on, channel {MIDI_CHANNEL}, velocity 127
(no note-off, no CC):
note {s['note']} = round 0 and below,
{s['note'] + 1} = round 1 …
Every change resets the cups.

+1 / −1 correct it (same effect).
reset: press twice (within {RESET_CONFIRM_S} s).
The fader only shows the count."""))
    return items


COLUMN_BUILDERS = {'loadcell': loadcell_column, 'tilt': tilt_column, 'rounds': rounds_column}


# ---------------------------------------------------------------------------
#  Script + document
# ---------------------------------------------------------------------------
def lua_string(s):
    return "'" + str(s).replace('\\', '\\\\').replace("'", "\\'") + "'"


def render_lua(template):
    """Write the CONFIG section of the Lua template from the Python config."""
    rows = []
    for s in SENSORS:
        fields = [f"kind = {lua_string(s['kind'])}", f"id = {lua_string(s['id'])}"]
        if s.get('osc'):
            fields.append(f"osc = {lua_string(s['osc'])}")
        if s.get('osc_tilt'):
            fields.append(f"osc_tilt = {lua_string(s['osc_tilt'])}, osc_dir = {lua_string(s['osc_dir'])}")
        if s.get('source'):
            fields.append(f"source = {lua_string(s['source'])}")
        if s.get('battery'):
            fields.append(f"battery = {lua_string(s['battery'])}")
        for key in ('cc', 'present_cc', 'drunk_cc', 'pour', 'pour_hold', 'tare_band'):
            if s.get(key) is not None:
                fields.append(f"{key} = {s[key]}")
        if s.get('gate'):
            fields.append(f"gate = {lua_string(s['gate'])}")
        if s.get('reset_on_round'):
            fields.append('reset_on_round = true')
        if s.get('note') is not None:
            fields.append(f"note = {s['note']}")
        rows.append('  { ' + ', '.join(fields) + ' },')
    config = '\n'.join([
        '-- ---- generated by build_okuma_layout.py — edit the Python config, not here ----',
        'local SENSORS = {',
        *rows,
        '}',
        f'local MIDI_CHANNEL = {MIDI_CHANNEL}',
        f'local MIDI_CONNECTION = {MIDI_CONNECTION}',
        f'local PRESENT_AT = {PRESENT_AT}',
        f'local PRESENT_HYST = {PRESENT_HYST}',
        f'local PRESENT_MS = {PRESENT_MS}',
        f'local STILL_BAND = {STILL_BAND}',
        f'local SETTLE_MS = {SETTLE_MS}',
        f'local POUR_HOLD_S = {POUR_HOLD_S}',
        f'local POUR_FRACTION = {POUR_FRACTION}',
        f'local DRIFT_FRACTION = {DRIFT_FRACTION}',
        f'local DRINK_FRACTION = {DRINK_FRACTION}',
        f'local GATE_S = {GATE_S}',
        f'local GATE_SILENT_S = {GATE_SILENT_S}',
        f'local PRESENT_RISE_S = {PRESENT_RISE_S}',
        f'local PRESENT_FALL_S = {PRESENT_FALL_S}',
        f'local FULL_RISE_S = {FULL_RISE_S}',
        f'local FULL_FALL_S = {FULL_FALL_S}',
        f'local DRUNK_RISE_S = {DRUNK_RISE_S}',
        f'local DRUNK_FALL_S = {DRUNK_FALL_S}',
        f'local TARE_BAND = {TARE_BAND}',
        f'local TARE_HOLD_S = {TARE_HOLD_S}',
        f'local ROUND_MIN_GAP_S = {ROUND_MIN_GAP_S}',
        f'local RESET_CONFIRM_S = {RESET_CONFIRM_S}',
        f'local POUR_THRESHOLD = {POUR_THRESHOLD}',
        f'local RANGE_MIN, RANGE_MAX, RANGE_STEP = {RANGE_MIN}, {RANGE_MAX}, {RANGE_STEP}',
        '-- ---- end generated ----',
    ])
    assert '--@@CONFIG@@' in template, 'CONFIG marker missing in Lua template'
    return template.replace('--@@CONFIG@@', config)


def build_document(lua):
    children, x = [], MARGIN
    for s in SENSORS:
        children += COLUMN_BUILDERS[s['kind']](s, x)
        x += COL_W + COL_GAP
    width = x - COL_GAP + MARGIN

    root_props = ''.join([
        prop('b', 'background', True), prop('c', 'color', rgba(BACKGROUND)),
        prop('f', 'cornerRadius', 1), prop('r', 'frame', (0, 0, width, CANVAS_H)),
        prop('b', 'grabFocus', False), prop('b', 'interactive', False),
        prop('b', 'locked', False), prop('s', 'name', 'okuma'),
        prop('i', 'orientation', 0), prop('b', 'outline', True),
        prop('i', 'outlineStyle', 0), prop('i', 'pointerPriority', 0),
        prop('s', 'script', lua), prop('i', 'shape', 1),
        prop('s', 'tag', ''), prop('b', 'visible', True),
    ])
    return ("<?xml version='1.0' encoding='UTF-8'?><lexml version='6'>"
            f"<node ID='{uuid.uuid4()}' type='GROUP'><includes></includes>"
            f'<properties>{root_props}</properties><values>{TOUCH_VALUE}</values>'
            f"<children>{''.join(children)}</children></node></lexml>")


def check_config():
    ids = [s['id'] for s in SENSORS]
    assert len(set(ids)) == len(ids), f'duplicate sensor id in {ids}'
    ccs = []
    for s in SENSORS:
        if s['kind'] == 'loadcell':
            ccs += [s['cc'], s['present_cc'], s['drunk_cc']]
        elif s['kind'] == 'tilt':
            ccs.append(s['cc'])
    assert len(set(ccs)) == len(ccs), f'duplicate CC in {sorted(ccs)}'
    assert all(isinstance(c, int) and 0 <= c <= 127 for c in ccs), f'CC out of range in {ccs}'
    assert 1 <= MIDI_CHANNEL <= 16 and 1 <= MIDI_CONNECTION <= 10, 'MIDI channel 1–16, connection 1–10'
    assert 0 <= POUR_THRESHOLD < RANGE_DEFAULT and RANGE_MIN <= RANGE_DEFAULT <= RANGE_MAX, \
        'need 0 <= POUR_THRESHOLD < RANGE_DEFAULT and RANGE_MIN <= RANGE_DEFAULT <= RANGE_MAX'
    assert (RANGE_MAX - RANGE_MIN) % RANGE_STEP == 0 and (RANGE_DEFAULT - RANGE_MIN) % RANGE_STEP == 0, \
        'RANGE_MAX and RANGE_DEFAULT must be on the RANGE_STEP grid'
    assert 0 < PRESENT_HYST < PRESENT_AT < 1, 'need 0 < PRESENT_HYST < PRESENT_AT < 1'
    assert 0 <= TARE_BAND < PRESENT_AT - PRESENT_HYST and TARE_HOLD_S >= 0, \
        'need 0 <= TARE_BAND < PRESENT_AT - PRESENT_HYST, TARE_HOLD_S >= 0'
    assert 0 < DRIFT_FRACTION < POUR_FRACTION <= 1 and 0 < DRINK_FRACTION <= 1, \
        'need 0 < DRIFT_FRACTION < POUR_FRACTION <= 1 and 0 < DRINK_FRACTION <= 1'
    assert min(PRESENT_MS, SETTLE_MS, POUR_HOLD_S, GATE_S, GATE_SILENT_S, STILL_BAND) >= 0
    assert min(PRESENT_RISE_S, PRESENT_FALL_S, FULL_RISE_S, FULL_FALL_S,
               DRUNK_RISE_S, DRUNK_FALL_S) >= 0, 'ramp times must be 0 or more'
    for s in SENSORS:
        assert s['kind'] in COLUMN_BUILDERS, f"unknown kind {s['kind']}"
        assert s['id'].isalnum(), f"id must be letters/digits: {s['id']}"
        if s['kind'] == 'rounds':
            assert s.get('source') in ids, f"rounds source {s.get('source')!r} is not a sensor id"
            assert [t for t in SENSORS if t['id'] == s['source']][0]['kind'] == 'loadcell', \
                'rounds source must be a load cell'
            assert isinstance(s.get('note'), int) and 0 <= s['note'] <= 127, \
                f"rounds {s['id']} needs a note 0–127"
        elif s['kind'] == 'tilt':
            assert s.get('osc_tilt') and s.get('osc_dir'), f"sensor {s['id']} needs osc_tilt and osc_dir"
        else:
            assert s.get('osc'), f"sensor {s['id']} needs an osc address"
            assert s.get('pour', 0) > 0, f"vessel {s['id']} needs a pour size in counts"
            assert s.get('gate') in (None, 'pitcher'), f"vessel {s['id']}: gate must be 'pitcher' or absent"
            assert any(t['kind'] == 'tilt' for t in SENSORS) or not s.get('gate'), \
                f"vessel {s['id']} is gated by a pitcher that does not exist"


def main():
    parser = argparse.ArgumentParser(description='Build the okuma TouchOSC layout.')
    parser.add_argument('--xml', action='store_true', help='also write readable XML')
    parser.add_argument('--out', default=None, help='output folder (default: next to this script)')
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    out_dir = Path(args.out) if args.out else here
    check_config()

    lua = render_lua((here / LUA_TEMPLATE).read_text(encoding='utf-8'))
    xml = build_document(lua)

    (out_dir / f'{OUTPUT_NAME}.tosc').write_bytes(zlib.compress(xml.encode('utf-8')))
    (out_dir / f'{OUTPUT_NAME}.lua').write_text(lua, encoding='utf-8')
    if args.xml:
        (out_dir / f'{OUTPUT_NAME}.xml').write_text(xml, encoding='utf-8')
    print(f'wrote {OUTPUT_NAME}.tosc and {OUTPUT_NAME}.lua to {out_dir}')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
okuma interactive — TouchOSC layout generator (v5)
==================================================

Builds  okuma_bridge.tosc  (the TouchOSC layout) and
        okuma_bridge.lua   (readable copy of the root script)
from the CONFIG section below and the Lua template next to this file.

    python build_okuma_layout.py            # writes both files next to this script
    python build_okuma_layout.py --xml      # also writes the readable XML (debugging)

Only the Python standard library is used.

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
#   cc       MIDI CC number the output fader sends
#            fixed accessories first (gaiwan 20, rounds 21, pitcher 22), cups last
#            (23+) so new cups simply continue the numbering
#   sip      load cells: the fill falls by this fraction (0..1) each time the vessel is lifted off
#            the scale for MIN_LIFT_S and put back. Cups 0.33 = three sips; gaiwan 1.0 = empty
#   pour_on_return  gaiwan: coming back heavier than it left (refilled off the scale) = a pour
#   reset_on_round  cups: every round change (gaiwan pour or the round buttons) sets the fill to 0
#   tare_band       optional: own TARE_BAND for this cell (gaiwan 0.10: a lid alone is never tared)
#   lift_cc  load cells: MIDI CC of the lift toggle (127 = lifted, 0 = on the scale)
#            CC 1–5 as in Greg's v12 (cup1–4 = 1–4, gaiwan = 5)
#   note     'rounds' only: note of the reset; round n sends note + n (note-on, velocity 127,
#            channel MIDI_CHANNEL; no note-off and no CC are sent)
#   color    hex colour of the group
SENSORS = [
    dict(kind='loadcell', id='gaiwan',  title='GAIWAN',  noun='GAIWAN',
         osc='/okuma/gaiwan',    battery='/okuma/gaiwan/battery', cc=20, lift_cc=5, color='#d39b4a',
         sip=1.0, pour_on_return=True, tare_band=0.10),
    dict(kind='rounds',   id='rounds',  title='ROUNDS',  source='gaiwan',
         cc=21, note=0, color='#e6c84d'),
    dict(kind='tilt',     id='pitcher', title='PITCHER',
         osc_tilt='/okuma/imu1/tilt', osc_dir='/okuma/imu1/dir',
         battery='/okuma/imu1/battery',                          cc=22, color='#9a80f2'),
    dict(kind='loadcell', id='cup1',    title='CUP 1',   noun='CUP',
         osc='/okuma/cup1',      battery='/okuma/cup1/battery',   cc=23, lift_cc=1, color='#33bfb3',
         sip=0.33, reset_on_round=True),
    dict(kind='loadcell', id='cup2',    title='CUP 2',   noun='CUP',
         osc='/okuma/cup2',      battery='/okuma/cup2/battery',   cc=24, lift_cc=2, color='#8ccc4d',
         sip=0.33, reset_on_round=True),
    dict(kind='loadcell', id='cup3',    title='CUP 3',   noun='CUP',
         osc='/okuma/cup3',      battery='/okuma/cup3/battery',   cc=25, lift_cc=3, color='#e66673',
         sip=0.33, reset_on_round=True),
    dict(kind='loadcell', id='cup4',    title='CUP 4',   noun='CUP',
         osc='/okuma/cup4',      battery='/okuma/cup4/battery',   cc=26, lift_cc=4, color='#4d9ae6',
         sip=0.33, reset_on_round=True),
]

# Load cell fill level (the output fader's CC). The three captured points (NO,
# EMPTY, WITH TEA) only calibrate the weight; the CC runs from EMPTY_MIDI (empty
# vessel) to FULL_MIDI (vessel with tea, also the cap). Keep them different.
EMPTY_MIDI     = 0
FULL_MIDI      = 127
# snap fader = the "off the scale" band (v5 fix 1): below it the vessel counts as away.
# Half an empty vessel by default: an empty vessel on a light-reading spot still stays above it,
# and drift up to that much does not fake a vessel
SNAP_MAX       = 1.0     # snap fader full scale = ±100 % of the empty-vessel weight
SNAP_DEFAULT   = 0.5     # start at ±50 %
SMOOTH_MAX     = 1.0     # smooth fader full scale = 1 s time constant
SMOOTH_DEFAULT = 0.0     # start with no extra smoothing

# How the fill CC moves once a vessel is resting (it HOLDS while lifted):
#   FALL_S     less tea than before -> glides down linearly; the whole drop takes
#              this many seconds (0 = jump)
#   RISE_TAU   more tea (pouring) -> follows up with this smoothing time constant,
#              in seconds (0 = jump)
FALL_S   = 5.0
RISE_TAU = 0.6
# The LIFT CC (127 = lifted, 0 = on the scale) is not a switch but a ramp (fix 5):
#   LIFT_RISE_S  0 -> 127 takes this many seconds when a vessel is lifted (0 = jump)
#   LIFT_FALL_S  127 -> 0 takes this many seconds after it is back and settled (0 = jump)
LIFT_RISE_S = 3.0
LIFT_FALL_S = 3.0

# Lift / put down state machine. Weights are in empty-vessel units:
# 0 = nothing on the scale, 1 = empty vessel.
#   LIFT_DROP    a vessel that gets lighter than its settled weight by more than this
#                has been lifted (tea does not leave a cup that stays put). Raise it if
#                evaporation / sloshing ever triggers it
#   STABLE_BAND  "the weight is still" = it stays within this band
#   SETTLE_MS    how long it must be still before a lift / put-down is over
#                (then the lift CC goes back to 0 and the fill level is read again)
LIFT_DROP   = 0.08
STABLE_BAND = 0.03
SETTLE_MS   = 400

# Auto-tare (v5 fix 1, all load cells): whenever the vessel is away (below the snap band),
# the scale reads within TARE_BAND of NO (empty-vessel units) and stays still for TARE_HOLD_S
# seconds, that reading becomes the new NO; EMPTY and WITH TEA move with it. This happens at
# every round start and during long sips, and does not disturb the lift in progress.
# Keep TARE_BAND below the snap band. A cell's tare_band overrides it (gaiwan: below a lid).
# 0 seconds = off
TARE_BAND   = 0.4
TARE_HOLD_S = 5

# Fill by events (v5). The weight of a load cell depends on where the vessel stands, so the
# level is not read from it; it changes on events:
#   POUR_FRACTION  a still rise of at least this fraction of the tea step (EMPTY -> WITH TEA)
#                  = tea was poured -> fill 100 %. Lower = more sensitive (a missed pour is
#                  worse than a false one). To be tuned on the real cups
#   MIN_LIFT_S     off the scale at least this long and back = a sip / a refill check; shorter
#                  lifts change nothing
POUR_FRACTION = 0.5
#   DRIFT_FRACTION a still rise smaller than this fraction of the tea step is taken as drift
#                  (the reference follows it); a bigger one below POUR_FRACTION stays on record,
#                  so a pour in two goes adds up
#   POUR_SEAT_MIN  wobble (v5 fix 1): when a vessel settles on a spot that reads lighter than the
#                  capture, the pour threshold shrinks with it, down to this factor (never grows)
DRIFT_FRACTION = 0.15
POUR_SEAT_MIN  = 0.5
MIN_LIFT_S    = 2

# Round counter (+1 every time tea is poured into the gaiwan, see POUR_FRACTION).
#   ROUND_MIN_GAP_S   ignore a "full" less than this many seconds after the last
#                     count (0 = off: every time it is full counts)
#   RESET_CONFIRM_S   the reset button must be pressed twice within this time
# Every change of the count also sends a short note: note + count (the rounds
# line in SENSORS), so count 0 = reset note. No cap; notes stop above 127.
ROUND_MIN_GAP_S = 3
RESET_CONFIRM_S = 3
# FULL_HOLD_S: a rise must stay still (within STABLE_BAND) this long before it counts as a
# pour. A hand pressing on the vessel or lifting the lid is a short, moving peak and does not
# count
FULL_HOLD_S     = 1.5

# Pitcher. total tilt = angle between the pitcher's current direction and its ZERO direction,
# built from the module's tilt + dir (not from tiltx / tilty, which distort away from the
# module's own zero). ZERO button = pitcher resting; the range fader = pour angle (max).
#   POUR_THRESHOLD    below this tilt the output is 0 (gate)
#   RANGE_*           range fader: the angle that gives MIDI 127 (min, max, step, start)
# Output = tilt / range angle -> 0..127 (0 below the gate, 127 at the range angle and beyond)
POUR_THRESHOLD = 10
RANGE_MIN, RANGE_MAX, RANGE_STEP = 10, 180, 5
RANGE_DEFAULT = 90

# Note shown in the pitcher column (TEXT control, multi-line)
NOTE = """MIDI ch {ch}. Pitcher: tilt = angle
from the ZERO pose (module tilt + dir).
Below {thr}° -> 0, zero..range -> 0..127.
ZERO: press with the pitcher resting.

Load cells: vessel in the MIDDLE,
settled; press NO, EMPTY, WITH TEA.
Fill {e}…{f}: a pour sets full, each
sip lowers it; holds while lifted,
falls over {fall:g} s. Toggle = lift CC.
Drag a fader = manual MIDI.
Battery: 0–100 on <module>/battery"""

# Look
COL_W, COL_GAP, MARGIN = 230, 10, 20
CANVAS_H   = 800
BACKGROUND = '#0f0f12'
DIM_TEXT   = '#8c99a6'
WHITE      = '#ffffff'
PARAM      = '#999999'
POINT_COLORS = {'none': '#596169', 'empty': '#cccccc', 'tea': '#bf8026'}

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
def fader(name, frame, color, default=0.0, cc=None, grid=False):
    """Vertical fader. With cc it sends MIDI; touchable either way."""
    props = base_props(name, frame, rgba(color)) + ''.join([
        prop('b', 'bar', True), prop('i', 'barDisplay', 0), prop('b', 'cursor', True),
        prop('i', 'cursorDisplay', 0), prop('b', 'grid', grid),
        prop('c', 'gridColor', (0, 0, 0, 0.25)), prop('i', 'gridSteps', 10),
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
    out = [label(f'{sid}_title', (x, 15, title_w, 36), f"{s['title']}   CC {s['cc']}",
                 18, s['color'], align=0)]
    if with_clear:
        out += labelled_button(f'clr_{sid}', (x + COL_W - 60, 18, 60, 30), '#4d4d4d', 'clear',
                               [(f'{sid}_clr_lbl', (0, 0, 30), 'clear', 12, '#d9d9d9')])
    out += [label(f'{sid}_bat', (x, 54, COL_W, 22), 'battery —', 12, DIM_TEXT, align=0),
            label(f'{sid}_status', (x, 78, COL_W, 22), '—', 12, DIM_TEXT, align=0)]
    return out


def output(s, x):
    """The big MIDI fader and its value line."""
    sid = s['id']
    return [fader(f'{sid}_out', (x + 5, 138, 100, 320), s['color'], 0, cc=None if s['kind'] == 'rounds' else s['cc']),
            label(f'{sid}_outval', (x, 464, COL_W, 28), 'MIDI —', 14, WHITE, align=0)]


def loadcell_column(s, x):
    sid = s['id']
    snap_x, smooth_x = x + 118, x + 173
    items = header(s, x, with_clear=True) + output(s, x) + [
        label(f'{sid}_snap_lbl',   (snap_x - 3, 110, 50, 24), 'snap', 12, DIM_TEXT),
        label(f'{sid}_smooth_lbl', (smooth_x - 3, 110, 50, 24), 'smooth', 12, DIM_TEXT),
        fader(f'{sid}_snap',   (snap_x, 138, 44, 270), PARAM, SNAP_DEFAULT / SNAP_MAX),
        fader(f'{sid}_smooth', (smooth_x, 138, 44, 270), PARAM, SMOOTH_DEFAULT / SMOOTH_MAX),
        label(f'{sid}_snap_val',   (snap_x - 8, 412, 60, 20), f'±{SNAP_DEFAULT*100:.1f}%', 11, DIM_TEXT),
        label(f'{sid}_snap_cnt',   (snap_x - 8, 432, 60, 20), '', 11, DIM_TEXT),
        label(f'{sid}_smooth_val', (smooth_x - 8, 412, 60, 20), 'off', 11, DIM_TEXT),
    ]
    points = [('none', f"NO {s['noun']}"), ('empty', f'EMPTY → {EMPTY_MIDI}'),
              ('tea', f'WITH TEA → {FULL_MIDI}')]
    for k, (point, title) in enumerate(points):
        y = 500 + k * 76
        text_color = '#000000' if point == 'empty' else WHITE
        items += labelled_button(f'cap_{sid}_{point}', (x, y, COL_W, 70), POINT_COLORS[point], 'capture',
                                 [(f'{sid}_{point}_lbl', (0, 8, 28), title, 15, text_color),
                                  (f'{sid}_{point}_val', (0, 38, 24), '—', 13, text_color)])
    # lift toggle: box + text underneath, the toggle (carrying the lift CC) on top
    frame = (x, 730, COL_W, 54)
    items += [label(f'{sid}_lift_box', frame, '', 12, WHITE, background='#26262c'),
              label(f'{sid}_lift_lbl', (x + 8, 730, COL_W - 16, 54),
                    f"on the scale   CC {s['lift_cc']} = 0", 13, WHITE),
              toggle(f'{sid}_lift', frame, rgba(s['color'], 0.55))]
    return items


def tilt_column(s, x):
    """Pitcher: readouts, range fader, ZERO button."""
    sid = s['id']
    px, pw = x + 112, 60
    rx = x + 178
    steps = (RANGE_MAX - RANGE_MIN) // RANGE_STEP
    range_default = round((RANGE_DEFAULT - RANGE_MIN) / RANGE_STEP) / steps
    note = NOTE.format(ch=MIDI_CHANNEL, thr=f'{POUR_THRESHOLD:g}', e=EMPTY_MIDI, f=FULL_MIDI,
                       fall=FALL_S)
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
                          f"""+1 each time tea is poured
into the {s['source']} (also a refill
that comes back heavier after
a lift). Starts at 0.

Every change sends a MIDI note
on channel {MIDI_CHANNEL}: note-on, velocity 127,
no note-off, no CC.
Note {s['note']} = reset, {s['note'] + 1} = round 1 …

+1 / −1 correct it (and send the note).
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
        if s.get('lift_cc') is not None:
            fields.append(f"lift_cc = {s['lift_cc']}")
        if s.get('sip') is not None:
            fields.append(f"sip = {s['sip']}")
        if s.get('pour_on_return'):
            fields.append('pour_on_return = true')
        if s.get('reset_on_round'):
            fields.append('reset_on_round = true')
        if s.get('tare_band') is not None:
            fields.append(f"tare_band = {s['tare_band']}")
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
        f'local EMPTY_MIDI = {EMPTY_MIDI}',
        f'local FULL_MIDI  = {FULL_MIDI}',
        f'local SNAP_MAX   = {SNAP_MAX}',
        f'local SMOOTH_MAX = {SMOOTH_MAX}',
        f'local FALL_S = {FALL_S}',
        f'local RISE_TAU = {RISE_TAU}',
        f'local LIFT_RISE_S = {LIFT_RISE_S}',
        f'local LIFT_FALL_S = {LIFT_FALL_S}',
        f'local LIFT_DROP = {LIFT_DROP}',
        f'local STABLE_BAND = {STABLE_BAND}',
        f'local SETTLE_MS = {SETTLE_MS}',
        f'local TARE_BAND = {TARE_BAND}',
        f'local TARE_HOLD_S = {TARE_HOLD_S}',
        f'local FULL_HOLD_S = {FULL_HOLD_S}',
        f'local POUR_FRACTION = {POUR_FRACTION}',
        f'local MIN_LIFT_S = {MIN_LIFT_S}',
        f'local DRIFT_FRACTION = {DRIFT_FRACTION}',
        f'local POUR_SEAT_MIN = {POUR_SEAT_MIN}',
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
    ccs = [s['cc'] for s in SENSORS] + [s['lift_cc'] for s in SENSORS if s['kind'] == 'loadcell']
    assert len(set(ids)) == len(ids), f'duplicate sensor id in {ids}'
    assert len(set(ccs)) == len(ccs), f'duplicate CC (fill / lift) in {ccs}'
    for name, v in (('EMPTY_MIDI', EMPTY_MIDI), ('FULL_MIDI', FULL_MIDI)):
        assert isinstance(v, int) and 0 <= v <= 127, f'{name} must be a whole number 0–127, got {v}'
    assert EMPTY_MIDI != FULL_MIDI, 'EMPTY_MIDI and FULL_MIDI must be different'
    assert min(FALL_S, RISE_TAU, LIFT_RISE_S, LIFT_FALL_S) >= 0, 'FALL_S, RISE_TAU, LIFT_RISE_S and LIFT_FALL_S must be 0 or more'
    assert 1 <= MIDI_CHANNEL <= 16 and 1 <= MIDI_CONNECTION <= 10, 'MIDI channel 1–16, connection 1–10'
    assert 0 <= POUR_THRESHOLD < RANGE_DEFAULT and RANGE_MIN <= RANGE_DEFAULT <= RANGE_MAX, \
        'need 0 <= POUR_THRESHOLD < RANGE_DEFAULT and RANGE_MIN <= RANGE_DEFAULT <= RANGE_MAX'
    assert (RANGE_MAX - RANGE_MIN) % RANGE_STEP == 0 and (RANGE_DEFAULT - RANGE_MIN) % RANGE_STEP == 0, \
        'RANGE_MAX and RANGE_DEFAULT must be on the RANGE_STEP grid'
    assert 0 <= TARE_BAND <= SNAP_DEFAULT and TARE_HOLD_S >= 0 and FULL_HOLD_S >= 0, \
        'need 0 <= TARE_BAND <= SNAP_DEFAULT, TARE_HOLD_S >= 0, FULL_HOLD_S >= 0'
    assert 0 < DRIFT_FRACTION < POUR_FRACTION <= 1 and MIN_LIFT_S >= 0 and 0 < POUR_SEAT_MIN <= 1, \
        'need 0 < DRIFT_FRACTION < POUR_FRACTION <= 1, MIN_LIFT_S >= 0, 0 < POUR_SEAT_MIN <= 1'
    for s in SENSORS:
        assert s['kind'] in COLUMN_BUILDERS, f"unknown kind {s['kind']}"
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
            assert 0 < s.get('sip', 0.33) <= 1, f"load cell {s['id']}: sip must be in (0, 1]"
            assert isinstance(s.get('lift_cc'), int) and 0 <= s['lift_cc'] <= 127, \
                f"load cell {s['id']} needs a lift_cc 0–127"
        assert s['id'].isalnum(), f"id must be letters/digits: {s['id']}"
        assert 0 <= s['cc'] <= 127, f"CC out of range: {s['cc']}"


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

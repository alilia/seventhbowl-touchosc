#!/usr/bin/env python3
"""
okuma interactive — OSC routing probe D: the real layout + a handleOsc counter
==============================================================================

Builds the real layout with ../build_okuma_layout.py (its own CONFIG, its own
Lua template) and adds ONE debug counter to handleOsc, plus a debug line and a
RESET button under the columns. Nothing in the builder or template files is
changed: the patch is applied in memory, the output is probe_D.tosc here.

    python make_probe_d.py            # uses LUA_TEMPLATE named in the builder
    python make_probe_d.py --template okuma_bridge.template.lua

What the counter shows per address (gaiwan, cup1):
    calls   handleOsc calls, split by who called it:
            root = root onReceiveOSC (route 1), label = notify from a receiver
            label (route 2)
    dups    calls whose value equals the previous value of that address.
            The ESP32 only sends when the value moved by > deadband (150 counts),
            so two equal values in a row = the same message handled twice.
    msgs    calls - dups = estimated incoming messages
If calls ~ 2 x msgs, every reading is handled twice (and enters the capture
average twice).
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import build_okuma_layout as B  # noqa: E402

DEBUG_ADDRS = ['/okuma/gaiwan', '/okuma/cup1']

DBG_LUA = r"""
-- ---- PROBE D debug counter (added by make_probe_d.py) ----
local DBG_ADDRS = { '/okuma/gaiwan', '/okuma/cup1' }
local dbg, dbgDirty, dbgUi = {}, true, 0
local function dbgReset()
  dbg = {}
  for _, a in ipairs(DBG_ADDRS) do dbg[a] = { root = 0, label = 0, dups = 0, last = nil, seq = '' } end
  dbgDirty = true
end
dbgReset()
local function dbgCount(src, path, v)
  local d = dbg[path]
  if not d then return end
  d[src] = d[src] + 1
  if v ~= nil and v == d.last then d.dups = d.dups + 1 end
  d.last = v
  d.seq = string.sub(d.seq .. (src == 'root' and 'R' or 'L'), -12)
  dbgDirty = true
end
local function dbgShow(now)
  if not dbgDirty or now - dbgUi < 150 then return end
  dbgUi, dbgDirty = now, false
  for i, a in ipairs(DBG_ADDRS) do
    local d = dbg[a]
    local calls = d.root + d.label
    local c = root:findByName('dbg_row' .. i, true)
    local s = string.format('%s   handleOsc calls %d (root %d / label %d)   dups %d   msgs ~%d   order %s',
      a, calls, d.root, d.label, d.dups, calls - d.dups, d.seq)
    if c and c.values.text ~= s then c.values.text = s end
  end
end
-- ---- end PROBE D ----
"""

# (anchor, replacement, description) — each anchor must occur exactly once
PATCHES = [
    ('-- one entry point for received numbers',
     DBG_LUA + '\n-- one entry point for received numbers',
     'debug counter before handleOsc'),
    ('local function handleOsc(path, v)\n',
     'local function handleOsc(path, v, src)\n  dbgCount(src or \'?\', path, v)\n',
     'count every handleOsc call'),
    ('return handleOsc(message[1], a and a.value)',
     "return handleOsc(message[1], a and a.value, 'root')",
     'root route tags its calls'),
    ('    handleOsc(oscPath, value)\n',
     "    handleOsc(oscPath, value, 'label')\n",
     'label route tags its calls'),
    ('function onReceiveNotify(key, value)\n',
     "function onReceiveNotify(key, value)\n  if key == 'dbg_reset' then dbgReset(); return end\n",
     'RESET button'),
    ('function update()\n  local now = getMillis()\n',
     'function update()\n  local now = getMillis()\n  dbgShow(now)\n',
     'refresh the debug line'),
]


def patch(template):
    for anchor, repl, what in PATCHES:
        k = template.count(anchor)
        if k != 1:
            sys.exit(f'probe D: cannot patch "{what}": anchor found {k}x (expected 1):\n  {anchor!r}\n'
                     'The template changed shape — adjust PATCHES in make_probe_d.py.')
        template = template.replace(anchor, repl)
    return template


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--template', default=None, help='Lua template (default: the builder\'s LUA_TEMPLATE)')
    ap.add_argument('--xml', action='store_true')
    args = ap.parse_args()

    tpl_name = args.template or B.LUA_TEMPLATE
    tpl_path = HERE.parent / tpl_name
    B.check_config()
    lua = B.render_lua(patch(tpl_path.read_text(encoding='utf-8')))

    # room under the columns for the debug lines
    old_h = B.CANVAS_H
    B.CANVAS_H = old_h + 130
    xml = B.build_document(lua)
    width = len(B.SENSORS) * (B.COL_W + B.COL_GAP) - B.COL_GAP + 2 * B.MARGIN
    y = old_h + 4
    extra = [B.label('dbg_title', (B.MARGIN, y, width - 2 * B.MARGIN, 24),
                     f'PROBE D ({B.OUTPUT_NAME} / {tpl_name}): handleOsc counter — press RESET, '
                     'press each load cell ~10x, read calls vs msgs', 13, '#e6c84d', align=0)]
    for i, a in enumerate(DEBUG_ADDRS, 1):
        extra.append(B.label(f'dbg_row{i}', (B.MARGIN, y + 2 + 26 * i, width - 2 * B.MARGIN - 200, 26),
                             f'{a}   handleOsc calls 0', 16, B.WHITE, align=0, background='#1a1a1f'))
    extra += B.labelled_button('dbg_reset_btn', (width - B.MARGIN - 180, y + 28, 180, 52), '#7a2e2e',
                               'dbg_reset', [('dbg_reset_lbl', (0, 12, 28), 'RESET', 16, '#f2f2f2')])
    marker = '</children></node></lexml>'
    assert xml.endswith(marker)
    xml = xml[:-len(marker)] + ''.join(extra) + marker

    import zlib
    (HERE / 'probe_D.tosc').write_bytes(zlib.compress(xml.encode('utf-8')))
    (HERE / 'probe_D.lua').write_text(lua, encoding='utf-8')
    if args.xml:
        (HERE / 'probe_D.xml').write_text(xml, encoding='utf-8')
    print(f'wrote probe_D.tosc from {B.OUTPUT_NAME} + {tpl_name}')


if __name__ == '__main__':
    main()

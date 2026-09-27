--[[ ==========================================================================
  okuma interactive — TouchOSC bridge  v1
  OSC in (ESP32 modules)  ->  normalised MIDI CC out (channel 1)

    /okuma/cup1 .. cup4   raw HX711 counts     ->  CC 20 .. 23
    /okuma/imu1/tilt      degrees (0 … 180)    ->  CC 24

  CUPS — three captured points per cup, piecewise linear between them:
      NO CUP     -> 127 (1.0)
      EMPTY CUP  -> 0
      CUP + TEA  -> 63
    Capture = mean of the readings from the last second (or the last reading
    if the module has been quiet — its 150-count deadband means a steady cup
    sends nothing). Works whether the load cell counts go up or down with weight.
    snap   : within ±x % of the empty-cup weight around a captured point, the
             output locks exactly to 127 / 0 / 63 (kills drift + jitter)
    smooth : extra smoothing time constant here (0 = off, max 1 s)
    Tea heavier than the TEA point keeps rising above 63 (clamped at 127).

  TILT — 0° -> 0, range° -> 127 (range fader, 10 … 180°, 5° steps, default 90).

  Calibration lives in memory while the layout runs and is mirrored into
  this group's `tag` property, which is read back on start.
========================================================================== ]]

local CUPS       = 4
local TILT_PATH  = '/okuma/imu1/tilt'
local TEA        = 63 / 127
local CAPTURE_MS = 1000     -- capture averages this window
local LIVE_MS    = 2000     -- "live" if a message came within this time
local SNAP_MAX   = 0.25     -- snap fader full = ±25 % of empty-cup weight
local SMOOTH_MAX = 1.0      -- smooth fader full = 1 s time constant

local POINTS     = { none = 'N', empty = 'E', tea = 'F' }
local POINT_TEXT = { none = 'NO CUP → 127', empty = 'EMPTY → 0', tea = 'TEA → 63' }

local cups, ui = {}, {}
local tilt = { deg = nil, last = 0 }
local lastUi, lastFrame = 0, nil

-- ---------------------------------------------------------------------------
local function find(name) return root:findByName(name, true) end

local function setText(ctrl, s)
  if ctrl and ctrl.values.text ~= s then ctrl.values.text = s end
end

local function fmt(v) return v and string.format('%.0f', v) or '—' end

-- ---- persistence (runtime + tag mirror) -----------------------------------
local function save()
  local parts = {}
  for i = 1, CUPS do
    local c = cups[i]
    local f = function(v) return v and string.format('%.1f', v) or '' end
    parts[i] = f(c.N) .. ',' .. f(c.E) .. ',' .. f(c.F)
  end
  root.tag = table.concat(parts, ';')
end

local function restore()
  local s = root.tag
  if type(s) ~= 'string' or s == '' then return end
  local i = 0
  for chunk in (s .. ';'):gmatch('([^;]*);') do
    i = i + 1
    if i > CUPS then break end
    local k, keys = 0, { 'N', 'E', 'F' }
    for field in (chunk .. ','):gmatch('([^,]*),') do
      k = k + 1
      if k > 3 then break end
      cups[i][keys[k]] = tonumber(field)
    end
  end
end

-- ---- cup mapping -----------------------------------------------------------
local function teaW(c)
  if not (c.N and c.E and c.F) or c.N == c.E then return nil end
  local wF = (c.F - c.N) / (c.E - c.N)
  if wF <= 1 then return nil end            -- tea must weigh more than the empty cup
  return wF
end

local function mapCup(i, v)
  local c = cups[i]
  if not (c.N and c.E) or c.N == c.E then return nil end
  local w   = (v - c.N) / (c.E - c.N)       -- 0 = no cup, 1 = empty cup
  local wF  = teaW(c)
  local tol = ui[i].snap.values.x * SNAP_MAX

  if math.abs(w) <= tol then return 1 end
  if math.abs(w - 1) <= tol then return 0 end
  if wF and math.abs(w - wF) <= tol then return TEA end

  if w <= 0 then return 1 end
  if w < 1 then return 1 - w end
  if not wF then return 0 end
  return math.clamp(TEA * (w - 1) / (wF - 1), 0, 1)
end

local function captureValue(c)
  if not c.target then return nil end
  local now, sum, n = getMillis(), 0, 0
  for _, h in ipairs(c.hist) do
    if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
  end
  if n > 0 then return sum / n end
  return c.target
end

-- ---- tilt ------------------------------------------------------------------
local function tiltRange()
  return 10 + math.floor(ui.range.values.x * 34 + 0.5) * 5
end

local function applyTilt()
  if not tilt.deg then return end
  local out = math.clamp(tilt.deg / tiltRange(), 0, 1)
  if ui.tiltOut.values.x ~= out then ui.tiltOut.values.x = out end
end

-- ---- display ---------------------------------------------------------------
local function refreshUi(now)
  for i = 1, CUPS do
    local c, u = cups[i], ui[i]

    if not c.target then
      setText(u.raw, 'raw —   waiting')
    else
      local age = now - c.last
      local st = age < LIVE_MS and 'live' or string.format('steady %ds', math.floor(age / 1000))
      setText(u.raw, string.format('raw %.0f   %s', c.raw, st))
    end

    if not (c.N and c.E) then
      setText(u.outval, 'capture NO CUP + EMPTY')
    elseif c.N == c.E then
      setText(u.outval, 'NO CUP = EMPTY ?')
    elseif c.F and not teaW(c) then
      setText(u.outval, 'TEA ≤ EMPTY ? recapture')
    elseif c.out then
      setText(u.outval, string.format('MIDI %d', math.floor(c.out * 127 + 0.5)))
    else
      setText(u.outval, 'MIDI —')
    end

    local pct = u.snap.values.x * SNAP_MAX
    if c.N and c.E then
      setText(u.snapLbl, string.format('±%.1f%%\n%.0f', pct * 100, math.abs(c.E - c.N) * pct))
    else
      setText(u.snapLbl, string.format('±%.1f%%', pct * 100))
    end
    local tau = u.smooth.values.x * SMOOTH_MAX
    setText(u.smoothLbl, tau <= 0.001 and 'off' or string.format('%.2f s', tau))

    for p, key in pairs(POINTS) do
      setText(u.pts[p], POINT_TEXT[p] .. '\n' .. fmt(c[key]))
    end
  end

  applyTilt()
  if tilt.deg then
    local age = now - tilt.last
    setText(ui.tiltDeg, string.format('%.1f°   %s', tilt.deg, age < LIVE_MS and 'live' or 'no data'))
    setText(ui.tiltVal, string.format('MIDI %d', math.floor(ui.tiltOut.values.x * 127 + 0.5)))
  else
    setText(ui.tiltDeg, '—   waiting')
    setText(ui.tiltVal, 'MIDI —')
  end
  setText(ui.rangeLbl, string.format('0 … %d°', tiltRange()))
end

-- ---- TouchOSC callbacks ----------------------------------------------------
function init()
  for i = 1, CUPS do
    local p = 'c' .. i .. '_'
    cups[i] = { hist = {} }
    ui[i] = {
      raw       = find(p .. 'raw'),
      out       = find(p .. 'out'),
      outval    = find(p .. 'outval'),
      snap      = find(p .. 'snap'),
      smooth    = find(p .. 'smooth'),
      snapLbl   = find(p .. 'snap_val'),
      smoothLbl = find(p .. 'smooth_val'),
      pts = {
        none  = find(p .. 'none_lbl'),
        empty = find(p .. 'empty_lbl'),
        tea   = find(p .. 'tea_lbl'),
      },
    }
  end
  ui.tiltOut  = find('tilt_out')
  ui.tiltDeg  = find('tilt_deg')
  ui.tiltVal  = find('tilt_outval')
  ui.range    = find('tilt_range')
  ui.rangeLbl = find('tilt_range_val')

  restore()
  refreshUi(getMillis())
end

function onReceiveOSC(message, connections)
  local path, args = message[1], message[2]
  local a = args and args[1]
  if not a or type(a.value) ~= 'number' then return false end

  local n = path:match('^/okuma/cup(%d+)$')
  if n then
    local c = cups[tonumber(n)]
    if not c then return false end
    local now = getMillis()
    c.target = a.value
    if not c.raw then c.raw = a.value end
    c.last = now
    table.insert(c.hist, { t = now, v = a.value })
    while #c.hist > 1 and (#c.hist > 50 or c.hist[1].t < now - CAPTURE_MS) do
      table.remove(c.hist, 1)
    end
    return true
  elseif path == TILT_PATH then
    tilt.deg, tilt.last = a.value, getMillis()
    applyTilt()
    return true
  end
  return false
end

function onReceiveNotify(key, value)
  if key == 'capture' then
    local i, p = tostring(value):match('^cap(%d+)_(%a+)$')
    i = tonumber(i)
    if i and cups[i] and POINTS[p] then
      local v = captureValue(cups[i])
      if v then
        cups[i][POINTS[p]] = v
        cups[i].out = nil
        save()
      end
    end
  elseif key == 'clear' then
    local i = tonumber(tostring(value):match('^clr(%d+)$'))
    if i and cups[i] then
      cups[i].N, cups[i].E, cups[i].F, cups[i].out = nil, nil, nil, nil
      save()
    end
  end
  refreshUi(getMillis())
end

function update()
  local now = getMillis()
  local dt = lastFrame and (now - lastFrame) / 1000 or 0
  lastFrame = now

  for i = 1, CUPS do
    local c = cups[i]
    if c.target then
      local tau = ui[i].smooth.values.x * SMOOTH_MAX
      if tau <= 0.001 then
        c.raw = c.target
      else
        c.raw = c.raw + (c.target - c.raw) * (1 - math.exp(-dt / tau))
      end
      local out = mapCup(i, c.raw)
      if out and (not c.out or math.abs(out - c.out) > 0.0005) then
        c.out = out
        ui[i].out.values.x = out
      end
    end
  end

  if now - lastUi >= 150 then
    lastUi = now
    refreshUi(now)
  end
end

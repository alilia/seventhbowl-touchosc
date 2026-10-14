--[[ ==========================================================================
  okuma interactive — TouchOSC bridge  v12
  OSC in (ESP32 modules)  ->  MIDI out, channel 1

  PER CUP (1..4) + GAIWAN (5)      cups: /okuma/cup1..4   gaiwan: /okuma/gaiwan
    CC    1..5    lifted = 127,  put down = 0   (map to an effect on/off)
    CC   20..23   cup tea amount 0 = empty … 127 = full (TEA point)
    CC   26       gaiwan amount  0 = empty … 127 = full
                  · lifted        -> holds its value
                  · less tea      -> glides DOWN linearly over 5 s
                  · more tea      -> glides UP smoothly (follows the pour)

  POURING / FORM
    CC   24       teapot tilt.  Two angles arrive: /okuma/imu1/tiltx, tilty
                  (signed degrees).  tilt = sqrt((x - zeroX)^2 + (y - zeroY)^2)
                  ZERO button stores the resting x / y (1 s average, saved).
                  Below POUR_THRESHOLD (10°) the output is 0, above it
                  tilt / range -> 0..127 (range fader 10 … 180°, 5° steps).
                  (The old single /okuma/imu1/tilt address still works.)
    NOTE 60       counter reset (start of the ceremony)
    NOTE 61..70   round 1..10  (short note, for Session scene launch)
    CC   25       round as a number

    The counter watches ONLY the gaiwan: every time the gaiwan gets full
    (fader ≥ 70 %) it is the next round. It re-arms once the gaiwan has
    been emptied (fader ≤ 20 %). Works with the sensor or the fader by hand.
    Under each column: one toggle — lit = cup lifted. Tap to switch by hand.
    Buttons: −1 / +1 / reset for manual control during rehearsal.

  CUP CALIBRATION — capture NO CUP, EMPTY, TEA with the cup settled.
    snap   : lock zone around EMPTY / TEA (± % of empty-cup weight)
    smooth : extra smoothing of the raw sensor (0 = off, max 1 s)

  MANUAL — the output faders are touchable (MIDI without sensors).
========================================================================== ]]

local CUPS       = 5        -- 1..4 cups, 5 = gaiwan
local GAIWAN     = 5
local TILT_PATH  = '/okuma/imu1/tilt'     -- old single-angle address (fallback)
local TILT_X     = '/okuma/imu1/tiltx'
local TILT_Y     = '/okuma/imu1/tilty'
local POUR_THRESHOLD = 10                  -- degrees; below this the pitcher output is 0
local CAPTURE_MS = 1000     -- capture averages this window
local LIVE_MS    = 2000     -- "live" if a message came within this time
local SNAP_MAX   = 0.25     -- snap fader full = ±25 % of empty-cup weight
local SMOOTH_MAX = 1.0      -- smooth fader full = 1 s time constant

-- presence / amount / fill detection
local ON_W        = 0.6     -- cup counts as "down" above 60 % of empty-cup weight
local OFF_W       = 0.4     -- … and as "lifted" below 40 %
local DEBOUNCE_MS = 300     -- state must hold this long before it flips
local SETTLE_MS   = 300     -- after set-down, wait before trusting the amount
local ROLLBACK_MS = 1000    -- on lift, restore the amount from this long ago
local DROP_MS     = 600     -- a falling amount is only sent after it held this long
local FALL_S      = 5.0     -- a drop in tea glides down linearly over this time
local RISE_TAU    = 0.6     -- a rise follows with this smoothing time constant (s)
local GAIWAN_FULL  = 0.70   -- gaiwan fader at/above this = full -> next round
local GAIWAN_EMPTY = 0.20   -- gaiwan fader at/below this = emptied -> re-arm
local MAX_ROUND   = 10

local CC_AMOUNT   = 20      -- + cup-1 (sent by the output faders)
local NOTE_CUP    = 36      -- + cup-1
local CC_CUP      = 1       -- + cup-1  (CC 1..4)
local NOTE_ROUND  = 60      -- + round  (60 = reset)
local CC_ROUND    = 25

local CONN = { true, false, false, false, false, false, false, false, false, false }

local POINTS     = { none = 'N', empty = 'E', tea = 'F' }
local POINT_TEXT = { none = 'NO CUP → note off', empty = 'EMPTY → 0', tea = 'FULL → 127' }

local cups, ui = {}, {}
local tilt = { deg = nil, last = 0, v = {}, at = {}, hist = { x = {}, y = {} } }
local round, pendingOff, armed = 0, {}, true
local lastUi, lastFrame = 0, nil

-- ---------------------------------------------------------------------------
local function find(name) return root:findByName(name, true) end

local function setText(ctrl, s)
  if ctrl and ctrl.values.text ~= s then ctrl.values.text = s end
end

local function fmt(v) return v and string.format('%.0f', v) or '—' end

-- ---- MIDI ------------------------------------------------------------------
local function cc(n, v)   sendMIDI({ 0xB0, n, math.clamp(math.floor(v + 0.5), 0, 127) }, CONN) end
local function noteOn(n)  sendMIDI({ 0x90, n, 127 }, CONN) end
local function noteOff(n) sendMIDI({ 0x90, n, 0 }, CONN) end   -- velocity 0

local function sendRound()
  cc(CC_ROUND, round)
  local n = NOTE_ROUND + round
  noteOn(n)
  pendingOff[n] = getMillis() + 150
end

local function setRound(r)
  round = math.clamp(r, 0, MAX_ROUND)
  sendRound()
end

local function resetCounter()
  armed = true
  setRound(0)
end

-- ---- persistence (runtime + tag mirror) -----------------------------------
local function save()
  local parts = {}
  for i = 1, CUPS do
    local c = cups[i]
    local f = function(v) return v and string.format('%.1f', v) or '' end
    parts[i] = f(c.N) .. ',' .. f(c.E) .. ',' .. f(c.F)
  end
  local g = function(v) return v and string.format('%.2f', v) or '' end
  parts[CUPS + 1] = g(tilt.zx) .. ',' .. g(tilt.zy)          -- pitcher zero
  root.tag = table.concat(parts, ';')
end

local function restore()
  local s = root.tag
  if type(s) ~= 'string' or s == '' then return end
  local i = 0
  for chunk in (s .. ';'):gmatch('([^;]*);') do
    i = i + 1
    if i > CUPS + 1 then break end
    local k, keys = 0, { 'N', 'E', 'F' }
    local into = cups[i]
    if i == CUPS + 1 then keys, into = { 'zx', 'zy' }, tilt end
    for field in (chunk .. ','):gmatch('([^,]*),') do
      k = k + 1
      if k > #keys then break end
      into[keys[k]] = tonumber(field)
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

-- weight in "empty cups": 0 = no cup, 1 = empty cup, wF = full
local function cupW(c, v)
  if not (c.N and c.E) or c.N == c.E then return nil end
  return (v - c.N) / (c.E - c.N)
end

-- tea amount 0..1, or nil if the cup is not fully on the scale
local function amountOf(i, w)
  local c   = cups[i]
  local tol = ui[i].snap.values.x * SNAP_MAX
  if w < 1 - tol then return nil end
  local wF = teaW(c)
  if math.abs(w - 1) <= tol or not wF then return 0 end
  if math.abs(w - wF) <= tol then return 1 end
  return math.clamp((w - 1) / (wF - 1), 0, 1)
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

-- ---- per-cup state machine -------------------------------------------------
local function setPresent(i, on, now)
  local c = cups[i]
  c.present, c.since = on, now
  local b = ui[i].cupBtn
  if b and b.values.x ~= (on and 0 or 1) then b.values.x = on and 0 or 1 end
  cc(CC_CUP + i - 1, on and 0 or 127)   -- lifted 127, put down 0
  if not on then
    -- lifting drags the reading down through the "less tea" range: undo that
    local back
    for k = #c.ahist, 1, -1 do
      if c.ahist[k].t <= now - ROLLBACK_MS then back = c.ahist[k].a; break end
    end
    if back == nil and c.ahist[1] then back = c.ahist[1].a end
    if back ~= nil then c.amount = back end
    c.dropAt = nil
  end
end

local function stepCup(i, now)
  local c = cups[i]
  local w = c.raw and cupW(c, c.raw)
  if not w then return end

  -- presence with hysteresis + debounce
  local want = c.present
  if want == nil then want = w > 0.5 end   -- first reading after start
  if c.present and w < OFF_W then want = false end
  if not c.present and w > ON_W then want = true end
  if want ~= c.present then
    c.flipAt = c.flipAt or now
    if now - c.flipAt >= DEBOUNCE_MS then
      c.flipAt = nil
      setPresent(i, want, now)
    end
  else
    c.flipAt = nil
  end

  -- amount: only while the cup has been down for a moment
  if c.present and now - c.since >= SETTLE_MS then
    local a = amountOf(i, w)
    if a then
      c.amount = a
      table.insert(c.ahist, { t = now, a = a })
    end
  end
  while #c.ahist > 1 and c.ahist[1].t < now - 3000 do table.remove(c.ahist, 1) end

  -- target: rises are taken at once (pouring), drops only once they have
  -- held (so the moment of lifting the cup never counts as "less tea")
  if c.amount >= c.goal then
    c.goal, c.dropAt = c.amount, nil
  else
    c.dropAt = c.dropAt or now
    if now - c.dropAt >= DROP_MS then
      c.goal, c.dropAt = c.amount, nil
      c.fallRate = (c.out - c.goal) / FALL_S       -- linear, whole drop in 5 s
    end
  end
end

-- output glide toward the goal
local function glide(c, dt)
  if c.goal < c.out then
    local rate = c.fallRate or ((c.out - c.goal) / FALL_S)
    c.out = math.max(c.goal, c.out - rate * dt)
  elseif c.goal > c.out then
    c.fallRate = nil
    c.out = c.out + (c.goal - c.out) * (1 - math.exp(-dt / RISE_TAU))
    if c.goal - c.out < 0.002 then c.out = c.goal end
  end
end

local function ready(c) return c.N and c.E and teaW(c) end

-- round counter: gaiwan gets full -> next round; re-arms once it is emptied
-- (reads the gaiwan output fader, i.e. the CC 26 that is actually sent)
local function stepCounter()
  local v = ui[GAIWAN].out.values.x
  if armed and v >= GAIWAN_FULL then
    armed = false
    setRound(round + 1)
  elseif not armed and v <= GAIWAN_EMPTY then
    armed = true
  end
end

-- ---- tilt ------------------------------------------------------------------
local function tiltRange()
  return 10 + math.floor(ui.range.values.x * 34 + 0.5) * 5
end

-- one axis of the pitcher arrived ('x' = tiltx, 'y' = tilty)
local function tiltAxis(axis, v, now)
  tilt.v[axis], tilt.at[axis] = v, now
  local h = tilt.hist[axis]
  table.insert(h, { t = now, v = v })
  while #h > 1 and (#h > 60 or h[1].t < now - CAPTURE_MS) do table.remove(h, 1) end
end

local function tiltMean(axis, now)
  local sum, n = 0, 0
  for _, h in ipairs(tilt.hist[axis]) do
    if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
  end
  return n > 0 and sum / n or tilt.v[axis]        -- quiet module: last value
end

-- total tilt measured from the captured zero (0, 0 until captured);
-- falls back to the old single-angle address if no x / y pair has arrived
local function tiltNow()
  if tilt.v.x and tilt.v.y then
    local dx, dy = tilt.v.x - (tilt.zx or 0), tilt.v.y - (tilt.zy or 0)
    return math.sqrt(dx * dx + dy * dy), math.min(tilt.at.x, tilt.at.y)
  end
  return tilt.deg, tilt.last
end

local function tiltZero()
  if not (tilt.v.x and tilt.v.y) then return end
  local now = getMillis()
  tilt.zx, tilt.zy = tiltMean('x', now), tiltMean('y', now)
end

local function tiltLevel(t)
  if t < POUR_THRESHOLD then return 0 end
  return math.clamp(t / math.max(tiltRange(), POUR_THRESHOLD + 1), 0, 1)
end

local function applyTilt()
  local t = tiltNow()
  if not t or ui.tiltOut.values.touch then return end   -- held = manual
  local out = tiltLevel(t)
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

    local midi = math.floor(u.out.values.x * 127 + 0.5)
    if u.out.values.touch or not c.target then
      setText(u.outval, string.format('CC %d   manual', midi))
    elseif not (c.N and c.E) then
      setText(u.outval, 'capture NO CUP + EMPTY')
    elseif c.N == c.E then
      setText(u.outval, 'NO CUP = EMPTY ?')
    elseif c.F and not teaW(c) then
      setText(u.outval, 'TEA ≤ EMPTY ? recapture')
    elseif not c.F then
      setText(u.outval, string.format('%s   capture TEA', c.present and '● cup' or '○ lifted'))
    else
      setText(u.outval, string.format('CC %d   %s', midi, c.present and '● cup' or '○ lifted'))
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
  local t, at = tiltNow()
  if t then
    local age = now - at
    setText(ui.tiltDeg, string.format('tilt %.1f°   %s', t, age < LIVE_MS and 'live' or 'no data'))
    setText(ui.tiltBig, string.format('%.1f°', t))
    setText(ui.tiltPour, t >= POUR_THRESHOLD and 'pouring' or string.format('below %g°', POUR_THRESHOLD))
  else
    setText(ui.tiltDeg, 'tilt —   waiting')
    setText(ui.tiltBig, '—')
    setText(ui.tiltPour, '—')
  end
  setText(ui.tiltX, tilt.v.x and string.format('x %+.1f°', tilt.v.x) or 'x —')
  setText(ui.tiltY, tilt.v.y and string.format('y %+.1f°', tilt.v.y) or 'y —')
  setText(ui.tiltZeroVal, tilt.zx and string.format('x %+.1f\ny %+.1f', tilt.zx, tilt.zy) or 'not set')
  local manual = ui.tiltOut.values.touch or not t
  setText(ui.tiltVal, string.format('MIDI %d%s', math.floor(ui.tiltOut.values.x * 127 + 0.5),
                                    manual and '   manual' or ''))
  setText(ui.rangeLbl, string.format('0 … %d°', tiltRange()))
  setText(ui.round, string.format('ROUND %d   gaiwan: %s', round,
                                  armed and 'waiting for full' or 'full → empty it'))
end

-- ---- TouchOSC callbacks ----------------------------------------------------
function init()
  for i = 1, CUPS do
    local p = 'c' .. i .. '_'
    cups[i] = { hist = {}, ahist = {}, present = nil, since = 0,
                amount = 0, goal = 0, out = 0 }
    ui[i] = {
      raw       = find(p .. 'raw'),
      out       = find(p .. 'out'),
      outval    = find(p .. 'outval'),
      snap      = find(p .. 'snap'),
      smooth    = find(p .. 'smooth'),
      snapLbl   = find(p .. 'snap_val'),
      smoothLbl = find(p .. 'smooth_val'),
      cupBtn    = find(p .. 'cup'),
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
  ui.tiltX       = find('tilt_xval')
  ui.tiltY       = find('tilt_yval')
  ui.tiltBig     = find('tilt_big')
  ui.tiltPour    = find('tilt_pour')
  ui.tiltZeroVal = find('tilt_zero_val')
  ui.round    = find('round_lbl')

  restore()
  refreshUi(getMillis())
end

function onReceiveOSC(message, connections)
  local path, args = message[1], message[2]
  if path == '/okuma/reset' then resetCounter(); return true end
  local a = args and args[1]
  if not a or type(a.value) ~= 'number' then return false end

  local n = path:match('^/okuma/cup(%d+)$')
  if path == '/okuma/gaiwan' then n = GAIWAN end
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
  elseif path == TILT_X or path == TILT_Y then
    tiltAxis(path == TILT_X and 'x' or 'y', a.value, getMillis())
    applyTilt()
    return true
  elseif path == TILT_PATH then
    tilt.deg, tilt.last = a.value, getMillis()
    applyTilt()
    return true
  end
  return false
end

function onReceiveNotify(key, value)
  if key == 'capture' and value == 'tilt_zero' then
    tiltZero()
    save()
  elseif key == 'capture' then
    local i, p = tostring(value):match('^cap(%d+)_(%a+)$')
    i = tonumber(i)
    if i and cups[i] and POINTS[p] then
      local v = captureValue(cups[i])
      if v then
        cups[i][POINTS[p]] = v
        save()
      end
    end
  elseif key == 'clear' then
    local i = tonumber(tostring(value):match('^clr(%d+)$'))
    if i and cups[i] then
      cups[i].N, cups[i].E, cups[i].F = nil, nil, nil
      save()
    end
  elseif key == 'cup' then
    local i, dir = tostring(value):match('^c(%d+)_(%a+)$')
    i = tonumber(i)
    local on = dir == 'down'
    if i and cups[i] and cups[i].present ~= on then setPresent(i, on, getMillis()) end
  elseif key == 'round' then
    if value == 'reset' then resetCounter()
    elseif value == 'plus' then setRound(round + 1)
    elseif value == 'minus' then setRound(round - 1) end
  end
  refreshUi(getMillis())
end

function update()
  local now = getMillis()
  local dt = lastFrame and (now - lastFrame) / 1000 or 0
  lastFrame = now

  for n, t in pairs(pendingOff) do
    if now >= t then noteOff(n); pendingOff[n] = nil end
  end

  for i = 1, CUPS do
    local c = cups[i]
    local held = ui[i].out.values.touch
    if c.target then
      local tau = ui[i].smooth.values.x * SMOOTH_MAX
      if tau <= 0.001 then
        c.raw = c.target
      else
        c.raw = c.raw + (c.target - c.raw) * (1 - math.exp(-dt / tau))
      end
      stepCup(i, now)
      glide(c, dt)
      -- the fader sends CC 20+i-1; while touched the sensor never overwrites it
      if not held and c.N and c.E and math.abs(ui[i].out.values.x - c.out) > 0.0005 then
        ui[i].out.values.x = c.out
      end
    end
  end

  stepCounter()

  if now - lastUi >= 150 then
    lastUi = now
    refreshUi(now)
  end
end

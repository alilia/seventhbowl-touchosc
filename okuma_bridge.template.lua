--[[ ==========================================================================
  okuma interactive — TouchOSC bridge  v3
  OSC in (ESP32 modules)  ->  normalised MIDI CC out

  This file is a TEMPLATE. build_okuma_layout.py replaces the CONFIG marker
  below with the sensor list and settings from its own config section, then
  puts the result into the root group's script. Edit sensors / CCs / colours
  in the Python file; edit behaviour here.

  TOUCHOSC'S LUA IS SMALL (Lua 5.1). Available base functions are only:
    error ipairs next pairs print select tonumber tostring unpack type
  plus the table, math (+ math.clamp) and string libraries. There is NO
  setmetatable, pcall, assert, require or load — do not use them here, the
  whole script would fail to start ("attempt to call global ... (a nil value)").
  Errors are reported by TouchOSC in its log as "CONTROL(ROOT) RUNTIME ERROR".

  HOW IT IS ORGANISED  (objects built from closures, no metatables)
    newModule    shared parts of every accessory (battery, manual fader,
                 MIDI text). Called first by the two constructors below.
    newLoadCell  gaiwan + cups. Three captured points, piecewise linear:
                   NO <OBJECT> -> NONE_MIDI   EMPTY -> EMPTY_MIDI
                   WITH TEA -> TEA_MIDI (capped there)
                 (127 / 0 / 63 by default; set them in the Python config.)
                 snap   = lock zone around each point (± % of empty weight)
                 smooth = extra lag (time constant)
                 LIFT / PUT DOWN is a small state machine (the output must not
                 follow the weight through the 0 "empty" point):
                   none     nothing on the scale            -> NONE_MIDI
                   present  a vessel is resting             -> the fill level
                   transit  something is arriving/leaving   -> NONE_MIDI, until the
                            weight has been still for SETTLE_MS, then it is
                            classified again (none / present)
                 A vessel on the scale can only get LIGHTER by being lifted
                 (tea does not leave a cup that stays put), so a drop of more
                 than LIFT_DROP below the settled weight = lifted =
                 NONE_MIDI at once. Weight appearing on an empty scale = a
                 put-down: NONE_MIDI until it has settled. Rises while a vessel is present are
                 filling and simply follow the fill level. Speed plays no role.
                 FULL (rounds): every time a vessel settles at the tea point
                 (ROUND_FULL_AT of the way from empty to tea) the module named
                 in `rounds` is told. It re-arms when the weight has dropped
                 below ROUND_REARM_AT of the way, or the vessel was lifted /
                 the scale was empty — so a refill off the scale counts too.
    newRounds    round counter. +1 each time the gaiwan is full; starts at 0.
                 Shown big on the layout and sent as a MIDI CC (the count
                 itself, 0–127). Buttons +1 / -1 / reset (reset must be
                 pressed twice within RESET_CONFIRM_S). The count is kept in
                 the root tag like the calibration.
    newTilt      pitcher. Two angles arrive (tiltx, tilty, signed degrees):
                   tilt = sqrt((x - zeroX)^2 + (y - zeroY)^2)
                 ZERO button stores the resting x / y. The range fader sets the
                 pour angle that gives 127 (RANGE_MIN..RANGE_MAX, step RANGE_STEP).
                 Below POUR_THRESHOLD the output is 0; otherwise tilt / range
                 -> 0..127.
    One object is created per entry in SENSORS; adding a load cell is one
    line in the Python config. Methods are called with a dot: m.tick(...)

  MIDI is not sent from this script: every output fader carries its own
  MIDI CC message (Messages tab). The script only moves the faders.

  MANUAL: output faders are touchable. While held, the sensor never
  overwrites them; on release they return to the sensor value (if that
  sensor is sending), otherwise they stay where they were left.

  BATTERY: placeholder. If a number 0–100 arrives on a module's battery
  address it is shown; otherwise "battery —".

  HOW OSC GETS IN (two ways, both lead to handleOsc):
    1. root onReceiveOSC            — if TouchOSC calls the root script
    2. the status / battery labels  — each is the receive-enabled OSC target of
                                      its module address and forwards the value
                                      to the root with notify('osc:<address>', n)
    If OSC ever seems not to arrive, check TouchOSC's own log.

  CALIBRATION is kept while the layout runs and mirrored into the root
  group's tag ("id=N,E,F;id=…"), which is read back on start.
========================================================================== ]]

--@@CONFIG@@

local NONE_V         = NONE_MIDI / 127    -- the three fill-level points as 0..1
local EMPTY_V        = EMPTY_MIDI / 127
local TEA_V          = TEA_MIDI / 127
local CAPTURE_MS     = 1000    -- capture = mean of readings in this window
local LIVE_MS        = 2000    -- "live" if a value arrived within this time
local BATTERY_OLD_MS = 30000   -- battery reading counts as old after this
local UI_EVERY_MS    = 150     -- text refresh rate

-- ---------------------------------------------------------------------------
--  helpers
-- ---------------------------------------------------------------------------
local saveAll   -- defined in the registry section (the rounds counter calls it)

local function find(name)
  local c = root:findByName(name, true)
  if not c then print('okuma: control not found: ' .. name) end
  return c
end

local function setText(ctrl, s)
  if ctrl and ctrl.values.text ~= s then ctrl.values.text = s end
end

local function num(v) return v and string.format('%.0f', v) or '—' end

-- ---------------------------------------------------------------------------
--  newModule — shared by every accessory
-- ---------------------------------------------------------------------------
local function newModule(cfg)
  local self = { id = cfg.id, cfg = cfg }
  local p = cfg.id .. '_'
  self.ui = {
    out    = find(p .. 'out'),
    outval = find(p .. 'outval'),
    status = find(p .. 'status'),
    bat    = (cfg.kind ~= 'rounds') and find(p .. 'bat') or nil,
  }

  function self.isHeld()
    return self.ui.out ~= nil and self.ui.out.values.touch == true
  end

  function self.setOut(x)
    if self.ui.out and self.ui.out.values.x ~= x then self.ui.out.values.x = x end
  end

  function self.midiText(manual)
    local m = math.floor(self.ui.out.values.x * 127 + 0.5)
    return string.format('MIDI %d%s', m, manual and '   manual' or '')
  end

  function self.onBattery(v, now)
    self.battery, self.batteryAt = v, now
  end

  function self.refreshBattery(now)
    if not self.battery then
      setText(self.ui.bat, 'battery —')
      return
    end
    local s = string.format('battery %d%%', math.floor(self.battery + 0.5))
    if now - self.batteryAt > BATTERY_OLD_MS then s = s .. '  (old)' end
    setText(self.ui.bat, s)
  end

  -- defaults, replaced by modules that have something to save / capture
  function self.serialize() return nil end
  function self.restore(s) end
  function self.capture(point) end
  function self.clear() end

  return self
end

-- ---------------------------------------------------------------------------
--  newLoadCell — gaiwan, cups
-- ---------------------------------------------------------------------------
local POINT_KEY = { none = 'N', empty = 'E', tea = 'F' }

local function newLoadCell(cfg)
  local self = newModule(cfg)
  local p = cfg.id .. '_'
  self.ui.snap      = find(p .. 'snap')
  self.ui.smooth    = find(p .. 'smooth')
  self.ui.snapVal   = find(p .. 'snap_val')
  self.ui.snapCnt   = find(p .. 'snap_cnt')
  self.ui.smoothVal = find(p .. 'smooth_val')
  self.ui.pts = {
    none  = find(p .. 'none_val'),
    empty = find(p .. 'empty_val'),
    tea   = find(p .. 'tea_val'),
  }
  self.hist = {}         -- recent readings {t, v} for capture

  function self.receive(v, now)
    self.target = v
    if not self.raw then self.raw = v end
    self.last = now
    table.insert(self.hist, { t = now, v = v })
    while #self.hist > 1 and (#self.hist > 50 or self.hist[1].t < now - CAPTURE_MS) do
      table.remove(self.hist, 1)
    end
  end

  -- position of the tea point on the weight axis (0 = nothing on the scale,
  -- 1 = empty vessel); nil unless all three points are captured and sensible
  function self.teaW()
    local N, E, F = self.N, self.E, self.F
    if not (N and E and F) or N == E then return nil end
    local wF = (F - N) / (E - N)
    if wF <= 1 then return nil end   -- tea must weigh more than the empty vessel
    return wF
  end

  -- weight in empty-vessel units: 0 = nothing on the scale, 1 = empty vessel
  function self.weight(v)
    local N, E = self.N, self.E
    if not (N and E) or N == E then return nil end
    return (v - N) / (E - N)
  end

  -- the state machine (see header); w is the current weight
  function self.step(w, now)
    local band = math.max(self.ui.snap.values.x * SNAP_MAX, STABLE_BAND)
    local s = self.state
    if not s then            -- first look (start, capture, clear, manual release)
      self.state = (w <= band) and 'none' or 'present'
      self.ref = w
      self.firstLook = true
    elseif s == 'none' then
      if w > band then       -- something arrives
        self.state, self.why = 'transit', 'placing'
        self.anchorW, self.anchorT = w, now
      end
    elseif s == 'present' then
      if w > self.ref then self.ref = w end        -- filling: follow upwards
      if self.ref - w > LIFT_DROP then             -- got lighter = lifted
        self.state, self.why = 'transit', 'lifted'
        self.anchorW, self.anchorT = w, now
      end
    else                     -- transit: wait until the weight has been still
      if math.abs(w - self.anchorW) > STABLE_BAND then
        self.anchorW, self.anchorT = w, now
      elseif now - self.anchorT >= SETTLE_MS then
        self.state = (w <= band) and 'none' or 'present'
        self.ref = w
      end
    end
    self.checkFull(w, now)
  end

  -- weights at which the vessel counts as full / ready to be counted again
  function self.fullLevels()
    local wF = self.teaW()
    if not wF then return nil end
    return 1 + ROUND_FULL_AT * (wF - 1), 1 + ROUND_REARM_AT * (wF - 1)
  end

  function self.setRounds(r) self.rounds = r end

  -- every time a resting vessel reaches the tea point: tell the round counter.
  -- Edge-triggered with hysteresis; the first look at a vessel never counts
  -- (power-up, capture, clear, releasing a held fader).
  function self.checkFull(w, now)
    local fullW, rearmW = self.fullLevels()
    if not fullW then return end
    local isFull = self.state == 'present' and w >= fullW
    if self.firstLook then
      self.firstLook = false
      self.armed = not isFull
    elseif self.state ~= 'present' then
      self.armed = true                -- lifted / arriving: counts next time it is full
    elseif isFull then
      if self.armed then
        self.armed = false
        if self.rounds then self.rounds.fullHit(now) end
      end
    elseif w < rearmW then
      self.armed = true
    end
  end

  function self.map(v)
    local N, E = self.N, self.E
    if not (N and E) or N == E then return nil end
    local w   = (v - N) / (E - N)
    local wF  = self.teaW()
    local tol = self.ui.snap.values.x * SNAP_MAX

    if math.abs(w) <= tol then return NONE_V end
    if math.abs(w - 1) <= tol then return EMPTY_V end
    if wF and math.abs(w - wF) <= tol then return TEA_V end

    if w <= 0 then return NONE_V end
    if w < 1 then return NONE_V + (EMPTY_V - NONE_V) * w end
    if not wF then return EMPTY_V end
    -- empty -> tea, and held at the tea value beyond it (capped)
    return EMPTY_V + (TEA_V - EMPTY_V) * math.clamp((w - 1) / (wF - 1), 0, 1)
  end

  function self.capture(point)
    local key = POINT_KEY[point]
    if not key or not self.target then return end
    local now, sum, n = getMillis(), 0, 0
    for _, h in ipairs(self.hist) do
      if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
    end
    self[key] = n > 0 and sum / n or self.target   -- quiet module: last value
    self.out, self.state = nil, nil                 -- fresh output, fresh look
  end

  function self.clear()
    self.N, self.E, self.F, self.out, self.state = nil, nil, nil, nil, nil
  end

  function self.serialize()
    local function f(v) return v and string.format('%.1f', v) or '' end
    return f(self.N) .. ',' .. f(self.E) .. ',' .. f(self.F)
  end

  function self.restore(s)
    local keys, k = { 'N', 'E', 'F' }, 0
    for field in string.gmatch(s .. ',', '([^,]*),') do
      k = k + 1
      if k > 3 then break end
      self[keys[k]] = tonumber(field)
    end
  end

  function self.tick(now, dt)
    local held = self.isHeld()
    if held then
      self.manual = true
    elseif self.manual then
      self.manual = false
      self.out, self.state = nil, nil   -- released: hand the fader back to the sensor
    end
    if held or not self.target then return end

    local tau = self.ui.smooth.values.x * SMOOTH_MAX
    if tau <= 0.001 then
      self.raw = self.target
    else
      self.raw = self.raw + (self.target - self.raw) * (1 - math.exp(-dt / tau))
    end

    local w = self.weight(self.target)
    if w then self.step(w, now) else self.state = nil end
    local out
    if self.state == 'present' then
      local v = self.raw
      -- a little lighter than the settled weight (evaporation, jitter, or the very
      -- start of a lift): hold the settled level instead of sagging with it
      if w and w < self.ref then v = self.N + self.ref * (self.E - self.N) end
      out = self.map(v)
    elseif self.state then
      out = NONE_V                             -- none / transit
    end
    if out and (not self.out or math.abs(out - self.out) > 0.0005) then
      self.out = out
      self.setOut(out)
    end
  end

  function self.refresh(now)
    local u = self.ui

    if not self.target then
      setText(u.status, 'raw —   waiting')
    else
      local age = now - self.last
      local st = age < LIVE_MS and 'live' or string.format('steady %ds', math.floor(age / 1000))
      if self.state == 'transit' then st = self.why end
      setText(u.status, string.format('raw %.0f   %s', self.raw, st))
    end

    if self.isHeld() or not self.target then
      setText(u.outval, self.midiText(true))
    elseif not (self.N and self.E) then
      setText(u.outval, 'capture NO + EMPTY')
    elseif self.N == self.E then
      setText(u.outval, 'NO = EMPTY ?')
    elseif self.F and not self.teaW() then
      setText(u.outval, 'TEA ≤ EMPTY ? recapture')
    else
      setText(u.outval, self.midiText(false))
    end

    local pct = u.snap.values.x * SNAP_MAX
    setText(u.snapVal, string.format('±%.1f%%', pct * 100))
    setText(u.snapCnt, (self.N and self.E) and string.format('≈%.0f', math.abs(self.E - self.N) * pct) or '')
    local tau = u.smooth.values.x * SMOOTH_MAX
    setText(u.smoothVal, tau <= 0.001 and 'off' or string.format('%.2f s', tau))

    for point, key in pairs(POINT_KEY) do setText(u.pts[point], num(self[key])) end
    self.refreshBattery(now)
  end

  return self
end

-- ---------------------------------------------------------------------------
--  newTilt — pitcher
-- ---------------------------------------------------------------------------
local function newTilt(cfg)
  local self = newModule(cfg)
  local p = cfg.id .. '_'
  self.ui.xval    = find(p .. 'xval')
  self.ui.yval    = find(p .. 'yval')
  self.ui.tilt    = find(p .. 'tilt')
  self.ui.pour    = find(p .. 'pour')
  self.ui.zeroVal = find(p .. 'zero_val')
  self.ui.range    = find(p .. 'range')
  self.ui.rangeVal = find(p .. 'range_val')
  self.v    = {}                      -- latest angle per axis: v.x, v.y
  self.at   = {}                      -- when each arrived
  self.hist = { x = {}, y = {} }      -- recent readings {t, v} for capture

  -- axis is 'x' (tiltx) or 'y' (tilty)
  function self.receiveAxis(axis, v, now)
    self.v[axis], self.at[axis] = v, now
    local h = self.hist[axis]
    table.insert(h, { t = now, v = v })
    while #h > 1 and (#h > 60 or h[1].t < now - CAPTURE_MS) do table.remove(h, 1) end
  end

  local function mean(axis, now)
    local sum, n = 0, 0
    for _, h in ipairs(self.hist[axis]) do
      if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
    end
    return n > 0 and sum / n or self.v[axis]      -- quiet module: last value
  end

  -- total tilt of an (x, y) pair, measured from the captured zero (0, 0 until captured)
  function self.tiltOf(x, y)
    local dx, dy = x - (self.zx or 0), y - (self.zy or 0)
    return math.sqrt(dx * dx + dy * dy)
  end

  function self.tilt()
    if not (self.v.x and self.v.y) then return nil end
    return self.tiltOf(self.v.x, self.v.y)
  end

  -- range fader: the angle that gives 127 (kept above the gate, so the division is safe)
  function self.range()
    local steps = (RANGE_MAX - RANGE_MIN) / RANGE_STEP
    return RANGE_MIN + math.floor(self.ui.range.values.x * steps + 0.5) * RANGE_STEP
  end

  function self.top()
    return math.max(self.range(), POUR_THRESHOLD + 1)
  end

  function self.level(t)
    if t < POUR_THRESHOLD then return 0 end
    return math.clamp(t / self.top(), 0, 1)
  end

  -- 'zero': the pitcher rests now -> remember x / y as the reference
  function self.capture(point)
    if point ~= 'zero' or not (self.v.x and self.v.y) then return end
    local now = getMillis()
    self.zx, self.zy = mean('x', now), mean('y', now)
  end

  function self.serialize()
    local function f(v) return v and string.format('%.2f', v) or '' end
    return f(self.zx) .. ',' .. f(self.zy)
  end

  function self.restore(s)
    local keys, k = { 'zx', 'zy' }, 0
    for field in string.gmatch(s .. ',', '([^,]*),') do
      k = k + 1
      if k > 2 then break end      -- (fix 7 tags carried a third field: ignored)
      self[keys[k]] = tonumber(field)
    end
  end

  function self.tick(now, dt)
    if self.isHeld() then return end                    -- held = manual
    local t = self.tilt()
    if t then self.setOut(self.level(t)) end
  end

  function self.refresh(now)
    local u = self.ui
    local t = self.tilt()
    if t then
      local live = now - math.min(self.at.x, self.at.y) < LIVE_MS
      setText(u.status, string.format('tilt %.1f°   %s', t, live and 'live' or 'no data'))
      setText(u.tilt, string.format('%.1f°', t))
      setText(u.pour, t >= POUR_THRESHOLD and 'pouring' or string.format('below %g°', POUR_THRESHOLD))
    else
      setText(u.status, 'tilt —   waiting')
      setText(u.tilt, '—')
      setText(u.pour, '—')
    end
    setText(u.xval, self.v.x and string.format('x %+.1f°', self.v.x) or 'x —')
    setText(u.yval, self.v.y and string.format('y %+.1f°', self.v.y) or 'y —')
    setText(u.zeroVal, self.zx and string.format('x %+.1f   y %+.1f', self.zx, self.zy) or '—')
    setText(u.rangeVal, string.format('0 … %d°', self.range()))
    setText(u.outval, self.midiText(self.isHeld() or not t))
    self.refreshBattery(now)
  end

  return self
end

-- ---------------------------------------------------------------------------
--  newRounds — round counter (+1 every time the gaiwan is full)
-- ---------------------------------------------------------------------------
local function newRounds(cfg)
  local self = newModule(cfg)
  local p = cfg.id .. '_'
  self.ui.count = find(p .. 'count')
  self.count = 0

  local function setCount(n)
    self.count = math.max(0, math.min(127, n))     -- it goes out as a MIDI CC value
    self.out = nil
    saveAll()
  end

  -- called by the gaiwan every time it settles at the tea point
  function self.fullHit(now)
    if self.lastAt and now - self.lastAt < ROUND_MIN_GAP_S * 1000 then return end
    self.lastAt = now
    setCount(self.count + 1)
  end

  -- the buttons: 'inc', 'dec', 'zero' (zero needs a second press)
  function self.adjust(op, now)
    if op == 'inc' then setCount(self.count + 1)
    elseif op == 'dec' then setCount(self.count - 1)
    elseif op == 'zero' then
      if self.zeroAt and now - self.zeroAt <= RESET_CONFIRM_S * 1000 then
        self.zeroAt = nil
        setCount(0)
      else
        self.zeroAt = now
      end
    end
    if op ~= 'zero' then self.zeroAt = nil end
  end

  function self.serialize() return tostring(self.count) end
  function self.restore(s)
    local n = tonumber(s)
    if n then self.count = math.max(0, math.min(127, math.floor(n))) end
  end

  function self.tick(now, dt)
    local held = self.isHeld()
    if held then
      self.manual = true
    elseif self.manual then
      self.manual = false
      self.out = nil                       -- released: back to the real count
    end
    if self.zeroAt and now - self.zeroAt > RESET_CONFIRM_S * 1000 then self.zeroAt = nil end
    if held then return end
    local x = self.count / 127
    if self.out ~= x then
      self.out = x
      self.setOut(x)
    end
  end

  function self.refresh(now)
    local u = self.ui
    setText(u.count, tostring(self.count))
    if self.zeroAt then
      setText(u.status, 'press reset again to confirm')
    else
      local s = string.format('%s full → +1', cfg.source or 'vessel')
      if self.lastAt then
        s = s .. string.format('   (last %ds ago)', math.floor((now - self.lastAt) / 1000))
      end
      setText(u.status, s)
    end
    setText(u.outval, self.midiText(self.isHeld()))
  end

  return self
end

-- ---------------------------------------------------------------------------
--  registry: one object per SENSORS entry, OSC address -> object
-- ---------------------------------------------------------------------------
local KINDS = { loadcell = newLoadCell, tilt = newTilt, rounds = newRounds }
local modules, byId, routes = {}, {}, {}
local lastUi, lastFrame = 0, nil

function saveAll()
  local parts = {}
  for _, m in ipairs(modules) do
    local s = m.serialize()
    if s then parts[#parts + 1] = m.id .. '=' .. s end
  end
  root.tag = table.concat(parts, ';')
end

local function restoreAll()
  local s = root.tag
  if type(s) ~= 'string' then return end
  for id, data in string.gmatch(s, '([%w_]+)=([^;]*)') do
    if byId[id] then byId[id].restore(data) end
  end
end

local function refreshAll(now)
  for _, m in ipairs(modules) do m.refresh(now) end
end

-- one entry point for received numbers, whichever way they arrived
local function handleOsc(path, v)
  local route = routes[path]
  if not route or type(v) ~= 'number' then return false end
  local m, what = route[1], route[2]
  if what == 'value' then m.receive(v, getMillis())
  elseif what == 'battery' then m.onBattery(v, getMillis())
  else m.receiveAxis(what, v, getMillis()) end      -- 'x' / 'y' (pitcher angles)
  return true
end

-- ---------------------------------------------------------------------------
--  TouchOSC callbacks
-- ---------------------------------------------------------------------------
function init()
  modules, byId, routes = {}, {}, {}
  for _, cfg in ipairs(SENSORS) do
    local m = KINDS[cfg.kind](cfg)
    modules[#modules + 1] = m
    byId[cfg.id] = m
    if cfg.osc then routes[cfg.osc] = { m, 'value' } end
    if cfg.osc_x then routes[cfg.osc_x] = { m, 'x' } end
    if cfg.osc_y then routes[cfg.osc_y] = { m, 'y' } end
    if cfg.battery then routes[cfg.battery] = { m, 'battery' } end
  end
  for _, cfg in ipairs(SENSORS) do     -- a counter listens to the module named in `source`
    local src = cfg.source and byId[cfg.source]
    if src and src.setRounds then src.setRounds(byId[cfg.id]) end
  end
  restoreAll()
  refreshAll(getMillis())
end

function onReceiveOSC(message, connections)
  local a = message[2] and message[2][1]
  return handleOsc(message[1], a and a.value)
end

function onReceiveNotify(key, value)
  local oscPath = string.match(tostring(key), '^osc:(.+)$')
  if oscPath then               -- a number forwarded by a receiving label
    handleOsc(oscPath, value)
    return
  end
  local name = tostring(value)
  if key == 'capture' then
    local id, point = string.match(name, '^cap_(.-)_(%a+)$')
    if id and byId[id] then byId[id].capture(point); saveAll() end
  elseif key == 'clear' then
    local id = string.match(name, '^clr_(.+)$')
    if id and byId[id] then byId[id].clear(); saveAll() end
  elseif key == 'round' then
    local id, op = string.match(name, '^rnd_(.-)_(%a+)$')
    if id and byId[id] and byId[id].adjust then byId[id].adjust(op, getMillis()) end
  end
  refreshAll(getMillis())
end

function update()
  local now = getMillis()
  local dt = lastFrame and (now - lastFrame) / 1000 or 0
  lastFrame = now
  for _, m in ipairs(modules) do m.tick(now, dt) end
  if now - lastUi >= UI_EVERY_MS then
    lastUi = now
    refreshAll(now)
  end
end

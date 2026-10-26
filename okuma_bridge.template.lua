--[[ ==========================================================================
  okuma interactive — TouchOSC bridge  v4
  OSC in (ESP32 modules)  ->  MIDI out

  v4 = v3 structure + Greg's v12 fill behaviour, lift CCs and round notes.

  This file is a TEMPLATE. build_okuma_layout.py replaces the CONFIG marker
  below with the sensor list and settings from its own config section, then
  puts the result into the root group's script. Edit sensors / CCs / colours /
  timings in the Python file; edit behaviour here.

  TOUCHOSC'S LUA IS SMALL (Lua 5.1). Available base functions are only:
    error ipairs next pairs print select tonumber tostring unpack type
  plus the table, math (+ math.clamp) and string libraries. There is NO
  setmetatable, pcall, assert, require or load — do not use them here, the
  whole script would fail to start ("attempt to call global ... (a nil value)").
  Errors are reported by TouchOSC in its log as "CONTROL(ROOT) RUNTIME ERROR".

  HOW IT IS ORGANISED  (objects built from closures, no metatables)
    newModule    shared parts of every accessory (battery, manual fader,
                 MIDI text). Called first by the constructors below.
    newLoadCell  gaiwan + cups.
                 CALIBRATION: three captured points — NO <OBJECT>, EMPTY,
                 WITH TEA. They define the weight scale; they are not MIDI
                 values any more.
                 FILL (CC, from v12): EMPTY -> EMPTY_MIDI (0) … WITH TEA ->
                 FULL_MIDI (127), linear between, capped at FULL.
                 snap   = lock zone around EMPTY / WITH TEA (± % of empty weight)
                 smooth = extra smoothing of the raw sensor (time constant)
                 LIFT / PUT DOWN (state machine from v3):
                   none     nothing on the scale
                   present  a vessel is resting
                   transit  something is arriving/leaving; becomes none /
                            present once the weight has been still for SETTLE_MS
                 A vessel on the scale can only get LIGHTER by being lifted
                 (tea does not leave a cup that stays put), so a drop of more
                 than LIFT_DROP below the settled weight = lifted, at once.
                 Speed plays no role.
                 OUTPUT while not 'present' (lifted, placing, empty scale):
                   the fill CC HOLDS its last value; the LIFT CC says 127.
                 Once a vessel has settled again ('present'), LIFT CC = 0 and:
                   less tea than before -> the fill glides DOWN linearly,
                                           the whole drop takes FALL_S
                   more tea (pouring)   -> it follows UP with RISE_TAU smoothing
                 LIFT TOGGLE under each column mirrors the lift CC (lit =
                 lifted). It carries the CC itself, so tapping it by hand sends
                 the CC too; the sensor overwrites it only at its next
                 lift / put-down.
                 FULL (rounds): every time a vessel settles at the tea point
                 (ROUND_FULL_AT of the way from empty to tea) the module named
                 in `rounds` is told. It re-arms when the weight has dropped
                 below ROUND_REARM_AT of the way, or the vessel was lifted /
                 the scale was empty — so a refill off the scale counts too.
    newRounds    round counter. +1 each time the gaiwan is full; starts at 0.
                 Sent as a MIDI CC (the count itself, 0–127) AND as a short
                 note (from v12, for Ableton Session scene launch):
                   note = ROUND_NOTE + count   (count 0 = reset note)
                 Every change fires the note — gaiwan full, +1, −1, reset.
                 Notes stop above note 127; the CC stops at 127. Reset must be
                 pressed twice within RESET_CONFIRM_S. The count is kept in
                 the root tag like the calibration.
    newTilt      pitcher. The module sends `tilt` (0..180, from ITS zero) and
                 `dir` (0..360, lean direction). Together they are a direction
                 in space; the script turns them into a unit vector
                   u = (sin t cos d, sin t sin d, cos t)
                 and the pitcher's tilt is the ANGLE BETWEEN u AND THE ZERO
                 VECTOR captured with the ZERO button (acos of the dot product).
                 Why not tiltx / tilty: those are two separate plane angles of
                 the module's own frame; when the pitcher rests far from the
                 module's zero (it does: ~82 deg) they are distorted and wrap at
                 +-180, so sqrt(dx^2 + dy^2) gave 225 deg for a 65 deg tilt.
                 The range fader sets the pour angle that gives 127
                 (RANGE_MIN..RANGE_MAX, step RANGE_STEP). Below POUR_THRESHOLD
                 the output is 0; otherwise tilt / range -> 0..127.
    One object is created per entry in SENSORS; adding a load cell is one
    line in the Python config. Methods are called with a dot: m.tick(...)

  MIDI: the CCs are not sent from this script — every output fader and lift
  toggle carries its own MIDI CC message (Messages tab); the script only moves
  them. The one exception is the round note, sent with sendMIDI on
  MIDI_CHANNEL / MIDI_CONNECTION.

  MANUAL: output faders are touchable. While held, the sensor never
  overwrites them; on release they return to the sensor value (if that
  sensor is sending), otherwise they stay where they were left.

  BATTERY: placeholder. If a number 0–100 arrives on a module's battery
  address it is shown; otherwise "battery —".

  HOW OSC GETS IN: only through the root's onReceiveOSC -> handleOsc. TouchOSC
  hands the root every incoming message first, whether or not a control
  listens on that address (tested 2026-10-14, touchosc/osc-routing-probes.md).
  The labels are display-only. Returning true for a known address stops
  TouchOSC from passing it on to controls. If OSC ever seems not to arrive,
  check TouchOSC's own log.

  CALIBRATION is kept while the layout runs and mirrored into the root
  group's tag ("id=N,E,F;id=…"), which is read back on start (v3 tags work).
========================================================================== ]]

--@@CONFIG@@

local EMPTY_V        = EMPTY_MIDI / 127   -- fill level ends as 0..1
local FULL_V         = FULL_MIDI / 127
local CAPTURE_MS     = 1000    -- capture = mean of readings in this window
local LIVE_MS        = 2000    -- "live" if a value arrived within this time
local BATTERY_OLD_MS = 30000   -- battery reading counts as old after this
local UI_EVERY_MS    = 150     -- text refresh rate
local ROUND_NOTE_MS  = 150     -- length of the round note

-- connection list for sendMIDI: only MIDI_CONNECTION is on
local MIDI_CONN = {}
for i = 1, 10 do MIDI_CONN[i] = (i == MIDI_CONNECTION) end

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
  self.ui.lift      = find(p .. 'lift')        -- toggle, carries the lift CC
  self.ui.liftLbl   = find(p .. 'lift_lbl')
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

  -- lifted = anything but a settled vessel (lifted, being placed, empty scale).
  -- Written to the toggle only when it changes, so a hand tap stays until the
  -- next real lift / put-down.
  function self.setLifted(lifted)
    if self.lifted == lifted then return end
    self.lifted = lifted
    local x = lifted and 1 or 0
    if self.ui.lift and self.ui.lift.values.x ~= x then self.ui.lift.values.x = x end
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
      if w > self.ref then                         -- filling: follow upwards
        -- fix 11: at most RISE_SLEW of the empty -> tea step per second, so a hand pressing on the vessel or
        -- lifting its lid (a very fast rise) neither moves the fill nor counts as a
        -- level to drop from (pouring is far slower)
        if RISE_SLEW > 0 and self.dt then
          local span = self.teaW()               -- empty -> tea, in weight units
          span = span and (span - 1) or 1
          self.ref = math.min(w, self.ref + RISE_SLEW * span * self.dt)
        else
          self.ref = w
        end
      end
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
    self.setLifted(self.state ~= 'present')
    self.checkFull(w, now)
  end

  -- fix 11: auto-tare. A scale that reads (nearly) nothing and stays still for
  -- TARE_HOLD_S takes that reading as the new NO point, so slow drift and the
  -- small rest after removing a vessel never need a manual NO capture. Only
  -- within TARE_BAND of NO, so a lid alone (about 0.2) is never tared away.
  function self.autoTare(w, now)
    if TARE_HOLD_S <= 0 or math.abs(w) > TARE_BAND then self.tareT = nil; return false end
    if not self.tareT or math.abs(w - self.tareW) > STABLE_BAND then
      self.tareW, self.tareT = w, now
      return false
    end
    if now - self.tareT < TARE_HOLD_S * 1000 then return false end
    self.tareT = now                       -- next adjustment after another hold
    if math.abs(w) < 0.002 then return false end
    self.N = self.N + w * (self.E - self.N)
    self.restart()                         -- classify the scale afresh
    saveAll()
    return true
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
    local above = self.state == 'present' and w >= fullW
    -- fix 11: "full" must also be held still for FULL_HOLD_S, so a hand pressing
    -- on the vessel or lifting its lid (a short, moving peak) does not count
    local held = false
    if above then
      if not self.fullSince or math.abs(w - self.fullW) > STABLE_BAND then
        self.fullSince, self.fullW = now, w
      end
      held = now - self.fullSince >= FULL_HOLD_S * 1000
    else
      self.fullSince = nil
    end
    if self.firstLook then
      self.firstLook = false
      self.armed = not above
    elseif self.state ~= 'present' then
      self.armed = true                -- lifted / arriving: counts next time it is full
    elseif held then
      if self.armed then
        self.armed = false
        if self.rounds then self.rounds.fullHit(now) end
      end
    elseif w < rearmW then
      self.armed = true
    end
  end

  -- fill level 0..1 of a resting vessel: EMPTY -> EMPTY_V … WITH TEA -> FULL_V
  -- (capped). Without the tea point there is no scale yet: EMPTY_V.
  function self.map(v)
    local w, wF = self.weight(v), self.teaW()
    if not w then return nil end
    if not wF then return EMPTY_V end
    local tol = self.ui.snap.values.x * SNAP_MAX
    if math.abs(w - 1) <= tol then return EMPTY_V end
    if math.abs(w - wF) <= tol then return FULL_V end
    return EMPTY_V + (FULL_V - EMPTY_V) * math.clamp((w - 1) / (wF - 1), 0, 1)
  end

  -- move the output toward the goal: down = linear (whole drop in FALL_S),
  -- up = smoothed with RISE_TAU
  function self.glide(dt)
    local goal, out = self.goal, self.out
    if goal < out then
      if FALL_S <= 0 then self.out = goal; return end
      local rate = self.fallRate or (out - goal) / FALL_S
      self.out = math.max(goal, out - rate * dt)
    elseif goal > out then
      self.fallRate = nil
      if RISE_TAU <= 0 then self.out = goal; return end
      self.out = out + (goal - out) * (1 - math.exp(-dt / RISE_TAU))
      if goal - self.out < 0.002 then self.out = goal end
    end
  end

  function self.capture(point)
    local key = POINT_KEY[point]
    if not key or not self.target then return end
    local now, sum, n = getMillis(), 0, 0
    for _, h in ipairs(self.hist) do
      if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
    end
    self[key] = n > 0 and sum / n or self.target   -- quiet module: last value
    self.restart()
  end

  function self.clear()
    self.N, self.E, self.F = nil, nil, nil
    self.restart()
  end

  -- fresh look: the next reading classifies the scale again and the output
  -- jumps straight to it (no glide)
  function self.restart()
    self.state, self.goal, self.fallRate, self.jump = nil, nil, nil, true
  end
  self.jump = true

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
      self.restart()                    -- released: hand the fader back to the sensor
    end
    if held or not self.target then return end

    local tau = self.ui.smooth.values.x * SMOOTH_MAX
    if tau <= 0.001 then
      self.raw = self.target
    else
      self.raw = self.raw + (self.target - self.raw) * (1 - math.exp(-dt / tau))
    end

    local w = self.weight(self.target)
    if not w then self.state = nil; return end
    if self.autoTare(w, now) then w = self.weight(self.target) end
    self.dt = dt
    self.step(w, now)

    if self.state == 'present' then
      local v = self.raw
      -- a little lighter than the settled weight (evaporation, jitter, or the very
      -- start of a lift): hold the settled level instead of sagging with it
      if w < self.ref then v = self.N + self.ref * (self.E - self.N) end
      -- fix 11: while the weight is above the settled level (ref, which rises at most
      -- RISE_SLEW of the empty -> tea step per second, see step) the fill follows ref, not the raw weight
      if RISE_SLEW > 0 and w > self.ref then v = self.N + self.ref * (self.E - self.N) end
      local goal = self.map(v)
      if goal then
        if self.goal and goal < self.goal - 0.0005 then
          self.fallRate = nil            -- a new, lower goal: restart the linear fall
        end
        if not self.goal or math.abs(goal - self.goal) > 0.0005 then self.goal = goal end
      end
    end
    -- not present (lifted / placing / empty scale): the goal stays = output holds

    if not self.goal then return end
    if self.jump or not self.out then
      self.out, self.jump = self.goal, false
    else
      if self.goal < self.out and not self.fallRate and FALL_S > 0 then
        self.fallRate = (self.out - self.goal) / FALL_S
      end
      self.glide(dt)
    end
    self.setOut(self.out)
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
    elseif not self.F then
      setText(u.outval, self.midiText(false) .. '   need TEA')
    else
      local s = self.midiText(false)
      if self.state ~= 'present' then s = s .. '   held'
      elseif self.goal and self.out and self.out > self.goal + 0.002 then s = s .. '   falling' end
      setText(u.outval, s)
    end

    local on = u.lift and u.lift.values.x > 0.5
    setText(u.liftLbl, string.format('%s   CC %d = %d', on and 'LIFTED' or 'on the scale',
                                     cfg.lift_cc, on and 127 or 0))

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
  self.ui.inTilt  = find(p .. 'in_tilt')
  self.ui.inDir   = find(p .. 'in_dir')
  self.ui.tilt    = find(p .. 'tilt')
  self.ui.pour    = find(p .. 'pour')
  self.ui.zeroVal = find(p .. 'zero_val')
  self.ui.range    = find(p .. 'range')
  self.ui.rangeVal = find(p .. 'range_val')
  self.v    = {}                      -- latest module values: v.t (tilt), v.d (dir)
  self.at   = {}                      -- when each arrived
  self.hist = {}                      -- recent unit vectors {t, x, y, z} for capture

  -- direction in space from the module's tilt / dir (degrees)
  local function unit(t, d)
    local tr, dr = math.rad(t), math.rad(d)
    return math.sin(tr) * math.cos(dr), math.sin(tr) * math.sin(dr), math.cos(tr)
  end

  -- axis is 't' (/tilt) or 'd' (/dir)
  function self.receiveAxis(axis, v, now)
    self.v[axis], self.at[axis] = v, now
    if not (self.v.t and self.v.d) then return end
    local x, y, z = unit(self.v.t, self.v.d)
    table.insert(self.hist, { t = now, x = x, y = y, z = z })
    while #self.hist > 1 and (#self.hist > 120 or self.hist[1].t < now - CAPTURE_MS) do
      table.remove(self.hist, 1)
    end
  end

  -- total tilt = angle between the current direction and the zero direction.
  -- Until ZERO is captured the zero is the module's own (0, 0, 1): tilt = module tilt.
  function self.tilt()
    if not (self.v.t and self.v.d) then return nil end
    local x, y, z = unit(self.v.t, self.v.d)
    local zx, zy, zz = self.z1 or 0, self.z2 or 0, self.z3 or 1
    local dot = math.clamp(x * zx + y * zy + z * zz, -1, 1)
    return math.deg(math.acos(dot))
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

  -- 'zero': the pitcher rests now -> remember its direction (mean of the last 1 s)
  function self.capture(point)
    if point ~= 'zero' or #self.hist == 0 then return end
    local now, sx, sy, sz, n = getMillis(), 0, 0, 0, 0
    for _, h in ipairs(self.hist) do
      if h.t >= now - CAPTURE_MS then sx = sx + h.x; sy = sy + h.y; sz = sz + h.z; n = n + 1 end
    end
    if n == 0 then                                   -- quiet module: last value
      local h = self.hist[#self.hist]
      sx, sy, sz, n = h.x, h.y, h.z, 1
    end
    local m = math.sqrt(sx * sx + sy * sy + sz * sz)
    if m < 0.001 then return end
    self.z1, self.z2, self.z3 = sx / m, sy / m, sz / m
  end

  function self.serialize()
    local function f(v) return v and string.format('%.5f', v) or '' end
    return f(self.z1) .. ',' .. f(self.z2) .. ',' .. f(self.z3)
  end

  -- three numbers forming a unit vector. Anything else (a v4 tag from before fix 10
  -- held two angles, tiltx / tilty) is ignored: press ZERO again.
  function self.restore(s)
    local vals = {}
    for field in string.gmatch(s .. ',', '([^,]*),') do vals[#vals + 1] = tonumber(field) end
    local a, b, c = vals[1], vals[2], vals[3]
    if #vals ~= 3 or not (a and b and c) then return end
    local m = math.sqrt(a * a + b * b + c * c)
    if math.abs(m - 1) > 0.01 then return end
    self.z1, self.z2, self.z3 = a / m, b / m, c / m
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
      local live = now - math.min(self.at.t, self.at.d) < LIVE_MS
      setText(u.status, string.format('tilt %.1f°   %s', t, live and 'live' or 'no data'))
      setText(u.tilt, string.format('%.1f°', t))
      setText(u.pour, t >= POUR_THRESHOLD and 'pouring' or string.format('below %g°', POUR_THRESHOLD))
    else
      setText(u.status, 'tilt —   waiting')
      setText(u.tilt, '—')
      setText(u.pour, '—')
    end
    setText(u.inTilt, self.v.t and string.format('in %.1f°', self.v.t) or 'in —')
    setText(u.inDir, self.v.d and string.format('dir %.0f°', self.v.d) or 'dir —')
    if self.z1 then
      local zt = math.deg(math.acos(math.clamp(self.z3, -1, 1)))
      local zd = math.deg(math.atan2(self.z2, self.z1))
      if zd < 0 then zd = zd + 360 end
      setText(u.zeroVal, string.format('%.1f° @ %.0f°', zt, zd))
    else
      setText(u.zeroVal, '—')
    end
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
  self.noteOffs = {}     -- note -> time to send its note-off

  -- short note for the current count (ROUND_NOTE + count; count 0 = reset note)
  local function fireNote()
    local n = cfg.note + self.count
    if n > 127 then return end
    sendMIDI({ 0x90 + MIDI_CHANNEL - 1, n, 127 }, MIDI_CONN)
    self.noteOffs[n] = getMillis() + ROUND_NOTE_MS
    self.lastNote = n
  end

  -- force: fire the note even if the count did not change (reset at 0)
  local function setCount(n, force)
    local before = self.count
    self.count = math.max(0, math.min(127, n))     -- it goes out as a MIDI CC value
    self.out = nil
    saveAll()
    if force or self.count ~= before then fireNote() end
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
        setCount(0, true)                          -- reset note even if already 0
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
    for n, at in pairs(self.noteOffs) do
      if now >= at then
        sendMIDI({ 0x80 + MIDI_CHANNEL - 1, n, 0 }, MIDI_CONN)
        self.noteOffs[n] = nil
      end
    end
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
    local n = cfg.note + self.count
    setText(u.outval, self.midiText(self.isHeld()) ..
                      (n <= 127 and string.format('   note %d', n) or '   no note'))
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

-- one entry point for received numbers
local function handleOsc(path, v)
  local route = routes[path]
  if not route or type(v) ~= 'number' then return false end
  local m, what = route[1], route[2]
  if what == 'value' then m.receive(v, getMillis())
  elseif what == 'battery' then m.onBattery(v, getMillis())
  else m.receiveAxis(what, v, getMillis()) end      -- 't' / 'd' (pitcher tilt, dir)
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
    if cfg.osc_tilt then routes[cfg.osc_tilt] = { m, 't' } end
    if cfg.osc_dir then routes[cfg.osc_dir] = { m, 'd' } end
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
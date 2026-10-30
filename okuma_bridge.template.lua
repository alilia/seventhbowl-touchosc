--[[ ==========================================================================
  Seventh Bowl — TouchOSC bridge  v6
  OSC in (ESP32 modules)  ->  MIDI out

  v6 = the vessel (gaiwan, cups) logic rebuilt as ON/OFF STATES instead of a
  fill amount: PRESENT (on the scale), FULL (more full than empty) and DRUNK
  (an empty vessel that was drunk, as opposed to one waiting for tea). Each is
  a MIDI CC that ramps 0 <-> 127 with its own rise / fall time. The logic runs
  every frame from the level fader, which OSC drives and a hand can drag, so
  the whole ceremony can be played from the screen without any sensor.

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
    newModule    shared parts of every accessory (battery, status, fader).
    newRamp      one on/off MIDI output: a tap toggle on screen that shows the
                 TARGET (lit = on) and a CC the script sends itself, moving
                 linearly to the target (rise_s up, fall_s down, 0 = jump). A
                 hand tap sets the target the same way; the logic takes over
                 again the next time ITS value for that output changes.
    newVessel    gaiwan + cups (one template, `kind = 'loadcell'`).
      UNITS      w = (reading - N) / dE   0 = nothing on the scale, 1 = the
                 empty vessel as captured. N (NO) is live: drift is tared away.
                 pour p = the setting `pour` (counts) / dE.
      LEVEL FADER (the input): 0 = away, 0.5 = the empty vessel as it stands
                 NOW (the reference of this round), 1 = reference + one pour.
                 OSC moves it; dragging it feeds the logic exactly like a
                 sensor (simulation). Because the reference is re-taken every
                 round, the empty vessel always sits on the middle line and a
                 full one at the top, whatever the spot it stands on.
                 Without a calibration it still works (NO = 0, EMPTY = 1).
      PRESENT    w >= PRESENT_AT (half an empty vessel) for PRESENT_MS -> on;
                 below PRESENT_AT - PRESENT_HYST for PRESENT_MS -> off.
      SETTLED    the weight stayed within STILL_BAND for SETTLE_MS.
      STATES     waiting -> full -> drunk -> (round change) -> waiting
        POUR     standing, still for `pour_hold` s, risen >= POUR_FRACTION × p
                 above the base (the settled weight; it follows drift and
                 falls, small rises < DRIFT_FRACTION × p), and — for vessels
                 with `gate = 'pitcher'` — the pitcher is pouring or poured
                 within GATE_S (a silent pitcher opens the gate). -> FULL, also
                 from full / drunk (a top-up). The gaiwan tells the rounds.
        DRUNK    a FULL vessel settles back after being away and is lighter
                 than when it was full by >= DRINK_FRACTION of what was poured.
                 A lighter-but-not-enough return stays FULL (sips add up).
        ROUND    every change of the round count (`reset_on_round` vessels):
                 state -> waiting, and the reference is re-taken from where the
                 vessel stands (or at its next put-down if it is away).
        Re-anchor: an empty vessel (waiting / drunk) that settles takes its
                 current weight as the reference (the fader shows 0.5).
      TARE       away, |w| <= tare band, still TARE_HOLD_S -> N takes the
                 reading; everything remembered shifts with it (no restart).
      CAPTURES   NO and EMPTY, any order (a value waits for its reference).
    newRounds    round counter. +1 each time tea (water) is poured into the
                 gaiwan, +1 / −1 / reset by hand. May go below 0 (a warming
                 round). Every change sends ONE note-on, channel MIDI_CHANNEL,
                 velocity 127, note = `note` + max(count, 0) (below 0 -> note
                 `note`); no note-off, no CC. Every change resets the cups.
    newTilt      pitcher (unchanged from v5 fix 10): tilt = angle between the
                 current direction (tilt + dir) and the ZERO direction; below
                 POUR_THRESHOLD -> 0, else tilt / range -> 0..127 (its fader
                 carries CC). Also tells the vessels whether it is pouring.

  MIDI: vessel outputs are sent with sendMIDI (CONTROL CHANGE) on
  MIDI_CHANNEL / MIDI_CONNECTION; the pitcher's fader carries its own CC; the
  round note is sent with sendMIDI.

  HOW OSC GETS IN: only through the root's onReceiveOSC -> handleOsc (tested
  2026-10-14, touchosc/osc-routing-probes.md).

  SAVED in the root tag: "id=v6:N,dE,state;rounds=count;pitcher=zero".
  v5 ("v5:N,dE,…") and v4 ("N,E,F") vessel tags are read too.
========================================================================== ]]

--@@CONFIG@@

local CAPTURE_MS     = 1000    -- capture = mean of readings in this window
local LIVE_MS        = 2000    -- "live" if a value arrived within this time
local BATTERY_OLD_MS = 30000   -- battery reading counts as old after this
local UI_EVERY_MS    = 150     -- text refresh rate

-- connection list for sendMIDI: only MIDI_CONNECTION is on
local MIDI_CONN = {}
for i = 1, 10 do MIDI_CONN[i] = (i == MIDI_CONNECTION) end

-- ---------------------------------------------------------------------------
--  helpers
-- ---------------------------------------------------------------------------
local saveAll        -- defined in the registry section
local newRound       -- defined in the registry section (a round change resets vessels)
local pitcherGate    -- defined in the registry section (is the pitcher pouring?)

local function find(name)
  local c = root:findByName(name, true)
  if not c then print('okuma: control not found: ' .. name) end
  return c
end

local function setText(ctrl, s)
  if ctrl and ctrl.values.text ~= s then ctrl.values.text = s end
end

local function num(v) return v and string.format('%.0f', v) or '—' end

local function sendCC(cc, v)
  sendMIDI({ 0xB0 + MIDI_CHANNEL - 1, cc, v }, MIDI_CONN)
end

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
--  newRamp — one on/off output: tap toggle (target) + CC ramp sent by script
-- ---------------------------------------------------------------------------
local function newRamp(ctlName, lblName, cc, riseS, fallS)
  local r = { cc = cc, goal = 0, out = 0, x = 0 }
  local ctl, lbl = find(ctlName), find(lblName)

  -- the logic's value; only a CHANGE overrides a hand tap
  function r.set(on)
    local g = on and 1 or 0
    if r.logic == g then return end
    r.logic, r.goal = g, g
    if ctl and ctl.values.x ~= g then ctl.values.x = g end
    r.x = g
  end

  function r.tick(dt)
    if ctl and ctl.values.x ~= r.x then           -- a hand tap
      r.x = ctl.values.x
      r.goal = (r.x > 0.5) and 1 or 0
    end
    local cur, goal = r.out, r.goal
    if cur ~= goal then
      local secs = (goal > cur) and riseS or fallS
      if secs <= 0 then cur = goal
      elseif goal > cur then cur = math.min(goal, cur + dt / secs)
      else cur = math.max(goal, cur - dt / secs) end
      r.out = cur
    end
    local v = math.floor(r.out * 127 + 0.5)
    if v ~= r.sent then
      r.sent = v
      sendCC(cc, v)
    end
  end

  function r.refresh()
    setText(lbl, string.format('CC %d = %d', cc, r.sent or 0))
  end

  return r
end

-- ---------------------------------------------------------------------------
--  newVessel — gaiwan, cups: present / full / drunk (see header)
-- ---------------------------------------------------------------------------
local function newVessel(cfg)
  local self = newModule(cfg)
  local p = cfg.id .. '_'
  self.ui.state   = find(p .. 'state')
  self.ui.pts = { none = find(p .. 'none_val'), empty = find(p .. 'empty_val') }
  self.present = newRamp(p .. 'present', p .. 'present_val', cfg.present_cc,
                         PRESENT_RISE_S, PRESENT_FALL_S)
  self.full    = newRamp(p .. 'full', p .. 'full_val', cfg.cc, FULL_RISE_S, FULL_FALL_S)
  self.drunk   = newRamp(p .. 'drunk', p .. 'drunk_val', cfg.drunk_cc,
                         DRUNK_RISE_S, DRUNK_FALL_S)
  self.hist = {}                       -- recent raw readings {t, v} for capture
  self.state = 'waiting'               -- waiting | full | drunk
  self.isPresent = false
  self.tareBand = cfg.tare_band or TARE_BAND
  self.pourHold = (cfg.pour_hold or POUR_HOLD_S) * 1000

  -- calibration: N (NO, live) and dE (empty step). Missing -> 0 / 1 (simulation)
  local function nN() return self.N or 0 end
  local function nE() if self.dE and self.dE ~= 0 then return self.dE end return 1 end
  local function pourW()                       -- one pour in empty-vessel units
    if self.dE and self.dE ~= 0 and cfg.pour then return math.abs(cfg.pour / self.dE) end
    return 1
  end

  -- level fader <-> weight, around the reference of this round (refW, default 1)
  local function ref() return self.refW or 1 end
  function self.levelOf(w)
    local r = ref()
    if r <= 0.05 then r = 1 end
    if w <= r then return math.clamp(0.5 * w / r, 0, 0.5) end
    return math.clamp(0.5 + 0.5 * (w - r) / pourW(), 0.5, 1)
  end
  function self.weightOf(l)
    local r = ref()
    if r <= 0.05 then r = 1 end
    if l <= 0.5 then return l / 0.5 * r end
    return r + (l - 0.5) / 0.5 * pourW()
  end

  -- -------- input: OSC reading (raw counts)
  function self.receive(v, now)
    self.raw, self.last = v, now
    table.insert(self.hist, { t = now, v = v })
    while #self.hist > 1 and (#self.hist > 60 or self.hist[1].t < now - CAPTURE_MS) do
      table.remove(self.hist, 1)
    end
    if not self.isHeld() then self.w = (v - nN()) / nE() end
  end

  function self.setRounds(r) self.rounds = r end

  -- -------- events
  local function pour(w, now)
    local was = self.state
    if was ~= 'full' then self.preW = math.min(ref(), self.base or w) end   -- the empty level
    self.state = 'full'
    self.fullW = w
    self.pouredW = w - (self.preW or ref())
    self.base = w
    self.pours = (self.pours or 0) + 1
    self.lastEvent = 'pour'
    -- a round = the gaiwan goes from not-full to full (a second step of the same pour is a top-up)
    if self.rounds and was ~= 'full' then self.rounds.fullHit(now) end
    saveAll()
  end

  -- settled after being away (or first time seen)
  local function arrive(w, now)
    if self.state == 'full' and self.fullW and self.pouredW and self.pouredW > 0
       and self.wasAway and (self.fullW - w) >= DRINK_FRACTION * self.pouredW then
      self.state = 'drunk'
      self.lastEvent = 'drunk'
      saveAll()
    end
    if self.state ~= 'full' then self.refW = w end   -- an empty vessel: this spot is the reference
    self.refPending = false
    self.base = w
    self.wasAway = false
  end

  -- a round change (from the rounds module)
  function self.roundReset(now)
    if not cfg.reset_on_round then return end
    self.state = 'waiting'
    self.fullW, self.pouredW, self.preW = nil, nil, nil
    if self.isPresent and self.settled and self.w then
      self.refW, self.base = self.w, self.w
    else
      self.refPending = true
    end
    self.lastEvent = 'round'
    saveAll()
  end

  -- -------- the logic, every frame
  local function logic(now, dt)
    local w = self.w
    if not w then return end

    -- still?
    if not self.stillW or math.abs(w - self.stillW) > STILL_BAND then
      self.stillW, self.stillT = w, now
    end
    local stillFor = now - self.stillT

    -- present (debounced)
    local want
    if w >= PRESENT_AT then want = true
    elseif w < PRESENT_AT - PRESENT_HYST then want = false
    else want = self.isPresent end
    if want ~= self.isPresent then
      self.flipT = self.flipT or now
      if now - self.flipT >= PRESENT_MS then
        self.isPresent, self.flipT = want, nil
        self.settled = false
        if not want then self.wasAway = true; self.awayT = now end
      end
    else
      self.flipT = nil
    end

    if self.isPresent then
      if not self.settled and stillFor >= SETTLE_MS then
        self.settled = true
        arrive(w, now)
      end
      if self.settled then
        if not self.base or w < self.base then self.base = w end          -- falls / downward drift follow
        if stillFor >= self.pourHold then
          local pw = pourW()
          local rise = w - self.base
          if rise >= POUR_FRACTION * pw then
            if not cfg.gate or pitcherGate(now) then pour(w, now) end
          elseif self.state == 'full' and self.fullW and w > self.fullW then
            self.fullW = w                                 -- the rest of a pour in steps
            self.pouredW = w - (self.preW or ref())
            self.base = w
          elseif rise < DRIFT_FRACTION * pw then
            self.base = w                                  -- small rise: drift
          end
        end
      end
    else
      self.settled = false
      -- tare: away, close to NO, still
      if self.N and TARE_HOLD_S > 0 and math.abs(w) <= self.tareBand
         and stillFor >= TARE_HOLD_S * 1000 and math.abs(w) > 0.002 and not self.isHeld() then
        self.N = self.N + w * nE()
        for _, k in ipairs({ 'w', 'stillW', 'base', 'refW', 'fullW', 'preW' }) do
          if self[k] then self[k] = self[k] - w end
        end
        self.tares = (self.tares or 0) + 1
        saveAll()
      end
    end
  end

  -- -------- calibration (any order, fix 2 of v5)
  local function settle()
    if self.N and not self.dE and self.pE then self.dE = self.pE - self.N; self.pE = nil end
  end

  function self.point(key)
    if key == 'none' then return self.N end
    return (self.N and self.dE) and (self.N + self.dE) or self.pE
  end

  function self.capture(point)
    if not self.raw then return end
    local now, sum, n = getMillis(), 0, 0
    for _, h in ipairs(self.hist) do
      if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
    end
    local m = n > 0 and sum / n or self.raw
    if point == 'none' then
      self.N = m
    elseif point == 'empty' then
      if self.N then self.dE = m - self.N; self.pE = nil else self.dE, self.pE = nil, m end
    else
      return
    end
    settle()
    self.refW, self.base, self.stillW, self.settled = nil, nil, nil, false
    if self.raw then self.w = (self.raw - nN()) / nE() end
  end

  function self.clear()
    self.N, self.dE, self.pE, self.refW, self.base, self.settled = nil, nil, nil, nil, nil, false
    if self.raw then self.w = (self.raw - nN()) / nE() end
  end

  function self.serialize()
    local function f(v) return v and string.format('%.1f', v) or '' end
    return 'v6:' .. f(self.N) .. ',' .. f(self.dE) .. ',' .. self.state
  end

  function self.restore(s)
    local vals, k = {}, 0
    local tagv = string.match(s, '^(v%d):')
    if tagv then s = string.sub(s, 4) end
    for field in string.gmatch(s .. ',', '([^,]*),') do
      k = k + 1
      if k > 4 then break end
      vals[k] = field
    end
    local a, b = tonumber(vals[1] or ''), tonumber(vals[2] or '')
    if tagv == 'v6' or tagv == 'v5' then
      self.N, self.dE = a, b
      if tagv == 'v6' and (vals[3] == 'full' or vals[3] == 'drunk' or vals[3] == 'waiting') then
        self.state = vals[3]
      end
    else                                           -- v3 / v4: absolute N, E, F
      self.N = a
      self.dE = (a and b) and (b - a) or nil
    end
  end

  function self.tick(now, dt)
    -- the fader is the input: a hand on it sets w (simulation), else it shows w
    if self.isHeld() then
      self.w = self.weightOf(self.ui.out.values.x)
      self.simAt = now
    elseif self.w then
      self.setOut(self.levelOf(self.w))
    end
    logic(now, dt)
    self.present.set(self.isPresent)
    self.full.set(self.state == 'full')
    self.drunk.set(self.state == 'drunk')
    self.present.tick(dt)
    self.full.tick(dt)
    self.drunk.tick(dt)
  end

  function self.refresh(now)
    local u = self.ui
    local src
    if self.last and now - self.last < LIVE_MS and not (self.simAt and self.simAt > self.last) then
      src = 'live'
    elseif self.simAt and (not self.last or self.simAt > self.last) then
      src = 'hand'
    elseif self.last then
      src = string.format('steady %ds', math.floor((now - self.last) / 1000))
    else
      src = 'no data'
    end
    setText(u.status, string.format('raw %s   %s', self.raw and string.format('%.0f', self.raw) or '—', src))
    local cal = (self.N and self.dE) and '' or '   (not calibrated)'
    setText(u.outval, self.w and string.format('w %.2f   level %d%%%s', self.w,
            math.floor(self.levelOf(self.w) * 100 + 0.5), cal) or ('—' .. cal))
    local st = string.upper(self.state)
    if self.refPending then st = st .. '  (ref at put-down)' end
    if self.isPresent and not self.settled then st = st .. '  settling' end
    setText(u.state, st)
    self.present.refresh()
    self.full.refresh()
    self.drunk.refresh()
    setText(u.pts.none, num(self.point('none')))
    setText(u.pts.empty, num(self.point('empty')))
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
    if self.isHeld() then                               -- held = manual (also a test pour)
      self.handAt = now
      if self.ui.out.values.x > 0 then self.pourAt = now end
      return
    end
    local t = self.tilt()
    if t then
      local l = self.level(t)
      self.setOut(l)
      if l > 0 and now - math.min(self.at.t, self.at.d) < LIVE_MS then self.pourAt = now end
    end
  end

  -- the pitcher gate for the vessels: open while pouring and GATE_S after it.
  -- A pitcher that has neither sent data nor been touched for GATE_SILENT_S
  -- opens the gate (the vessels then count on weight alone).
  function self.gateOpen(now)
    if self.pourAt and now - self.pourAt <= GATE_S * 1000 then return true end
    local lastData = (self.at.t and self.at.d) and math.min(self.at.t, self.at.d) or nil
    local lastSeen = math.max(lastData or -1e12, self.handAt or -1e12)
    return now - lastSeen > GATE_SILENT_S * 1000
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
    setText(u.outval, self.midiText(self.isHeld() or not t) ..
                      (self.gateOpen(now) and '   gate open' or '   gate shut'))
    self.refreshBattery(now)
  end

  return self
end

-- ---------------------------------------------------------------------------
--  newRounds — round counter (may go below 0; note-on only)
-- ---------------------------------------------------------------------------
local function newRounds(cfg)
  local self = newModule(cfg)
  local p = cfg.id .. '_'
  self.ui.count = find(p .. 'count')
  self.count = 0

  local function noteOf(c) return cfg.note + math.max(c, 0) end

  -- one note-on, velocity 127, no note-off; below 0 -> the lowest note
  local function fireNote()
    local n = noteOf(self.count)
    if n > 127 then return end
    sendMIDI({ 0x90 + MIDI_CHANNEL - 1, n, 127 }, MIDI_CONN)
    self.lastNote = n
  end

  -- force: fire the note even if the count did not change (reset at 0)
  local function setCount(n, force)
    local before = self.count
    self.count = math.max(-127, math.min(127, n))
    self.out = nil
    saveAll()
    if force or self.count ~= before then
      fireNote()
      newRound(getMillis())
    end
  end

  -- called by the gaiwan every time water is poured into it
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
    if n then self.count = math.max(-127, math.min(127, math.floor(n))) end
  end

  function self.tick(now, dt)
    if self.zeroAt and now - self.zeroAt > RESET_CONFIRM_S * 1000 then self.zeroAt = nil end
    if self.isHeld() then return end
    local x = math.max(self.count, 0) / 127
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
      local s = string.format('%s filled → +1', cfg.source or 'vessel')
      if self.lastAt then
        s = s .. string.format('   (last %ds ago)', math.floor((now - self.lastAt) / 1000))
      end
      setText(u.status, s)
    end
    local n = noteOf(self.count)
    setText(u.outval, n <= 127 and string.format('note %d (ch %d)', n, MIDI_CHANNEL) or 'no note')
  end

  return self
end

-- ---------------------------------------------------------------------------
--  registry: one object per SENSORS entry, OSC address -> object
-- ---------------------------------------------------------------------------
local KINDS = { loadcell = newVessel, tilt = newTilt, rounds = newRounds }
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

function newRound(now)
  for _, m in ipairs(modules) do
    if m.roundReset then m.roundReset(now) end
  end
end

-- open when no pitcher exists
function pitcherGate(now)
  for _, m in ipairs(modules) do
    if m.gateOpen then return m.gateOpen(now) end
  end
  return true
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

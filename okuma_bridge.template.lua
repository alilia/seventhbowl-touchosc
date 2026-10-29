--[[ ==========================================================================
  Seventh Bowl — TouchOSC bridge  v5
  OSC in (ESP32 modules)  ->  MIDI out

  v5 = v4 + fill by EVENTS instead of by weight (the weight of a load cell
  depends on where the vessel stands, so the number can't be trusted for the
  level), steps stored as offsets from the live NO point, tare whenever the
  scale is empty and still.

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
                 CALIBRATION (captured once, vessel in the MIDDLE of its place):
                   NO     the empty scale  -> N, kept LIVE (drifts, tared)
                   EMPTY  the empty vessel -> stored as a STEP above NO (dE)
                   TEA    vessel with tea  -> stored as a STEP above EMPTY (dF)
                 Steps, not absolute values: drift moves the whole curve, so a
                 tare (new NO) moves all three points together.
                 WEIGHT w = (reading - N) / dE : 0 = nothing, 1 = empty vessel.
                 It is only used to see EVENTS (arrive / lift / pour); it is
                 never mapped to the level, because a load cell reads very
                 differently depending on where the vessel stands.
                 FILL (the CC) is a stored 0..1 level changed by events:
                   POUR     while standing, the weight rises by POUR_FRACTION of
                            the tea step and stays still for FULL_HOLD_S
                            -> fill = 100 %  (and the gaiwan tells the rounds)
                   SIP      the vessel was off the scale for at least MIN_LIFT_S
                            and comes back -> fill - `sip` (cups 0.33: three
                            sips; the gaiwan 1.0: empty). Never goes up on a
                            return. Capped 0..100 %.
                   `pour_on_return` (gaiwan): a lid-off refill comes back
                            heavier than it left -> counts as a pour.
                 The CC HOLDS while the vessel is lifted; after a put-down a
                 lower fill glides down over FALL_S, a higher one follows with
                 RISE_TAU. The LIFT CC ramps 0 <-> 127 over LIFT_RISE_S (up) and
                 LIFT_FALL_S (down); it is a target (self.lifted) with a moving output.
                 snap   = "off the scale" band (± % of the empty step, default 50 %):
                          below it the vessel is away (sip / lift), above it present
                 WOBBLE (v5 fix 1): vessels stand only roughly in the middle, so
                 the same vessel reads differently after every put-down. Every
                 event is therefore measured from where the vessel settled THIS
                 time (the base), never from the captured numbers, and the pour
                 threshold shrinks for a spot that reads light (seat < 1).
                 smooth = extra smoothing of the raw sensor (time constant)
                 LIFT / PUT DOWN (state machine from v3):
                   none     nothing on the scale
                   present  a vessel is resting
                   transit  something is arriving/leaving; becomes none /
                            present once the weight has been still for SETTLE_MS
                 A vessel on the scale can only get LIGHTER by being lifted, so a
                 drop of more than LIFT_DROP below the settled weight = lifted.
                 The lift CC says 127 whenever the state is not 'present'.
                 LIFT TOGGLE under each column mirrors the lift CC (lit = lifted);
                 it carries the CC itself, so tapping it by hand sends it too.
                 TARE (v5 fix 1): whenever the scale is off (vessel away), within
                 the tare band (TARE_BAND, the gaiwan its own `tare_band` so a lid
                 alone is never tared) and still for TARE_HOLD_S, NO takes that
                 reading. That includes every round start and every long sip. It
                 does not interrupt a lift in progress.
    newRounds    round counter. +1 each time tea is poured into the gaiwan; starts at 0.
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
  group's tag ("id=v5:N,dE,dF,fill;id=…"), read back on start (v4 tags "N,E,F" and v3 tags work).
========================================================================== ]]

--@@CONFIG@@

local EMPTY_V        = EMPTY_MIDI / 127   -- fill level ends as 0..1
local FULL_V         = FULL_MIDI / 127
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
local saveAll      -- defined in the registry section (the rounds counter calls it)
local resetCups    -- defined in the registry section (a round change empties the cups)

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
local POINTS = { 'none', 'empty', 'tea' }

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
  self.sip = cfg.sip or 0.33
  self.seat = 1          -- how heavy the current spot reads (1 = like the capture)
  self.tareBand = cfg.tare_band or TARE_BAND

  function self.receive(v, now)
    self.target = v
    if not self.raw then self.raw = v end
    self.last = now
    table.insert(self.hist, { t = now, v = v })
    while #self.hist > 1 and (#self.hist > 50 or self.hist[1].t < now - CAPTURE_MS) do
      table.remove(self.hist, 1)
    end
  end

  -- calibration: N = NO point (live), dE = empty step above N, dF = tea step above EMPTY
  -- tea step in weight units (1 = the empty step); nil unless it points the same way
  function self.teaW()
    if not (self.dE and self.dF) or self.dE == 0 then return nil end
    local t = self.dF / self.dE
    if t <= 0 then return nil end
    return t
  end

  -- weight in empty-vessel units: 0 = nothing on the scale, 1 = empty vessel
  function self.weight(v)
    if not (self.N and self.dE) or self.dE == 0 then return nil end
    return (v - self.N) / self.dE
  end

  -- a calibration point as an absolute reading (what the buttons show)
  function self.point(key)
    if key == 'none' then return self.N end
    local e = (self.N and self.dE) and (self.N + self.dE) or self.pE
    if key == 'empty' then return e end
    if e and self.dF then return e + self.dF end
    return self.pF
  end

  -- lifted = anything but a settled vessel (lifted, being placed, empty scale).
  -- Written to the toggle only when it changes, so a hand tap stays until the
  -- next real lift / put-down.
  -- The lift toggle shows the TARGET (lit = lifted) and carries no MIDI of its own;
  -- the script sends the lift CC as a ramp (LIFT_RISE_S up, LIFT_FALL_S down, 0 = jump).
  -- A change of the sensor state sets the target; a hand tap on the toggle sets it too
  -- and ramps the same way, until the sensor state changes again.
  function self.setLifted(lifted)
    if self.lifted == lifted then return end
    self.lifted = lifted
    self.liftGoal = lifted and 1 or 0
    local ctl = self.ui.lift
    if ctl and ctl.values.x ~= self.liftGoal then ctl.values.x = self.liftGoal end
    self.liftX = self.liftGoal
  end

  self.liftGoal, self.liftX = 0, 0                  -- start: on the scale

  function self.rampLift(dt)
    local ctl = self.ui.lift
    if not ctl then return end
    if ctl.values.x ~= self.liftX then             -- a hand tap
      self.liftX = ctl.values.x
      self.liftGoal = (self.liftX > 0.5) and 1 or 0
    end
    local cur, goal = self.liftOut or 0, self.liftGoal
    if cur == goal then return end
    local secs = (goal > cur) and LIFT_RISE_S or LIFT_FALL_S
    if secs <= 0 then cur = goal
    elseif goal > cur then cur = math.min(goal, cur + dt / secs)
    else cur = math.max(goal, cur - dt / secs) end
    self.liftOut = cur
    local v = math.floor(cur * 127 + 0.5)
    if v ~= self.liftSent then
      self.liftSent = v
      sendMIDI({ 0xB0 + MIDI_CHANNEL - 1, cfg.lift_cc, v }, MIDI_CONN)
    end
  end

  function self.setFill(f)
    f = math.clamp(f, 0, 1)
    if f < 0.02 then f = 0 elseif f > 0.98 then f = 1 end   -- three sips of 0.33 = 0
    if self.fill ~= f then
      self.fill = f
      saveAll()
    end
  end

  function self.setRounds(r) self.rounds = r end

  -- tea was poured into the vessel
  local function pour(now)
    self.setFill(1)
    self.pours = (self.pours or 0) + 1
    if self.rounds then self.rounds.fullHit(now) end
  end

  -- the rise that counts as a pour (fix 1: smaller on a spot that reads light)
  local function pourRise(tw) return POUR_FRACTION * tw * self.seat end

  -- a vessel has settled on the scale again
  local function arrive(w, now)
    local ep = self.ep
    self.ep = nil
    local tw = self.teaW()
    if ep and not ep.none then
      -- never left the scale (hand on it, lid lifted, slid, held while pouring):
      -- keep the old base, so a pour made meanwhile is still seen as a rise
      if tw and ep.base and (w - ep.base) >= pourRise(tw) then pour(now); self.base = w end
      self.stillW, self.stillT = nil, nil
      return
    end
    if ep then                                     -- came back after being away
      local away = (now - ep.t0) / 1000
      if cfg.pour_on_return and tw and ep.base and (w - ep.base) >= pourRise(tw) then
        pour(now)                                  -- came back heavier (refilled off the scale)
      elseif away >= MIN_LIFT_S then
        self.setFill((self.fill or 0) - self.sip)  -- a sip: the level only goes down
        self.sips = (self.sips or 0) + 1
      end
    end
    -- new spot: how heavy does it read? (expected weight here = 1 + fill × tea step)
    local expect = 1 + (self.fill or 0) * (tw or 0)
    self.seat = math.clamp(w / expect, POUR_SEAT_MIN, 1)
    self.seatW = w / expect
    self.base = w
    self.stillW, self.stillT = nil, nil
  end

  -- the state machine (see header); w is the current weight
  function self.step(w, now)
    local band = math.max(self.ui.snap.values.x * SNAP_MAX, STABLE_BAND)
    local s = self.state
    if not s then            -- first look (start, capture, clear, tare, manual release)
      self.state = (w <= band) and 'none' or 'present'
      self.ref, self.base = w, w
      self.ep, self.stillW, self.stillT = nil, nil, nil
      self.off = (self.state == 'none')
      if self.fill == nil then                     -- nothing remembered: a guess from the weight
        local tw = self.teaW()
        self.fill = (self.state == 'present' and tw and (w - 1) >= 0.5 * tw) and 1 or 0
        saveAll()
      end
    elseif s == 'none' then
      if w > band then       -- something arrives
        self.state, self.why = 'transit', 'placing'
        self.anchorW, self.anchorT = w, now
      end
    elseif s == 'present' then
      if w > self.ref then self.ref = w end        -- filling: follow upwards
      self.off = false
      if self.ref - w > LIFT_DROP then             -- got lighter = lifted
        self.state, self.why = 'transit', 'lifted'
        self.anchorW, self.anchorT = w, now
        self.ep = { t0 = now, base = self.base, none = false }
      end
    else                     -- transit: wait until the weight has been still
      if math.abs(w - self.anchorW) > STABLE_BAND then
        self.anchorW, self.anchorT = w, now
      elseif now - self.anchorT >= SETTLE_MS then
        local new = (w <= band) and 'none' or 'present'
        self.state, self.ref = new, w
        if new == 'none' then
          if self.ep then self.ep.none = true end
          self.off = true
        else
          arrive(w, now)
        end
      end
    end
    if w <= band then self.off = true end
    if self.off and self.ep then self.ep.none = true end
    -- lift CC (fix 1): only when the vessel really left the scale, not for a
    -- slide, a hand or a lid; it goes back to 0 once it has settled again
    self.setLifted(self.state ~= 'present' and self.off)
  end

  -- a vessel that stands: has tea been poured in? Looks at the weight each time
  -- it has been still for FULL_HOLD_S and compares it with the level before;
  -- the level follows slow drift (rises under DRIFT_FRACTION of the tea step).
  function self.watchPour(w, now)
    if self.state ~= 'present' then
      self.stillW, self.stillT = nil, nil
      return
    end
    if not self.stillW or math.abs(w - self.stillW) > STABLE_BAND then
      self.stillW, self.stillT = w, now
    elseif now - self.stillT >= FULL_HOLD_S * 1000 then
      local tw = self.teaW()
      if not tw then
        self.base = w          -- no tea step captured yet: nothing to detect, just follow
      elseif self.base and (w - self.base) >= pourRise(tw) then
        pour(now)
        self.base = w
      elseif not self.base or w < self.base or (w - self.base) < DRIFT_FRACTION * tw * self.seat then
        self.base = w          -- lower, or a small rise: drift follows. A bigger rise stays
      end                      -- on record so a pour in two goes (a pause between) still adds up
      self.stillT = now
    end
  end

  -- tare (fix 1): only while the scale is off (vessel away, state settled), within
  -- the tare band and still for TARE_HOLD_S. NO takes the reading; EMPTY and TEA
  -- are steps above it, so they move with it. The state machine is NOT restarted:
  -- a lift in progress stays a lift (the sip / pour-out is still counted on return),
  -- only the remembered weights are shifted by the same amount.
  function self.autoTare(w, now)
    if TARE_HOLD_S <= 0 or self.state ~= 'none' or math.abs(w) > self.tareBand then
      self.tareT = nil
      return false
    end
    if not self.tareT or math.abs(w - self.tareW) > STABLE_BAND then
      self.tareW, self.tareT = w, now
      return false
    end
    if now - self.tareT < TARE_HOLD_S * 1000 then return false end
    self.tareT = now
    if math.abs(w) < 0.002 then return false end
    self.N = self.N + w * self.dE
    for _, k in ipairs({ 'ref', 'base', 'anchorW', 'stillW', 'tareW' }) do
      if self[k] then self[k] = self[k] - w end
    end
    if self.ep and self.ep.base then self.ep.base = self.ep.base - w end
    self.tares = (self.tares or 0) + 1
    saveAll()
    return true
  end

  -- the output goal: EMPTY_V … FULL_V by the stored fill; down glides, up smooths
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

  -- captures work in any order (fix 2). A value captured before the point it is
  -- measured from waits (pE / pF, absolute) until that point exists.
  local function settle()
    if self.N and not self.dE and self.pE then self.dE = self.pE - self.N; self.pE = nil end
    if self.N and self.dE and not self.dF and self.pF then
      self.dF = self.pF - (self.N + self.dE); self.pF = nil
    end
  end

  function self.capture(point)
    if not self.target then return end
    local now, sum, n = getMillis(), 0, 0
    for _, h in ipairs(self.hist) do
      if h.t >= now - CAPTURE_MS then sum = sum + h.v; n = n + 1 end
    end
    local m = n > 0 and sum / n or self.target     -- quiet module: last value
    if point == 'none' then
      self.N = m                                   -- the steps stay: EMPTY and TEA move with it
    elseif point == 'empty' then
      local tea = self.point('tea') or self.pF     -- keep WITH TEA where it was
      if self.N then self.dE = m - self.N; self.pE = nil else self.dE, self.pE = nil, m end
      self.dF, self.pF = nil, tea
    elseif point == 'tea' then
      if self.N and self.dE then self.dF = m - (self.N + self.dE); self.pF = nil
      else self.dF, self.pF = nil, m end
    else
      return
    end
    settle()
    self.restart()
  end

  function self.clear()
    self.N, self.dE, self.dF, self.fill = nil, nil, nil, nil
    self.pE, self.pF = nil, nil
    self.restart()
  end

  -- fresh look: the next reading classifies the scale again and the output
  -- jumps straight to the stored fill (no glide)
  function self.restart()
    self.state, self.goal, self.fallRate, self.jump = nil, nil, nil, true
  end
  self.jump = true

  function self.serialize()
    local function f(v) return v and string.format('%.1f', v) or '' end
    return 'v5:' .. f(self.N) .. ',' .. f(self.dE) .. ',' .. f(self.dF) .. ',' ..
           (self.fill and string.format('%.3f', self.fill) or '')
  end

  function self.restore(s)
    local v5 = string.sub(s, 1, 3) == 'v5:'
    if v5 then s = string.sub(s, 4) end
    local vals, k = {}, 0
    for field in string.gmatch(s .. ',', '([^,]*),') do
      k = k + 1
      if k > 4 then break end
      vals[k] = tonumber(field)
    end
    if v5 then
      self.N, self.dE, self.dF = vals[1], vals[2], vals[3]
      if vals[4] then self.fill = math.clamp(vals[4], 0, 1) end
    else                                           -- v3 / v4 tag: absolute N, E, F
      self.N = vals[1]
      self.dE = (vals[1] and vals[2]) and (vals[2] - vals[1]) or nil
      self.dF = (vals[2] and vals[3]) and (vals[3] - vals[2]) or nil
    end
  end

  function self.setFillGoal()
    if not self.fill then return end
    local goal = EMPTY_V + (FULL_V - EMPTY_V) * self.fill
    if not self.goal or math.abs(goal - self.goal) > 0.0005 then
      if self.goal and goal < self.goal then self.fallRate = nil end   -- restart the linear fall
      self.goal = goal
    end
  end

  function self.tick(now, dt)
    self.rampLift(dt)               -- also with no sensor / no calibration: a hand tap ramps
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
    self.step(w, now)
    self.watchPour(w, now)
    self.setFillGoal()

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
      if self.seatW and self.state == 'present' then st = st .. string.format('  seat %.2f', self.seatW) end
      setText(u.status, string.format('raw %.0f   %s', self.raw, st))
    end

    if self.isHeld() or not self.target then
      setText(u.outval, self.midiText(true))
    elseif not self.N then
      setText(u.outval, 'capture NO')
    elseif not self.dE then
      setText(u.outval, 'capture EMPTY')
    elseif self.dE == 0 then
      setText(u.outval, 'NO = EMPTY ?')
    elseif self.dF and not self.teaW() then
      setText(u.outval, 'TEA ≤ EMPTY ? recapture')
    elseif not self.dF then
      setText(u.outval, self.midiText(false) .. '   need TEA')
    else
      local s = string.format('%s   fill %d%%', self.midiText(false), math.floor((self.fill or 0) * 100 + 0.5))
      if self.state ~= 'present' then s = s .. '   held'
      elseif self.goal and self.out and self.out > self.goal + 0.002 then s = s .. '   falling' end
      setText(u.outval, s)
    end

    local on = self.lifted
    setText(u.liftLbl, string.format('%s   CC %d = %d', on and 'LIFTED' or 'on the scale',
                                     cfg.lift_cc, on and 127 or 0))

    local pct = u.snap.values.x * SNAP_MAX
    setText(u.snapVal, string.format('±%.1f%%', pct * 100))
    setText(u.snapCnt, self.dE and string.format('≈%.0f', math.abs(self.dE) * pct) or '')
    local tau = u.smooth.values.x * SMOOTH_MAX
    setText(u.smoothVal, tau <= 0.001 and 'off' or string.format('%.2f s', tau))

    for _, point in ipairs(POINTS) do setText(u.pts[point], num(self.point(point))) end
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

  -- short note for the current count (ROUND_NOTE + count; count 0 = reset note)
  local function fireNote()
    local n = cfg.note + self.count
    if n > 127 then return end
    sendMIDI({ 0x90 + MIDI_CHANNEL - 1, n, 127 }, MIDI_CONN)
    self.lastNote = n
  end

  -- force: fire the note even if the count did not change (reset at 0)
  local function setCount(n, force)
    local before = self.count
    self.count = math.max(0, math.min(127, n))     -- it goes out as a MIDI CC value
    self.out = nil
    saveAll()
    if force or self.count ~= before then fireNote(); resetCups() end
  end

  -- called by the gaiwan every time tea is poured into it
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
      local s = string.format('%s filled → +1', cfg.source or 'vessel')
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

function resetCups()
  for _, m in ipairs(modules) do
    if m.cfg.reset_on_round and m.setFill then m.setFill(0) end
  end
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
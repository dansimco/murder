--- murder: multiple USB crows on norns
-- Replaces the Lua side of _norns.crow.add/remove/event (no matron changes).
--
--   crow                 -- unchanged: the crow in slot 1
--   local c2 = crow.connect(2)
--   c2.output[1].volts = 5
--   c2.input[1].stream = function(v) print(v) end
--   c2.add = function(id, name) ... end    -- connect callback
--   crow.devices()       -- { {slot=, id=, name=, chip=}, ... }
--
-- Slots are assigned by crow's unique chip id (^^i), remembered across boots.

local mods = require 'core/mods'

-- norns names a mod after its folder in dust/code; requires and the menu
-- must use that, but saved data always lives under data/murder.
local NAME = mods.this_name or 'murder'
if NAME ~= 'murder' then
  print("murder: installed as '" .. NAME .. "'; rename the folder to dust/code/murder")
end
local Slot = require(NAME .. '/lib/slot')

local MAX_SLOTS = 8
local IDENTIFY_TIMEOUT = 1.5
local STATE_DIR = _path.data .. 'murder/'
local STATE_FILE = STATE_DIR .. 'state.lua'

-- the handler is tagged so it can later be released without touching
-- anything the user has since put on input 1
local CLOCK_ENABLE = [[
    _murder_clk = function() tell('change',1,1) end
    input[1].change = _murder_clk
    input[1].mode('change',2,0.1,'rising')
  ]]

-- if input 1 still has our clock handler, swap it for a no-op so it stops
-- ticking the norns clock. mode is left alone; if the input was repurposed
-- (handler replaced) nothing changes. (crow's default change handler would
-- also send ^^change, hence the no-op rather than nil.)
local CLOCK_RELEASE =
  "if _murder_clk and input[1].change == _murder_clk then " ..
  "input[1].change = function() end end _murder_clk = nil"

local M = {
  devices = {},  -- matron id -> device record
  slots = {},    -- slot n -> device record
  handles = {},  -- slot n -> Slot internals
  state = { chips = {} },
}

--------------------------------------------------------------------------------
-- persistence

local function load_state()
  if util.file_exists(STATE_FILE) then
    local t = tab.load(STATE_FILE)
    if type(t) == 'table' then
      M.state.chips = type(t.chips) == 'table' and t.chips or {}
    end
  end
end

local function save_state()
  util.make_dir(STATE_DIR)
  tab.save(M.state, STATE_FILE)
end

--------------------------------------------------------------------------------
-- slots

local function send_slot(n, cmd)
  local d = M.slots[n]
  if d then _norns.crow_send(d.dev, cmd) end
end

local function slot(n)
  local s = M.handles[n]
  if not s then
    s = Slot.new(n,
      function(cmd) send_slot(n, cmd) end,
      function() return M.slots[n] ~= nil end,
      function(file) return norns.crow.findscript(file) end)
    M.handles[n] = s
  end
  return s
end

local function clock_source_is_crow()
  return params.lookup["clock_source"] ~= nil and params:string("clock_source") == "crow"
end

local function assign(d, n)
  d.slot = n
  M.slots[n] = d
  if d.chip and M.state.chips[d.chip] ~= n then
    M.state.chips[d.chip] = n
    save_state()
  end
  print("murder: crow " .. (d.chip or "?") .. " (id " .. d.id .. ") -> slot " .. n)

  if n == 1 then
    norns.crow.dev = d.dev
    norns.crow.add(d.id, d.name, d.dev)
  else
    slot(n).callback('add', d.id, d.name, d.dev)
  end

  -- slot 1 is always the clock crow
  if n == 1 and clock_source_is_crow() then
    norns.crow.clock_enable()
  end
end

local function unassign(d)
  local n = d.slot
  if not n then return end
  M.slots[n] = nil
  d.slot = nil
  if n == 1 then
    norns.crow.dev = nil
    norns.crow.remove(d.id)
  else
    slot(n).callback('remove', d.id)
  end
end

-- remembered slot if free, else lowest free slot not remembered by another
-- chip, else lowest free slot.
local function pick_slot(chip)
  local want = chip and M.state.chips[chip]
  if want and want <= MAX_SLOTS and not M.slots[want] then return want end
  local reserved = {}
  for c, s in pairs(M.state.chips) do
    if c ~= chip then reserved[s] = true end
  end
  for n = 1, MAX_SLOTS do
    if not M.slots[n] and not reserved[n] then return n end
  end
  for n = 1, MAX_SLOTS do
    if not M.slots[n] then return n end
  end
end

local function place(d)
  if d.slot then return end
  local n = pick_slot(d.chip)
  if n then assign(d, n)
  else print("murder: no free slot for crow id " .. d.id) end
end

--- move the crow in slot a to slot b, swapping with any occupant
function M.move(a, b)
  if a == b or b < 1 or b > MAX_SLOTS then return end
  local da, db = M.slots[a], M.slots[b]
  if not da then return end
  -- the crow leaving slot 1 stops being the clock
  if (a == 1 or b == 1) and M.slots[1] and clock_source_is_crow() then
    send_slot(1, CLOCK_RELEASE)
  end
  unassign(da)
  if db then unassign(db) end
  assign(da, b)
  if db then assign(db, a) end
end

--------------------------------------------------------------------------------
-- identification

local function identify(d)
  _norns.crow_send(d.dev, "^^i")
  d.pending_clock = clock.run(function()
    clock.sleep(IDENTIFY_TIMEOUT)
    d.pending_clock = nil
    if M.devices[d.id] == d and not d.slot then
      print("murder: crow id " .. d.id .. " did not identify, assigning by order")
      place(d)
    end
  end)
end

local function on_identity(d, chip)
  if d.chip or type(chip) ~= 'string' then return end
  d.chip = chip
  place(d)
end

local pending_events = setmetatable({ change = function() end }, {
  __index = function() return function() end end,
})

local function base_events(d)
  if d.slot == 1 then return norns.crow.events
  elseif d.slot then return slot(d.slot).events()
  else return pending_events end
end

local function make_env(d)
  local proxy = setmetatable({}, {
    __index = function(_, k)
      if k == 'identity' then
        return function(...)
          on_identity(d, ...)
          return base_events(d).identity(...)
        end
      end
      return base_events(d)[k]
    end,
  })
  return setmetatable({ __murder_ev = proxy }, { __index = _G })
end

--------------------------------------------------------------------------------
-- matron entry points

local function find_device(id)
  local d = M.devices[id]
  if d then return d end
  -- crow_event ids are uint8_t in matron; add/remove ids are not
  local short = (id - 1) % 256
  for did, dev in pairs(M.devices) do
    if (did - 1) % 256 == short then return dev end
  end
end

local function evalcrow(d, line)
  line = d.ebuffer .. line
  d.ebuffer = ""
  local code, reps = line:gsub("%^%^", "__murder_ev.")
  if reps > 0 then
    local f, err = load(code, "=crow", "t", d.env)
    if not f then print("murder: bad crow event: " .. err); return end
    local ok, e = pcall(f)
    if not ok then print("murder: crow event error: " .. tostring(e)) end
  elseif d.slot == 1 then
    norns.crow.receive(line)
  elseif d.slot then
    slot(d.slot).callback('receive', line)
  end
end

local function on_event(d, line)
  local n, m = line:find "%c+"
  if not n then
    d.ebuffer = d.ebuffer .. line
  else
    evalcrow(d, line:sub(1, n - 1))
    if m < #line then on_event(d, line:sub(m + 1, -1)) end
  end
end

_norns.crow.add = function(id, name, dev)
  local d = { id = id, name = name, dev = dev, ebuffer = "" }
  d.env = make_env(d)
  M.devices[id] = d
  identify(d)
end

_norns.crow.remove = function(id)
  local d = M.devices[id]
  if not d then return end
  if d.pending_clock then clock.cancel(d.pending_clock) end
  unassign(d)
  M.devices[id] = nil
end

_norns.crow.event = function(id, line)
  local d = find_device(id)
  if d then on_event(d, line) end
end

--------------------------------------------------------------------------------
-- core overrides

-- clock always lives on slot 1. tag the handler so a swap can release it.
norns.crow.clock_enable = function()
  send_slot(1, CLOCK_ENABLE)
end

-- script change: core resets slot 1; reset the rest and retry stragglers
local core_init = norns.crow.init
norns.crow.init = function()
  core_init()
  for n, s in pairs(M.handles) do s.clear() end
  for _, d in pairs(M.devices) do
    if not d.slot and not d.pending_clock then identify(d) end
  end
end

-- script.lua re-enables crow clock on the global crow with a registered event
-- (^^A, which the C clock ignores). re-send the real enable afterwards.
local core_add_params = clock.add_params
clock.add_params = function(...)
  core_add_params(...)
  clock.run(function()
    clock.sleep(0.1)
    if clock_source_is_crow() then norns.crow.clock_enable() end
  end)
end

--------------------------------------------------------------------------------
-- script api (rawset: crow's __newindex would send these to the device)

rawset(crow, 'connect', function(n)
  n = n or 1
  assert(type(n) == 'number' and n >= 1 and n <= MAX_SLOTS,
    "crow.connect: slot must be 1-" .. MAX_SLOTS)
  return slot(n).handle
end)

rawset(crow, 'devices', function()
  local t = {}
  for n = 1, MAX_SLOTS do
    local d = M.slots[n]
    if d then table.insert(t, { slot = n, id = d.id, name = d.name, chip = d.chip }) end
  end
  return t
end)

--------------------------------------------------------------------------------
-- mod menu

local menu = { pos = 1 }

local function chip_label(chip)
  if not chip then return "?" end
  return chip:len() > 12 and chip:sub(-12) or chip
end

menu.key = function(n, z)
  if n == 2 and z == 1 then mods.menu.exit() end
end

menu.enc = function(n, d)
  if n == 2 then
    menu.pos = util.clamp(menu.pos + d, 1, MAX_SLOTS)
  elseif n == 3 then
    local to = util.clamp(menu.pos + (d > 0 and 1 or -1), 1, MAX_SLOTS)
    if M.slots[menu.pos] then
      M.move(menu.pos, to)
      menu.pos = to
    end
  end
  mods.menu.redraw()
end

menu.redraw = function()
  screen.clear()
  local first = util.clamp(menu.pos - 3, 0, MAX_SLOTS - 6)
  for row = 1, 6 do
    local i = first + row
    local y = row * 10
    local d = M.slots[i]
    screen.level(i == menu.pos and 15 or 4)
    screen.move(0, y)
    screen.text(tostring(i))
    screen.move(12, y)
    screen.text(d and chip_label(d.chip) or "-")
    if i == 1 then
      screen.move(127, y)
      screen.text_right("clock")
    end
  end
  screen.update()
end

menu.init = function() end
menu.deinit = function() end

mods.menu.register(NAME, menu)

--------------------------------------------------------------------------------

load_state()

return M

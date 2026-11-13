-- desktop simulation: loads real norns lua/core/crow.lua with stubbed matron.
-- usage: NORNS=/path/to/norns lua test/sim.lua
local NORNS = assert(os.getenv("NORNS"), "set NORNS to a monome/norns checkout")
local HERE = arg[0]:match("(.*/)test/") or "./"
local TMP = os.tmpname(); os.remove(TMP); os.execute("mkdir -p " .. TMP .. "/code")
os.execute("ln -sfn \"$(cd " .. HERE .. " && pwd)\" " .. TMP .. "/code/murder")

package.path = NORNS .. "/lua/?.lua;" .. NORNS .. "/lua/lib/?.lua;" .. TMP .. "/code/?.lua;" .. package.path

-- stubs ----------------------------------------------------------------------
_path = { data = TMP .. "/data/", code = TMP .. "/code/" }
_norns = {
  execute = function(cmd) os.execute(cmd) end,
  crow_send = function(dev, s) table.insert(dev.sent, s) end,
}
norns = { state = { path = TMP .. "/script/" } }
tab = require 'tabutil'
util = require 'util'
screen = setmetatable({}, { __index = function() return function() end end })

local clock_source = "internal"
params = {
  lookup = { clock_source = 1 },
  string = function(_, k) return clock_source end,
}

local coros, next_id = {}, 1
clock = {
  run = function(f, ...)
    local id = next_id; next_id = next_id + 1
    local args = table.pack(...)
    coros[id] = coroutine.create(function() f(table.unpack(args, 1, args.n)) end)
    return id
  end,
  cancel = function(id) coros[id] = nil end,
  sleep = function() coroutine.yield() end,
  add_params = function() end,
}
local function tick(n)
  for _ = 1, n or 20 do
    for id, co in pairs(coros) do
      assert(coroutine.resume(co))
      if coroutine.status(co) == "dead" then coros[id] = nil end
    end
  end
end

package.loaded['core/mods'] = {
  this_name = 'murder',
  menu = { register = function() end, redraw = function() end, exit = function() end },
}

-- load core crow, then the mod ------------------------------------------------
crow = require 'core/crow'
local M = require 'murder/lib/mod'

-- helpers --------------------------------------------------------------------
local pass, fail = 0, 0
local function check(cond, msg)
  if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end
local function dev(label) return { label = label, sent = {} } end
local function last(d) return d.sent[#d.sent] end
local function has(d, pat)
  for _, s in ipairs(d.sent) do if s:find(pat, 1, true) then return true end end
end
local function plug(id, d, chip)
  _norns.crow.add(id, "crow: telephone line", d)
  check(last(d) == "^^i", "identity requested on add")
  if chip then _norns.crow.event(id, "^^identity('" .. chip .. "')\n\r") end
end

local added = {}
norns.crow.add = function(id, name, d) table.insert(added, d.label) end
local removed = 0
norns.crow.remove = function() removed = removed + 1 end

-- 1. two crows, slots by plug order on fresh state -----------------------------
local A, B = dev "A", dev "B"
plug(3, A, "0xAAAA")
plug(5, B, "0xBBBB")
check(M.slots[1] and M.slots[1].dev == A, "A in slot 1")
check(M.slots[2] and M.slots[2].dev == B, "B in slot 2")
check(norns.crow.dev == A, "norns.crow.dev is slot 1")
check(added[1] == "A" and #added == 1, "norns.crow.add only for slot 1")
check(has(B, "crow.reset()"), "slot 2 default add resets crow")

-- 2. sending ------------------------------------------------------------------
crow.output[1].volts = 3
check(last(A) == 'output[1]["volts"]=3', "global crow -> A: " .. tostring(last(A)))
local c2 = crow.connect(2)
c2.output[2].volts = 5
check(last(B) == 'output[2]["volts"]=5', "c2 -> B: " .. tostring(last(B)))
c2 "print('hi')"
check(last(B) == "print('hi')", "c2 call sends string")
c2.output[1]("pulse", 0.1)
check(last(B) == 'output[1]("pulse",0.1)', "c2 remote call: " .. tostring(last(B)))
check(c2.connected() == true and crow.connect(3).connected() == false, "connected()")

-- 3. events are per device ------------------------------------------------------
local got1, got2
crow.input[1].stream = function(v) got1 = v end
c2.input[1].stream = function(v) got2 = v end
local kA = last(A):match('_c.tell%("(%a)"')
local kB = last(B):match('_c.tell%("(%a)"')
check(kA and kB, "event keys registered")
_norns.crow.event(5, "^^" .. kB .. "(1.")      -- split across reads
_norns.crow.event(5, "5)\n")
check(got2 == 1.5 and got1 == nil, "B event -> c2 handler only")
_norns.crow.event(3, "^^" .. kA .. "(2)\n^^" .. kA .. "(4)\n")
check(got1 == 4, "A events -> global handler, multi-line")
local rx
c2.receive = function(s) rx = s end
_norns.crow.event(5, "hello\n")
check(rx == "hello", "c2.receive")

-- 4. uint8 event id wrap ---------------------------------------------------------
local C = dev "C"
plug(300, C, nil)
_norns.crow.event(44, "^^identity('0xCCCC')\n") -- (300-1)%256+1
check(M.slots[3] and M.slots[3].dev == C, "uint8 id event matched device")
_norns.crow.remove(300)
check(M.slots[3] == nil, "C removed")

-- 5. removal of slot 2 leaves slot 1 alone ------------------------------------
_norns.crow.remove(5)
check(M.slots[2] == nil and norns.crow.dev == A and removed == 0, "remove B keeps A")
_norns.crow.remove(3)
check(norns.crow.dev == nil and removed == 1, "remove A clears global")

-- 6. reversed plug order: remembered slots win ---------------------------------
local B2, A2 = dev "B2", dev "A2"
plug(10, B2, "0xBBBB")
check(M.slots[2] and M.slots[2].dev == B2, "B returns to slot 2 when plugged first")
check(M.slots[1] == nil, "slot 1 held for remembered A")
plug(11, A2, "0xAAAA")
check(M.slots[1] and M.slots[1].dev == A2 and norns.crow.dev == A2, "A returns to slot 1")

-- 7. unidentified crow falls back after timeout --------------------------------
local D = dev "D"
plug(12, D, nil)
check(M.devices[12].slot == nil, "pending before timeout")
tick()
check(M.devices[12].slot ~= nil, "assigned after timeout: " .. tostring(M.devices[12].slot))
_norns.crow.remove(12)

-- 8. clock always on slot 1 -------------------------------------------------
clock_source = "crow"
A2.sent, B2.sent = {}, {}
norns.crow.clock_enable()
check(has(A2, "tell('change',1,1)") and not has(B2, "tell('change'"), "clock enable goes to slot 1 only")
_norns.crow.remove(10)
local B3 = dev "B3"
plug(13, B3, "0xBBBB")
check(not has(B3, "tell('change'"), "slot 2 reconnect gets no clock")
A2.sent = {}
clock.add_params(); tick()
check(has(A2, "tell('change',1,1)") and not has(B3, "tell('change'"), "add_params re-enables on slot 1 only")

-- 9. move / swap ----------------------------------------------------------------
M.move(1, 2)
check(M.slots[1].dev == B3 and M.slots[2].dev == A2, "swap slots")
check(norns.crow.dev == B3, "global crow follows swap")
check(M.state.chips["0xBBBB"] == 1 and M.state.chips["0xAAAA"] == 2, "swap remembered")
check(has(A2, "input[1].change == _murder_clk"), "crow leaving slot 1 releases its clock handler")
check(not has(A2, "mode('none')"), "released crow input mode untouched")
check(has(B3, "tell('change',1,1)"), "crow entering slot 1 gets clock")
clock_source = "internal"

-- 10. persistence ---------------------------------------------------------------
local saved = tab.load(_path.data .. "murder/state.lua")
check(saved and saved.chips["0xBBBB"] == 1 and saved.clock_slot == nil, "state saved")

-- 11. script change resets secondary slots --------------------------------------
local fired
c2 = crow.connect(2)
c2.input[1].stream = function() fired = true end
local k2 = last(A2):match('_c.tell%("(%a)"')
A2.sent = {}
norns.crow.init()
check(has(A2, "crow.reset()"), "slot 2 crow reset on script change")
_norns.crow.event(11, "^^" .. k2 .. "(1)\n")
check(not fired, "slot 2 events cleared on script change")

-- 12. devices() -----------------------------------------------------------------
local list = crow.devices()
check(#list == 2 and list[1].chip == "0xBBBB" and list[2].slot == 2, "crow.devices()")

print(string.format("%d passed, %d failed", pass, fail))
os.execute("rm -rf " .. TMP)
os.exit(fail == 0 and 0 or 1)

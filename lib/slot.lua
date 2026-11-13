--- murder: per-slot crow namespace
-- A slot handle talks to whichever crow currently occupies slot n.
-- It mirrors the global `crow` table: indexing builds remote paths,
-- assigning sends values (functions become ^^ events), calling sends a string.
--
-- Slot 1 is the global `crow`: its handle routes through norns.crow.* so
-- scripts and system code (clock, public, loadscript) keep working unchanged.

local Q = require 'core/crow/quote'

local Slot = {}

local CALLBACKS = { add = true, remove = true, receive = true }

-- static ^^ events for slots 2+. slot 1 uses norns.crow.events.
local function new_events(n)
  return setmetatable({
    identity = function(...) print("crow " .. n .. " identity: " .. ...) end,
    version  = function(...) print("crow " .. n .. " version: " .. ...) end,
    -- crow.public is single-crow in core; ignore it on secondary crows
    ready    = function() end,
    pub      = function() end,
    pupdate  = function() end,
    pubview  = function() end,
    change   = function() end, -- clock event, handled in C
  }, {
    __index = function(_, ix)
      return function(...)
        print("crow " .. n .. " unused event: ^^" .. ix .. "(" .. Q(...) .. ")")
      end
    end,
  })
end

local function register_event(events, fn)
  local n = tab.count(events) + 1
  local c
  if     n <= 26 then c = utf8.char(n + 64) -- A-Z
  elseif n <= 52 then c = utf8.char(n + 70) -- a-z
  else
    print("ERROR: can't register crow event. only 52 handlers allowed.")
    return
  end
  events[c] = fn
  return c
end

--- build a handle
-- @param n slot number
-- @param send function(cmd) delivering a string to the slot's crow (or dropping it)
-- @param connected function() -> bool
-- @param findscript function(file) -> abspath or nil
function Slot.new(n, send, connected, findscript)
  local self = { n = n } -- private state
  local api = {}         -- methods visible on the handle

  if n == 1 then
    self.register_event = function(fn) return norns.crow.register_event(fn) end
    self.reset_events = function() norns.crow.reset_events() end
    self.events = function() return norns.crow.events end
    self.get_cb = function(k) return norns.crow[k] end
    self.set_cb = function(k, v) norns.crow[k] = v end
  else
    local events, cbs
    self.reset_events = function() events = new_events(n) end
    self.register_event = function(fn) return register_event(events, fn) end
    self.events = function() return events end
    self.get_cb = function(k) return cbs[k] end
    self.set_cb = function(k, v) cbs[k] = v end
    self.reset_callbacks = function()
      cbs = {
        add = function(name) send "crow.reset()" end, -- same default as core
        remove = function() end,
        receive = function(...) print("crow " .. n .. ":", ...) end,
      }
    end
    self.reset_events()
    self.reset_callbacks()
  end

  -- fns with custom syntax (same as global crow)
  function api.version()  send "^^v" end
  function api.identity() send "^^i" end
  function api.reset()    send "crow.reset()" end
  function api.kill()     send "^^k" end
  function api.clear()    send "^^c" end
  function api.send(...)  send(...) end
  function api.connected() return connected() end
  function api.slot() return n end

  function api.loadscript(file, is_persistent, cont)
    local abspath = findscript(file)
    if not abspath then
      print("crow " .. n .. " loadscript: can't find file " .. file)
      return
    end
    print("crow " .. n .. " loading: " .. file)
    return clock.run(function()
      send "^^s"
      clock.sleep(0.2)
      for line in io.lines(abspath) do
        send(line)
        clock.sleep(0.01)
      end
      clock.sleep(0.2)
      send(is_persistent and "^^w" or "^^e")
      if cont then
        clock.sleep(is_persistent and 0.5 or 0.2)
        cont()
      end
    end)
  end

  -- remote path builder, e.g. h.output[1].volts = 3
  local sub = {
    __index = function(t, ix)
      t.str = t.str .. Q.key(ix)
      return t
    end,
    __newindex = function(t, ix, val)
      local sval
      if type(val) == 'function' then
        local key = self.register_event(val)
        if not key then return end
        sval = 'function(...)_c.tell(' .. Q(key) .. ',quote(...))end'
      else
        sval = Q(val)
      end
      send(t.str .. Q.key(ix) .. '=' .. sval)
    end,
    __call = function(t, ...)
      local nargs = select("#", ...)
      send(t.str .. '(' .. (nargs > 0 and Q(...) or '') .. ')')
    end,
  }

  local handle = setmetatable({}, {
    __index = function(_, ix)
      if CALLBACKS[ix] then return self.get_cb(ix) end
      local f = api[ix]
      if f then return f end
      return setmetatable({ str = ix }, sub)
    end,
    __newindex = function(_, ix, val)
      if CALLBACKS[ix] then self.set_cb(ix, val)
      else send(ix .. '=' .. Q(val)) end
    end,
    __call = function(_, ...) send(...) end,
    __tostring = function() return "crow slot " .. n end,
  })

  -- internal hooks for the registry (not visible through the handle)
  self.handle = handle
  self.callback = function(k, ...)
    local f = self.get_cb(k)
    if f then
      local ok, err = pcall(f, ...)
      if not ok then print("crow " .. n .. " " .. k .. " error: " .. tostring(err)) end
    end
  end
  self.clear = function()
    -- called on script change for slots 2+ (slot 1 is reset by norns.crow.init)
    if n ~= 1 then
      self.reset_events()
      self.reset_callbacks()
      if connected() then api.reset() end
    end
  end

  return self
end

return Slot

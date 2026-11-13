# murder

<img width="2000" height="1500" alt="IMG_9628" src="https://github.com/user-attachments/assets/9cd183a0-f3a8-45f5-bff9-566bec80c896" />

A norns mod that lets you use several USB crows at once. It only changes Lua, so
matron and the C code stay as they are. It was written against monome/norns @ 227aa04.

Matron already creates one device per crow. This mod patches
`_norns.crow.add/remove/event` with versions that track every crow, each with its
own line buffer and its own event table.

Currently the first crow that is found is the one which can be clock input. Will add more control later. 


## script api

```lua
-- the global `crow` works as before and controls the crow in slot 1
crow.output[1].volts = 3

-- other crows: like midi.connect(n), a handle bound to slot n
local c2 = crow.connect(2)
c2.output[1].volts = 5
c2.output[2].action = "pulse(0.01, 8)"
c2.input[1].stream = function(v) print("crow 2 in1", v) end
c2.input[1].mode("stream", 0.1)
c2 "print('hi')"                 -- send a raw string
c2.reset(); c2.clear(); c2.kill(); c2.version(); c2.identity()
c2.connected()                   -- true if a crow is in slot 2
c2.loadscript("foo.lua", false)  -- same lookup as norns.crow.loadscript

-- callbacks for each slot (reset when the script changes)
c2.add     = function(id, name, dev) end  -- default: crow.reset()
c2.remove  = function(id) end
c2.receive = function(line) end           -- non-^^ output

crow.devices()  --> { {slot=1, id=, name=, chip="0x..."}, ... }
```

`crow.connect(1)` returns a handle for the same crow as the global `crow`. Its
`add`, `remove` and `receive` get and set `norns.crow.add`, `norns.crow.remove`
and `norns.crow.receive`.

## slots

- When a crow is added, the mod sends it `^^i` and reads back its unique chip id.
  It then gives the crow a slot by that id, so plugging crows in a different
  order doesn't change their slots. The ttyACM order depends on plug order, so
  it can't be used for this.
- Each chip id's slot is saved to `~/dust/data/murder/state.lua`. A crow that has
  been seen before gets its saved slot back. A new crow gets the lowest free slot
  that isn't saved for another crow.
- If a crow doesn't answer `^^i` within 1.5 s, it gets the next free slot in plug
  order.
- The mod menu (SYSTEM > MODS > MURDER) lists the slots, with slot 1 marked
  `clock`. E2 selects a slot, and E3 moves the crow in it up or down, swapping
  with any crow already there.

## clock

The crow in slot 1 is always the clock crow, for both clock in and clock out. To
use a different crow for clock, move it into slot 1 in the mod menu.

matron runs `clock_crow_handle_clock()` when any crow sends `^^change(1,1)`, so
the mod makes sure only slot 1 has clock enabled. With the clock source set to
crow:

- The enable is sent to slot 1 whenever a crow takes that slot, and again after
  every script change. At 227aa04, `script.lua` turns clock back on with a
  registered event (`^^H`), which the C clock ignores, so on its own it doesn't
  work.
- When a swap moves a crow out of slot 1, the mod checks that crow's input 1. If
  the mod's clock handler is still there, it's replaced with a no-op. The
  input's mode stays as it is, and a handler you set yourself is left alone.

## limitations

- **crow.public** works only on slot 1, because `core/crow/public.lua` is shared
  by all crows. `^^pub` and related events from other slots are ignored.
- The ids in matron's `crow_event` are `uint8_t`, while the add/remove ids are
  not. The mod matches event ids modulo 256, so this only matters if two
  connected crows have ids exactly 256 apart.
- A crow that runs `input[n].mode('change')` with its *default* handler also
  sends `^^change(1,1)` and will drive the norns clock. Setting the handler from
  norns (`c2.input[1].change = fn`) is safe.

## testing

```sh
NORNS=/path/to/norns lua test/sim.lua
```

This loads the real `lua/core/crow.lua` with matron and the clock stubbed out. It
covers slot assignment, routing in both directions, split and multi-line events,
uint8 id wrap, remove and replug, the identify timeout, clock on slot 1, slot
swaps (including the clock handover), persistence and script-change resets.

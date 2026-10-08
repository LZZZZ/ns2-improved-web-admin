-- Off-rig harness for the map-cycle request types in lua/ServerWebInterface.lua,
-- and for getinstalledmodslist's `active` flag.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed,
-- over a directory standing in for config://, with core/MapCycle.lua's two
-- functions reduced to what they do: keep a table, and save it with dkjson.
-- It checks the logic -- read the file, never mutate the live cycle, refuse
-- before writing, keep unknown keys, report Shine's mapvote -- not the engine;
-- the engine side was measured on the rig (docs/CONSTRAINTS.md items 12-13).
--
-- Usage: luajit tools/spikes/maps-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"
local DISK = os.tmpname()
os.remove(DISK)
os.execute("mkdir -p '" .. DISK .. "'")

local realOpen = io.open
local dkjson = dofile(CORE .. "dkjson.lua")
local FILE = DISK .. "/MapCycle.json"

local function write(text) local f = realOpen(FILE, "w"); f:write(text); f:close() end
local function read() local f = realOpen(FILE, "r"); if not f then return nil end
                      local t = f:read("*a"); f:close(); return t end

local function NewVM(memory, shine)
    local hooks = { }
    local logged = { }
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function(path, mode)
        local rel = path:match("^config://(.*)$")
        if not rel then return nil, "not allowed" end
        return realOpen(DISK .. "/" .. rel, mode)
    end }
    env.json = dkjson
    env.Shine = shine
    env.Script = { Load = function() end }
    env.CreateRingBuffer = function() return { Insert = function() end,
        GetNumElements = function() return 0 end, ToTable = function() return { } end } end
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = { Message = function() end, SetWebRoot = function() end,
                   GetSystemTime = function() return 0 end, GetTime = function() return 0 end }
    env.Log = function(fmt, ...) table.insert(logged, string.format(fmt, ...)) end
    -- The 09-25 engine's tonumber64: a number for a workshop-sized id, nil for junk.
    env.tonumber64 = function(s) return tonumber(s) end
    env.MapCycle_GetMapCycle = function() return memory.cycle end
    -- Installed and active mods, as the engine spells them: hex strings.
    local mods = memory.mods or { installed = { }, active = { } }
    env.Server = {
        GetNumMods = function() return #mods.installed end,
        GetModId = function(i) return mods.installed[i][1] end,
        GetModTitle = function(i) return mods.installed[i][2] end,
        GetNumActiveMods = function() return #mods.active end,
        GetActiveModId = function(i) return mods.active[i] end,
    }
    env.MapCycle_SetMapCycle = function(c)
        memory.cycle = c
        write(dkjson.encode(c, { indent = true }))
    end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    local vm = { logged = logged }
    function vm.request(params)
        local ctype, body = hooks.WebRequest[1](params)
        return ctype, body and dkjson.decode(body)
    end
    return vm
end

local failures = 0
local function check(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

local LIVE = [[{"time":40,"mode":"order","mods":[208649136,117887554],
  "groups":[{"name":"g","maps":["ns2_veil"]}],
  "maps":["ns2_veil",{"map":"ns2_jambi","mods":[129599221],"min":12},{"map":"ns2_x","mods":[]}]}]]

-- 1. getmapcycle reads the file and leaves memory alone
write(LIVE)
local memory = { cycle = dkjson.decode(LIVE) }
local vm = NewVM(memory)
local _, c = vm.request({ request = "getmapcycle" })
check(c.mods[1] == "c6fbbb0" and c.maps[2].mods[1] == "7b986f5", "getmapcycle hex-encodes global and per-map ids")
check(type(memory.cycle.mods[1]) == "number" and type(memory.cycle.maps[2].mods[1]) == "number",
      "the live cycle keeps numbers after a read (item 12)")
check(c.groups[1].name == "g" and c.maps[2].min == 12, "unknown keys reach the client")

write(LIVE:gsub('"time":40', '"time":41'))
_, c = vm.request({ request = "getmapcycle" })
check(c.time == 41, "a hand edit of the file shows at once (item 13)")

os.remove(FILE)
_, c = vm.request({ request = "getmapcycle" })
check(c.time == 40 and c.mods[1] == "c6fbbb0", "no file: falls back to memory")
check(type(memory.cycle.mods[1]) == "number", "the fallback does not mutate memory either")

write("{ not json")
_, c = vm.request({ request = "getmapcycle" })
check(c.time == 40, "an unparseable file: falls back to memory")

-- 2. setmapcycle refuses before writing
write(LIVE)
local function refused(data, what)
    local before = read()
    local ctype, r = vm.request({ request = "setmapcycle", data = data })
    check(ctype == "application/json" and r.ok == false and type(r.error) == "string"
          and read() == before, what .. " -> refused, nothing written (" .. tostring(r and r.error) .. ")")
end
refused("{ nope", "bad JSON")
refused(nil, "no data")
refused('"ns2_veil"', "not an object")
refused('{"time":30}', "no maps")
refused('{"maps":[]}', "empty maps")
refused('{"maps":["ns2_veil",""]}', "empty map name")
refused('{"maps":[{"mods":["7b986f5"]}]}', "entry without a map")
refused('{"maps":["ns2_veil"],"mods":["zzzz"]}', "junk global mod id")
refused('{"maps":[{"map":"ns2_veil","mods":["12 34"]}]}', "junk per-map mod id")
refused('{"maps":["ns2_veil"],"time":-1}', "negative time")
refused('{"maps":["ns2_veil"],"time":"30"}', "time as a string")
refused('{"maps":["ns2_veil"],"mode":"shuffle"}', "unknown mode")
check(#vm.logged >= 1 and vm.logged[1]:find("^setmapcycle refused"), "refusals are logged")

-- 3. setmapcycle writes, keeps what it does not understand, and reads back
local send = [[{"time":30.5,"mode":"random","mods":["c6fbbb0","workshop:1"],
  "groups":[{"name":"g","maps":["ns2_veil"]}],
  "maps":[{"map":"ns2_veil","min":12,"mods":[]},"ns2_summit",{"map":"ns2_jambi","mods":["7b986f5"]}]}]]
local ctype, r = vm.request({ request = "setmapcycle", data = send })
check(ctype == "application/json" and r.ok == true, "a good cycle is accepted")
local disk = dkjson.decode(read())
check(disk.mods[1] == 208649136 and disk.mods[2] == "workshop:1" and disk.maps[3].mods[1] == 129599221,
      "the file holds numbers, and the `:` escape passes through")
check(disk.groups[1].name == "g" and disk.maps[1].min == 12 and disk.time == 30.5 and disk.mode == "random",
      "unknown keys, a float time and the mode are written")
check(read():find('"mods":%[%]') ~= nil or read():find('"mods": ?%[%]') ~= nil,
      "an empty mods list stays a list on disk")
check(r.cycle.mods[1] == "c6fbbb0" and r.cycle.maps[3].mods[1] == "7b986f5" and r.cycle.maps[1].min == 12,
      "the reply is the file read back, hex-encoded")
check(memory.cycle.maps[2] == "ns2_summit", "the game's cycle was replaced")

-- 4. getmapvote
local _, v = vm.request({ request = "getmapvote" })
check(v.enabled == false and v.next_map == nil, "no Shine: mapvote disabled")

local plugin = {
    Config = { GetMapsFromMapCycle = true, RoundLimit = 2 },
    RoundLimit = 3,
    MapChoices = { "ns2_veil", { map = "ns2_jambi", mods = { 1 } } },
    GetNextMap = function(self) return "ns2_jambi" end,
}
local shine = { IsExtensionEnabled = function(_, name)
    if name == "mapvote" then return true, plugin end
    return false
end }
vm = NewVM(memory, shine)
_, v = vm.request({ request = "getmapvote" })
check(v.enabled and v.maps_from_cycle and v.round_limit == 3 and v.next_map == "ns2_jambi",
      "Shine: from the cycle, the plugin's own round limit, the next map")
check(#v.options == 2 and v.options[2] == "ns2_jambi", "Shine: the vote's current options, by name")

plugin.GetNextMap = function() error("boom") end
_, v = vm.request({ request = "getmapvote" })
check(v.enabled and v.next_map == nil, "a failing GetNextMap is reported as no next map")

-- 5. getinstalledmodslist marks what is mounted now (REQUIREMENTS item 3)
memory.mods = {
    installed = { { "aa473d86", "NS2Panel" }, { "bbe5db27", "Mouse Wheel Jump" },
                  { "d41d68cd", "UWE Hotfix 344" }, { "54dc69f2", "1423731186" } },
    -- The hotfix is mounted with no cycle entry; 7b986f5 is active but not in
    -- the installed list here, which must not invent a row.
    active = { "d41d68cd", "aa473d86", "7b986f5" },
}
vm = NewVM(memory)
local _, installed = vm.request({ request = "getinstalledmodslist" })
check(#installed == 4, "one row per installed mod, none invented for an active id")
check(installed[1].active == true and installed[2].active == false
      and installed[3].active == true and installed[4].active == false,
      "active marks exactly the mounted ones")
check(installed[1].id == "aa473d86" and installed[1].name == "NS2Panel",
      "id and name as before")

os.execute("rm -rf '" .. DISK .. "'")
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

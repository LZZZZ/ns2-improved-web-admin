-- Off-rig harness for chat in lua/ServerWebInterface.lua: the game's
-- Server.lua keeps 20 messages without a time; the mod grows that ring to
-- 200 on its first tick or request and stamps each new message's time.
-- getchatlist replies from that ring.
--
-- Usage: luajit tools/spikes/chat-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua and RingBuffer.lua come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local MOD = REPO .. "lua/ServerWebInterface.lua"
local dkjson = dofile(opts.core .. "dkjson.lua")

local clock = { now = 1790000000 }

local function NewVM()
    local hooks = { }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "no files in this harness" end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = {
        Message = function() end, SetWebRoot = function() end,
        GetSystemTime = function() return clock.now end,
        GetTime = function() return 0 end,
        GetEntitiesWithClassname = function() return players end,
        GetSystemTimeReal = function() return clock.now end,
        GetServerPerformanceData = function() return {
            GetTimestamp = function() return 0 end,
            GetDurationMs = function() return 0 end,
        } end,
    }
    env.ientitylist = function(list) return ipairs(list) end
    env.Server = { GetFrameRate = function() return 60 end }
    env.table = setmetatable({ array = function() return { } end }, { __index = table })
    local ring = assert(loadfile(opts.core .. "RingBuffer.lua"))
    setfenv(ring, env)
    ring()
    local chunk = assert(loadfile(MOD))
    dofile(HERE .. "engine-stubs.lua")(env, dkjson)
    setfenv(chunk, env)
    chunk()

    -- What Server.lua sets up after loading the mod's file: 20, no time.
    env.Server.recentChatMessages = env.CreateRingBuffer(20)
    local count = 0
    function env.Server.AddChatToHistory(message, playerName, steamId, teamNumber, teamOnly)
        count = count + 1
        env.Server.recentChatMessages:Insert({ id = count, message = message, player = playerName,
            steamId = steamId, team = teamNumber, teamOnly = teamOnly })
    end

    local vm = { env = env }
    function vm.say(...) env.Server.AddChatToHistory(...) end
    function vm.tick() for _, fn in ipairs(hooks.UpdateServer) do fn(0.016) end end
    function vm.request(params)
        local _, body = hooks.WebRequest[1](params, { path = "/", method = "GET", headers = { } })
        return dkjson.decode(body), body
    end
    function vm.chat(since) return (vm.request({ request = "getchatlist", since = tostring(since) })) end
    return vm
end

local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end

local vm = NewVM()
vm.say("before the first tick", "Alice", 101, 1, false)
local r = vm.chat(0)
check(r.buffer_size == 200, "a request grows the game's ring to 200")
check(#r.entries == 1 and r.entries[1].time == nil, "and keeps what it held, without a time")

vm = NewVM()
vm.tick()
r = vm.chat(0)
check(#r.entries == 0 and r.last_id == 0 and r.dropped == 0 and r.buffer_size == 200,
      "after a tick: nothing yet, last_id 0, ring of 200")

vm.say("gl hf", "Alice", 101, 1, false)
clock.now = clock.now + 5
vm.say("rush", "Alice", 101, 1, true)
r = vm.chat(0)
check(#r.entries == 2 and r.last_id == 2 and r.dropped == 0, "since=0 returns both, last_id 2")
check(r.entries[2].message == "rush" and r.entries[2].time == clock.now and r.entries[1].time == clock.now - 5,
      "with the game's fields and the time each was said")
check(#vm.chat(1).entries == 1, "since=1 returns only what is newer")
local _, body = vm.request({ request = "getchatlist", since = "2" })
check(body:find('"entries":%[%]') ~= nil, "since=last_id encodes no entries as []")

r = vm.request({ request = "getchatlist" })
check(#r == 2 and r[1].message == "gl hf" and r.entries == nil, "no since: the stock bare array")
check(#vm.request({ request = "getchatlist", since = "junk" }) == 2, "and so for a since that is not a number")

for i = 1, 250 do vm.say("spam " .. i, "Carol", 104, 2, false) end
r = vm.chat(0)
check(#r.entries == 200 and r.entries[1].id == 53 and r.last_id == 252, "the ring keeps the last 200: 53..252")
check(r.dropped == 52, "and the 52 that fell out are counted")
local stamped = true
for _, e in ipairs(r.entries) do stamped = stamped and e.time == clock.now end
check(stamped, "every message once the ring is full has a time")
r = vm.request({ request = "getchatlist" })
check(#r == 20 and r[1].id == 233 and r[20].id == 252, "no since: the last 20, as the stock ring held")

-- Shine replaces AddChatToHistory without chaining: the next tick stamps again.
local replaced = 0
vm.env.Server.AddChatToHistory = function(message, playerName, steamId, teamNumber, teamOnly)
    replaced = replaced + 1
    vm.env.Server.recentChatMessages:Insert({ id = 1000 + replaced, message = message, player = playerName,
        steamId = steamId, team = teamNumber, teamOnly = teamOnly })
end
vm.tick()
vm.say("after shine", "Bob", 102, 1, false)
r = vm.chat(252)
check(#r.entries == 1 and r.entries[1].id == 1001 and r.entries[1].time == clock.now, "a replaced AddChatToHistory is stamped after the next tick")

-- Something wrapping ours keeps one entry per message, one time.
local inner = vm.env.Server.AddChatToHistory
vm.env.Server.AddChatToHistory = function(...) return inner(...) end
vm.tick()
vm.say("double wrapped", "Bob", 102, 1, false)
r = vm.chat(1001)
check(#r.entries == 1 and r.entries[1].time == clock.now, "wrapped twice: still one entry with a time")

-- A map change is a fresh VM: ids start over, below the old cursor.
vm = NewVM()
vm.tick()
vm.say("new map", "Alice", 101, 0, false)
r = vm.chat(252)
check(r.last_id == 1 and #r.entries == 0, "after a map change last_id is 1")

print("all passed")

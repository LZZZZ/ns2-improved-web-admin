-- Off-rig harness for getchatlist in lua/ServerWebInterface.lua: the reply it
-- makes of Server.recentChatMessages, which the game's Server.lua keeps (200
-- messages, each with an id and a time, in the PR to ns2-game).
--
-- Usage: luajit tools/spikes/chat-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua comes from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local MOD = REPO .. "lua/ServerWebInterface.lua"
local dkjson = dofile(opts.core .. "dkjson.lua")

local function RingBuffer(n)
    local items = { }
    return {
        size = n,
        Insert = function(self, x) table.insert(items, x); if #items > n then table.remove(items, 1) end end,
        GetNumElements = function() return #items end,
        ToTable = function() return items end,
    }
end

local clock = { now = 1790000000 }

local function NewVM()
    local hooks = { }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "no files in this harness" end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.CreateRingBuffer = RingBuffer
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
    local chunk = assert(loadfile(MOD))
    dofile(HERE .. "engine-stubs.lua")(env, dkjson)
    setfenv(chunk, env)
    chunk()

    -- Server.lua's AddChatToHistory, as the PR leaves it.
    env.Server.recentChatMessages = RingBuffer(200)
    local count = 0
    local vm = { env = env }
    function vm.say(message, playerName, steamId, teamNumber, teamOnly)
        count = count + 1
        env.Server.recentChatMessages:Insert({ id = count, time = clock.now, message = message,
            player = playerName, steamId = steamId, team = teamNumber, teamOnly = teamOnly })
    end
    function vm.request(params)
        local _, body = hooks.WebRequest[1](params)
        return dkjson.decode(body), body
    end
    function vm.chat(since) return (vm.request({ request = "getchatlist", since = tostring(since) })) end
    return vm
end

local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end

local vm = NewVM()
local r = vm.chat(0)
check(#r.entries == 0 and r.last_id == 0 and r.dropped == 0 and r.buffer_size == 200,
      "no chat yet: nothing, last_id 0, ring of 200")

vm.say("gl hf", "Alice", 101, 1, false)
clock.now = clock.now + 5
vm.say("rush", "Alice", 101, 1, true)
r = vm.chat(0)
check(#r.entries == 2 and r.last_id == 2 and r.dropped == 0, "since=0 returns both, last_id 2")
check(r.entries[2].message == "rush" and r.entries[2].time == clock.now, "with the game's fields and time")
check(#vm.chat(1).entries == 1, "since=1 returns only what is newer")
local _, body = vm.request({ request = "getchatlist", since = "2" })
check(body:find('"entries":%[%]') ~= nil, "since=last_id encodes no entries as []")

check(#vm.request({ request = "getchatlist" }).entries == 2, "no since reads from 0")
check(#vm.request({ request = "getchatlist", since = "junk" }).entries == 2, "nor does a since that is not a number")

for i = 1, 250 do vm.say("spam " .. i, "Carol", 104, 2, false) end
r = vm.chat(0)
check(#r.entries == 200 and r.entries[1].id == 53 and r.last_id == 252, "the ring keeps the last 200: 53..252")
check(r.dropped == 52, "and the 52 that fell out are counted")

-- A map change is a fresh VM: ids start over, below the old cursor.
vm = NewVM()
vm.say("new map", "Alice", 101, 0, false)
r = vm.chat(252)
check(r.last_id == 1 and #r.entries == 0, "after a map change last_id is 1")

print("all passed")

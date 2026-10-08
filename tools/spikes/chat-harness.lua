-- Off-rig harness for the chat ring in lua/ServerWebInterface.lua.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed.
-- Server.AddChatToHistory is defined only after the file has loaded, as
-- Server.lua does (the file is loaded at :35, the function defined at :82), so
-- the wrap has to be the late one. It checks the logic -- the wrap, the
-- cursor, the ring, a wrapper chain, a fresh VM -- not the engine: what calls
-- AddChatToHistory on a real server is a rig question.
--
-- Usage: luajit tools/spikes/chat-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"
local dkjson = dofile(CORE .. "dkjson.lua")

local function RingBuffer(n)
    local items = { }
    return {
        Insert = function(self, x) table.insert(items, x); if #items > n then table.remove(items, 1) end end,
        GetNumElements = function() return #items end,
        ToTable = function() return items end,
    }
end

local function NewVM(clock)
    local hooks = { }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    -- Nothing here touches files: every open fails, as an unreadable log does.
    env.io = { open = function() return nil, "no files in this harness" end }
    env.json = dkjson
    env.kDefaultPlayerName = "NSPlayer"
    env.Script = { Load = function() end }
    env.CreateRingBuffer = RingBuffer
    env.GetBannedPlayersList = function() return { } end
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
    env.Server = {
        GetFrameRate = function() return 60 end,
        GetOwner = function(p) return p.client end,
        GetClientAddress = function(c) return c.addr end,
    }
    env.IPAddressToString = function(a) return a end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    -- Server.lua:74-88, after the file has loaded.
    local vanillaCalls = 0
    env.Server.recentChatMessages = RingBuffer(20)
    local count = 0
    env.Server.AddChatToHistory = function(message, playerName, steamId, teamNumber, teamOnly)
        if message == "explode" then error("refused") end
        vanillaCalls = vanillaCalls + 1
        count = count + 1
        env.Server.recentChatMessages:Insert({ id = count, message = message, player = playerName,
                                               steamId = steamId, team = teamNumber, teamOnly = teamOnly })
    end

    local vm = { env = env }
    function vm.fire(name, ...) for _, fn in ipairs(hooks[name] or { }) do fn(...) end end
    function vm.tick() vm.fire("UpdateServer") end
    function vm.say(...) return env.Server.AddChatToHistory(...) end
    function vm.vanillaCalls() return vanillaCalls end
    function vm.request(params)
        local ctype, body = hooks.WebRequest[1](params)
        return ctype, dkjson.decode(body), body
    end
    function vm.chat(since)
        local _, reply = vm.request({ request = "getchatlist", since = since and tostring(since) })
        return reply
    end
    return vm
end

local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end
local function messages(entries)
    local t = { }
    for _, e in ipairs(entries) do table.insert(t, e.message) end
    return table.concat(t, ",")
end

local clock = { now = 1790000000 }
local vm = NewVM(clock)

local original = vm.env.Server.AddChatToHistory
check(vm.env.Server.AddChatToHistory == original, "not wrapped before the first tick: it did not exist at load")
vm.tick()
check(vm.env.Server.AddChatToHistory ~= original, "wrapped on the first tick")
local wrapped = vm.env.Server.AddChatToHistory
vm.tick(); vm.tick()
check(vm.env.Server.AddChatToHistory == wrapped, "and not again on later ticks")

vm.say("gl hf", "Alice", 101, 1, false)
clock.now = clock.now + 5
vm.say("rush", "Alice", 101, 1, true)
check(vm.vanillaCalls() == 2, "the game's own function still runs, once per message")

local r = vm.chat(0)
check(#r.entries == 2 and r.last_id == 2, "since=0 returns both, last_id 2")
check(r.dropped == 0 and r.buffer_size == 200, "nothing dropped, ring of 200")
local e = r.entries[2]
check(e.id == 2 and e.message == "rush" and e.player == "Alice" and e.steamId == 101
      and e.team == 1 and e.teamOnly == true and e.time == clock.now,
      "an entry carries id, time and the game's five fields")
check(r.entries[1].teamOnly == false, "teamOnly is a real false, not absent")
r = vm.chat(1)
check(#r.entries == 1 and r.entries[1].message == "rush", "since=1 returns only what is newer")
r = vm.chat(2)
check(#r.entries == 0 and r.last_id == 2, "since=last_id returns nothing")
local _, _, body = vm.request({ request = "getchatlist", since = "2" })
check(body:find('"entries":%[%]') ~= nil, "and encodes no entries as [], not {}")

local _, legacy = vm.request({ request = "getchatlist" })
check(#legacy == 2 and legacy[1].message == "gl hf" and legacy[1].time == nil,
      "without since: the game's list, in its own shape")
_, legacy = vm.request({ request = "getchatlist", since = "junk" })
check(#legacy == 2, "a since that is not a number is no cursor: the game's list")

-- The web request path wraps too, for chat sent before the first tick.
local vm2 = NewVM(clock)
local original2 = vm2.env.Server.AddChatToHistory
vm2.request({ request = "getchatlist", since = "0" })
check(vm2.env.Server.AddChatToHistory ~= original2, "a web request wraps as well")
vm2.say("early", "Admin", 0, 0, false)
check(#vm2.chat(0).entries == 1, "so chat before the first tick is kept")

-- Another mod wraps ours, and we wrap theirs on the next tick.
local theirs = 0
local ours = vm.env.Server.AddChatToHistory
vm.env.Server.AddChatToHistory = function(...) theirs = theirs + 1; return ours(...) end
vm.tick()
check(vm.env.Server.AddChatToHistory ~= ours, "re-wrapped over another mod's wrapper")
vm.say("chain", "Bob", 102, 2, false)
r = vm.chat(2)
check(#r.entries == 1 and theirs == 1 and vm.vanillaCalls() == 3,
      "a chain through our wrapper twice records once, and runs everything once")

-- A message the game refuses by erroring is not recorded, and the error stands.
local ok, err = pcall(vm.say, "explode", "Bob", 102, 2, false)
check(not ok and tostring(err):find("refused"), "the game's error reaches the caller")
check(#vm.chat(3).entries == 0, "and nothing was recorded")
vm.say("after", "Bob", 102, 2, false)
check(#vm.chat(3).entries == 1, "chat still works after an error")

-- Odd arguments are recorded with defaults rather than breaking chat.
vm.say("odd", nil, "103", nil, nil)
r = vm.chat(4)
e = r.entries[1]
check(e and e.player == "" and e.steamId == 103 and e.team == 0 and e.teamOnly == false,
      "nil and string arguments are normalized")

-- More than the ring holds.
for i = 1, 250 do vm.say("spam " .. i, "Carol", 104, 2, false) end
r = vm.chat(0)
check(#r.entries == 200, "the ring keeps 200")
check(r.last_id == 255 and r.entries[1].id == 56 and r.entries[200].id == 255, "ids keep counting: 56..255")
check(r.dropped == 55, "and the 55 that fell out are counted")
check(#vm.env.Server.recentChatMessages:ToTable() == 20, "the game's own list is still 20")

-- A map change is a fresh VM: ids start over.
vm = NewVM(clock)
vm.tick()
vm.say("new map", "Alice", 101, 0, false)
r = vm.chat(255)
check(r.last_id == 1 and #r.entries == 0, "after a map change last_id is 1: below the old cursor")
check(#vm.chat(0).entries == 1, "and the new map's chat is there from 0")

print("all passed")

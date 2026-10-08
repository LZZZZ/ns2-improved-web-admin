-- What lua/ServerWebInterface.lua costs the server, in CPU time: the numbers
-- in docs/SERVER-COST.md.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed,
-- as the harnesses do, then plays an hour on one map: 18 players, a perf
-- window every 10 s, a TICKSTAT line every 10 s appended to a real
-- log-Server.txt, the engine scan every 2 s. Then it times
-- the mod's own handlers through the WebRequest and UpdateServer hooks. The
-- stubs answer at once, so what is timed is the Lua and dkjson, not the
-- engine calls they make; the real engine's are extra, and small beside
-- dkjson. Times are this machine's: a server's CPU is likely slower.
--
-- Usage: luajit tools/spikes/server-cost-bench.lua --core <core/lua>
--            [--mod <file>] [log-Server.txt] [dir]
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua and RingBuffer.lua come from there.
--   --mod times another copy of the file, e.g. one from git history.
--   The log seeds the stand-in config:// (default: the rig's tickstat lines
--   only); its TICKSTAT lines, when it has any, are the ones appended.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")(
    "--core <core/lua> [--mod <file>] [log-Server.txt] [dir]", { "core" })
local CORE = opts.core
local MOD = opts.mod or (REPO .. "lua/ServerWebInterface.lua")
local SEED = pos[1] or (HERE .. "tickstat-rig-20260928.txt")
local DISK = pos[2]
local ownDisk = not DISK
if ownDisk then
    DISK = os.tmpname()
    os.remove(DISK)
end
os.execute("mkdir -p '" .. DISK .. "/webadmin-spa'")
local LOG = DISK .. "/log-Server.txt"

local realOpen = io.open
local dkjson = dofile(CORE .. "dkjson.lua")
local clock = os.clock

-- The seed log, with the engine's header if it has none, and its TICKSTAT lines.
local seed = assert(realOpen(SEED, "rb")):read("*a")
if not seed:find("^Date: ") then
    seed = "Date: 10/07/2026\nTime: 11:55:07 PM:\nBuild: 344 (403a92901a beta)\n" .. seed
end
local tickstats = { }
for line in seed:gmatch("[^\n]+") do
    if line:sub(1, 9) == "TICKSTAT|" then tickstats[#tickstats + 1] = line end
end
assert(#tickstats > 0, "no TICKSTAT lines in " .. SEED)
do local f = realOpen(LOG, "wb"); f:write(seed); f:close() end
local function append(text) local f = realOpen(LOG, "ab"); f:write(text); f:close() end

-- A ServerPerformanceData: perf-harness.lua's, cut down to what is read.
local kSummed = { "duration", "idle", "moves", "movesTime", "updTime", "incomplete", "warns", "fails" }
local function PerfData(fields)
    local d = fields or { }
    for _, k in ipairs(kSummed) do d[k] = d[k] or 0 end
    d.entities, d.players, d.score, d.quality = d.entities or 0, d.players or 0, d.score or 0, d.quality or 0
    d.stamp, d.tickrate = d.stamp or 0, d.tickrate or 80
    local get = function(k) return function(self) return self[k] end end
    d.GetTimestamp, d.GetDurationMs = get("stamp"), get("duration")
    d.GetNumPlayers, d.GetScore, d.GetQuality = get("players"), get("score"), get("quality")
    d.GetTimeSpentIdling, d.GetTimeSpentOnMoves = get("idle"), get("movesTime")
    d.GetTimeSpentOnUpdate, d.GetMovesProcessed = get("updTime"), get("moves")
    d.GetEntityCount, d.GetIncompleteCount = get("entities"), get("incomplete")
    d.GetNumInterpWarns, d.GetNumInterpFails = get("warns"), get("fails")
    d.GetTickrate = get("tickrate")
    d.GetMoverate = function() return 40 end
    d.GetSendrate = function() return 40 end
    d.GetInterpMs = function() return 85 end
    d.GetMaxPlayers = function() return 18 end
    function d:Accumulate(o)
        for _, k in ipairs(kSummed) do self[k] = self[k] + o[k] end
        self.entities, self.players, self.score, self.quality = o.entities, o.players, o.score, o.quality
        self.stamp = o.stamp
    end
    function d:Clear() for _, k in ipairs(kSummed) do self[k] = 0 end end
    return d
end

-- 18 players, ScoringMixin's methods included.
local function Players(n)
    local list = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    for i = 1, n do
        local client = {
            id = 76561198000000000 + i,
            GetUserId = function(self) return self.id end,
            GetIsVirtual = function() return false end,
            GetPing = function() return 80 end,
        }
        local player = {
            name = "Player number " .. i, team = i % 2 + 1, client = client,
            GetName = function(self) return self.name end,
            GetTeamNumber = function(self) return self.team end,
            GetIsCommander = function() return false end,
            GetScore = function() return 120 end, GetKills = function() return 12 end,
            GetAssistKills = function() return 3 end, GetDeaths = function() return 7 end,
            GetResources = function() return 45.5 end,
            GetPlayerSkill = function() return 1771 end, GetPlayerSkillOffset = function() return -214 end,
            GetCommanderSkill = function() return 1931 end, GetCommanderSkillOffset = function() return 200 end,
            GetSkillTier = function() return 4 end,
        }
        client.GetControllingPlayer = function() return player end
        list[i] = player
    end
    return list
end

local function NewVM()
    local hooks = { }
    local vm = { real = 1000, unix = 1791417600, ticks = 0, stamp = 0 }
    local players = Players(18)
    vm.players = players
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function(path, mode)
        local rel = path:match("^config://(.*)$")
        if not rel then return nil, "not a mounted root" end
        return realOpen(DISK .. "/" .. rel, mode)
    end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.table = setmetatable({ array = function() return { } end,
                               icount = function(t) return #t end }, { __index = table })
    local rb = assert(loadfile(CORE .. "RingBuffer.lua"))
    setfenv(rb, env)
    rb()
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    vm.sample = PerfData({ stamp = 0 })
    env.Shared = {
        Message = function(m) append(tostring(m) .. "\n") end,
        SetWebRoot = function() end,
        GetSystemTime = function() return math.floor(vm.unix) end,
        GetSystemTimeReal = function() return vm.real end,
        GetTime = function() return vm.real end,
        GetMapName = function() return "ns2_veil" end,
        GetEntitiesWithClassname = function() return players end,
        GetServerPerformanceData = function() return vm.sample end,
        GetCheatsEnabled = function() return false end,
        GetDevMode = function() return false end,
        ConsoleCommand = function() end,
    }
    env.ServerPerformanceData = function() return PerfData() end
    env.ientitylist = function(list) return ipairs(list) end
    env.HasMixin = function() return true end
    env.IPAddressToString = function(a) return a end
    env.kDefaultPlayerName = "NSPlayer"
    env.GetEntitiesForTeam = function() return { { GetTeamResources = function() return 50 end } } end
    local team = { GetNumPlayers = function() return 9 end }
    local rules = { GetGameStarted = function() return true end, GetGameStartTime = function() return 0 end,
                    GetTeam1 = function() return team end, GetTeam2 = function() return team end }
    env.GetGamerules = function() return rules end
    env.GetBannedPlayersList = function() return { } end
    env.Server = {
        GetFrameRate = function() return 80 end, GetName = function() return "webadmin-spa bench" end,
        GetMaxPlayers = function() return 18 end,
        GetOwner = function(p) return p.client end,
        GetClientAddress = function(c) return "191.123.45." .. (c.id % 256) end,
        SaveReservedSlotsConfig = function() end,
    }
    env.Log = function() end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    -- One tick at 10 Hz: an engine sample every second, as the rig measured.
    function vm.tick()
        vm.real, vm.unix = vm.real + 0.1, vm.unix + 0.1
        vm.ticks = vm.ticks + 1
        if vm.ticks % 10 == 0 then
            vm.stamp = vm.stamp + 1
            vm.sample = PerfData({ stamp = vm.stamp, duration = 1000, players = 18, score = 90,
                                   quality = 95, entities = 2400, idle = 600, moves = 1200,
                                   movesTime = 150, updTime = 200 })
        end
        for _, fn in ipairs(hooks.UpdateServer) do fn() end
    end
    function vm.request(params)
        local _, body = hooks.WebRequest[1](params)
        return body
    end
    function vm.hook(name, ...) for _, fn in ipairs(hooks[name]) do fn(...) end end
    return vm
end

local function bench(name, n, f)
    f()
    local t0 = clock()
    for _ = 1, n do f() end
    local ms = (clock() - t0) / n * 1000
    print(string.format("  %-60s %8.3f ms", name, ms))
    return ms
end

print(("mod:  %s\nseed: %s (%d KB, %d TICKSTAT lines)"):format(MOD, SEED, math.floor(#seed / 1024), #tickstats))

local vm = NewVM()
for _, p in ipairs(vm.players) do vm.hook("ClientConnect", p.client) end
-- An hour and a bit: 362 windows, 362 TICKSTAT lines found by the scan.
local t0 = clock()
for i = 1, 36200 do
    if i % 100 == 0 then append(tickstats[math.floor(i / 100) % #tickstats + 1] .. "\n") end
    vm.tick()
end
local simulated = clock() - t0
local first = dkjson.decode(vm.request({ request = "getperf", since = "999999", esince = "999999" }))

print(("\nAfter an hour on one map: windows up to id %d, tickstat lines up to id %d (360 kept of each)")
    :format(first.last_id, first.engine.last_id))

print("\nPer tick, with or without a panel (UpdateServer hook)")
print(string.format("  %-60s %8.3f ms", "average over the simulated hour", simulated / 36200 * 1000))
bench("a tick that does not scan", 2000, function()
    vm.real, vm.unix = vm.real + 0.001, vm.unix + 0.001
    vm.hook("UpdateServer")
end)
local function scanWith(text)
    return function()
        append(text)
        vm.real, vm.unix = vm.real + 2, vm.unix + 2
        vm.hook("UpdateServer")
    end
end
-- Real log lines, cut at line starts: what a scan usually meets.
local function slice(bytes)
    local text = seed:sub(-bytes)
    return text:sub(text:find("\n", 1, true) + 1)
end
bench("a tick that scans 1 KB of new log (2 s on the 80-tick box)", 200, scanWith(slice(1024)))
bench("a tick that scans 256 KB of it (the cap, after a hitch)", 20, scanWith(slice(256 * 1024)))
bench("a tick that scans 256 KB of TICKSTAT lines (the worst)", 20,
      scanWith(string.rep(tickstats[1] .. "\n", math.floor(256 * 1024 / (#tickstats[1] + 1)))))

-- Back to an hour's worth of records: the scans above added some.
vm = NewVM()
for _, p in ipairs(vm.players) do vm.hook("ClientConnect", p.client) end
for i = 1, 36200 do
    if i % 100 == 0 then append(tickstats[math.floor(i / 100) % #tickstats + 1] .. "\n") end
    vm.tick()
end

print("\nPer request, only while a panel polls (WebRequest hook)")
bench("request=json, 18 players", 500, function() vm.request({ request = "json" }) end)
local body = vm.request({ request = "getperf" })
local r = dkjson.decode(body)
bench(("getperf since=0: the first reply, %d windows + %d tickstat, %d KB")
      :format(#r.windows, #r.engine.tickstats, math.floor(#body / 1024)), 20,
      function() vm.request({ request = "getperf" }) end)
-- Every page a client fetches from 0, as the panel does, timing only the
-- server's side: the decode between pages is the client's.
local caughtUp
local function catchUp()
    local since, esince, pages, spent, worst = 0, 0, 0, 0, 0
    repeat
        local t = clock()
        local b = vm.request({ request = "getperf", since = tostring(since), esince = tostring(esince) })
        t = clock() - t
        spent, worst, pages = spent + t, math.max(worst, t), pages + 1
        local p = dkjson.decode(b)
        since, esince = p.last_id, p.engine.last_id
    until not (p.more or p.engine.more)
    caughtUp = { since = since, esince = esince }
    return pages, spent, worst
end
local runs, pages, spent, worst = 20, 0, 0, 0
catchUp()
for _ = 1, runs do
    local n, s1, w = catchUp()
    pages, spent, worst = n, spent + s1, math.max(worst, w)
end
print(string.format("  %-60s %8.3f ms", ("getperf from 0 until caught up: %d pages, summed"):format(pages),
                    spent / runs * 1000))
print(string.format("  %-60s %8.3f ms", "  the slowest page", worst * 1000))
bench("getperf steady poll (one window, one line)", 500, function()
    vm.request({ request = "getperf", since = tostring(caughtUp.since - 1),
                 esince = tostring(caughtUp.esince - 1) })
end)
local log = dkjson.decode(vm.request({ request = "getlog" }))
bench("getlog first tail (64 KB)", 50, function() vm.request({ request = "getlog" }) end)
bench("getlog since an old cursor: one reply, at the cap", 20, function()
    vm.request({ request = "getlog", file = log.file_id, since = tostring(math.max(0, log.size - 1024 * 1024)) })
end)
do
    -- 1 MB behind, the most the panel catches up rather than skipping.
    local replies, spent, worst = 0, 0, 0
    for _ = 1, 10 do
        local cursor, n = math.max(0, log.size - 1024 * 1024), 0
        repeat
            local t = clock()
            local b = vm.request({ request = "getlog", file = log.file_id, since = tostring(cursor) })
            t = clock() - t
            spent, worst, n = spent + t, math.max(worst, t), n + 1
            local p = dkjson.decode(b)
            cursor = p.to
        until not p.more
        replies = n
    end
    print(string.format("  %-60s %8.3f ms", ("getlog 1 MB behind until caught up: %d replies, summed"):format(replies),
                        spent / 10 * 1000))
    print(string.format("  %-60s %8.3f ms", "  the slowest reply", worst * 1000))
end
bench("getlog steady poll (~2 KB new)", 500, function()
    vm.request({ request = "getlog", file = log.file_id, since = tostring(log.size - 2048) })
end)
bench("getrecentplayers, 18 connected", 200, function() vm.request({ request = "getrecentplayers" }) end)

if ownDisk then os.execute("rm -rf '" .. DISK .. "'") end

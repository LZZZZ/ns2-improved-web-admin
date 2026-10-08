-- Off-rig harness for getperf in lua/ServerWebInterface.lua.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed:
-- a real-time clock the harness moves one tick at a time, and a fake
-- Shared.GetServerPerformanceData that completes a sample every engine second,
-- the way the rig measured it (REQUIREMENTS item 10). The fake accumulator
-- raises an error where the engine raises SIGFPE -- Accumulate() of an empty
-- sample -- so the harness fails where the server would die. It checks the
-- windowing, the cursor, the capacity and the arithmetic, not the engine.
--
-- Usage: luajit tools/spikes/perf-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"

local dkjson = dofile(CORE .. "dkjson.lua")

-- The totals a ServerPerformanceData carries, and how Accumulate combines them.
local kSummed = { "duration", "idle", "moves", "movesTime", "updTime", "entsUpdated",
                  "incomplete", "warns", "fails" }

local function PerfData(fields)
    local d = fields or { }
    for _, k in ipairs(kSummed) do d[k] = d[k] or 0 end
    d.entities = d.entities or 0
    d.players = d.players or 0
    d.score = d.score or 0
    d.quality = d.quality or 0
    d.stamp = d.stamp or 0
    d.tickrate = d.tickrate or 0
    local get = function(k) return function(self) return self[k] end end
    d.GetTimestamp, d.GetDurationMs = get("stamp"), get("duration")
    d.GetNumPlayers, d.GetScore, d.GetQuality = get("players"), get("score"), get("quality")
    d.GetTimeSpentIdling, d.GetTimeSpentOnMoves = get("idle"), get("movesTime")
    d.GetTimeSpentOnUpdate, d.GetMovesProcessed = get("updTime"), get("moves")
    d.GetNumEntitiesUpdated, d.GetEntityCount = get("entsUpdated"), get("entities")
    d.GetIncompleteCount, d.GetNumInterpWarns = get("incomplete"), get("warns")
    d.GetNumInterpFails = get("fails")
    d.GetTickrate = get("tickrate")
    d.GetMoverate = function(self) return self.tickrate > 0 and 40 or 0 end
    d.GetSendrate = function(self) return self.tickrate > 0 and 40 or 0 end
    d.GetInterpMs = function(self) return self.tickrate > 0 and 85 or 0 end
    d.GetMaxPlayers = function(self) return self.tickrate > 0 and 24 or 0 end
    function d:Accumulate(o)
        -- The engine's behaviour, measured: SIGFPE, which nothing catches.
        if o.duration <= 0 then error("SIGFPE: Accumulate() of an empty sample") end
        local total = self.duration + o.duration
        self.entities = math.floor((self.entities * self.duration + o.entities * o.duration) / total)
        for _, k in ipairs(kSummed) do self[k] = self[k] + o[k] end
        self.players, self.score, self.quality = o.players, o.score, o.quality
        self.tickrate, self.stamp = o.tickrate, o.stamp
    end
    function d:Clear()
        for _, k in ipairs(kSummed) do self[k] = 0 end
        self.entities, self.players, self.score, self.quality = 0, 0, 0, 0
    end
    return d
end

local function NewVM(opts)
    opts = opts or { }
    local hooks = { }
    local vm = { real = opts.real or 1000, tickrate = opts.tickrate or 60, ticks = 0,
                 stamp = 0, sigfpe = nil }
    -- Before the engine's first second the sample is empty, and its timestamp
    -- still moves once (the rig saw timestamp 0 then 1.0).
    vm.sample = PerfData({ stamp = 0 })
    vm.next = { players = 12, score = 20, quality = 90, entities = 800,
                idle = 600, moves = 1200, movesTime = 250, updTime = 120,
                entsUpdated = 48000, incomplete = 0, warns = 0, fails = 0 }
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "not allowed" end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.table = setmetatable({ array = function() return { } end }, { __index = table })
    local rb = assert(loadfile(CORE .. "RingBuffer.lua"))
    setfenv(rb, env)
    rb()
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    env.Shared = {
        Message = function() end, SetWebRoot = function() end,
        GetSystemTime = function() return math.floor(vm.real) end,
        GetSystemTimeReal = function() return vm.real end,
        GetTime = function() return vm.real end,
        GetMapName = function() return opts.map or "ns2_tram" end,
        GetEntitiesWithClassname = function() return players end,
        GetServerPerformanceData = function() return vm.sample end,
    }
    env.ServerPerformanceData = function() return PerfData() end
    env.ientitylist = function(list) return ipairs(list) end
    env.Server = { GetFrameRate = function() return vm.tickrate end }
    env.Log = function() end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    -- One server tick of `ms` milliseconds (default 1000 / tickrate). Every
    -- tickrate ticks the engine completes a one-second sample.
    function vm.tick(ms)
        vm.real = vm.real + (ms or 1000 / vm.tickrate) / 1000
        vm.ticks = vm.ticks + 1
        if vm.ticks % vm.tickrate == 0 then
            vm.stamp = vm.stamp + 1
            local f = { stamp = vm.stamp, duration = 1000, tickrate = vm.tickrate }
            for k, v in pairs(vm.next) do f[k] = v end
            if vm.emptySamples and vm.emptySamples > 0 then
                vm.emptySamples = vm.emptySamples - 1
                f = { stamp = vm.stamp }
            end
            vm.sample = PerfData(f)
        end
        local ok, err = pcall(function()
            for _, fn in ipairs(hooks.UpdateServer) do fn() end
        end)
        if not ok then vm.sigfpe = vm.sigfpe or tostring(err) end
    end
    function vm.seconds(n) for _ = 1, math.floor(n * vm.tickrate + 0.5) do vm.tick() end end
    function vm.request(params)
        local ctype, body = hooks.WebRequest[1](params)
        return ctype, body and dkjson.decode(body), body
    end
    return vm
end

local failures = 0
local function check(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

local function ids(r)
    local t = { }
    for _, w in ipairs(r.windows) do t[#t + 1] = w.id end
    return table.concat(t, ",")
end

-- 1. Before the engine's first sample: an empty report, no config.
do
    local vm = NewVM()
    local ctype, r, body = vm.request({ request = "getperf" })
    check(ctype == "application/json" and r.window_s == 10 and r.capacity == 360,
          "window_s 10, capacity 360")
    check(r.loaded_at == 1000 and r.map == "ns2_tram", "loaded_at and map")
    check(r.last_id == 0 and #r.windows == 0 and body:find('"windows":%[%]') ~= nil,
          "no windows yet, encoded as []")
    check(r.config == nil, "no config before the engine has a sample")
end

-- 2. Empty samples after a map load are never accumulated (the SIGFPE).
do
    local vm = NewVM()
    vm.emptySamples = 3
    vm.seconds(25)
    check(vm.sigfpe == nil, "no Accumulate() of an empty sample" ..
          (vm.sigfpe and (": " .. vm.sigfpe) or ""))
    local _, r = vm.request({ request = "getperf" })
    -- Empty at 1, 2 and 3 s; the first real sample (4 s) starts the window,
    -- which closes at 14 and 24 s.
    check(#r.windows == 2 and r.windows[1].duration_ms == 10000,
          "the first window starts at the first real sample")
end

-- 3. Windows: 10 s each, ticks counted, the arithmetic of DetailText.
do
    local vm = NewVM()
    vm.seconds(31)
    local _, r = vm.request({ request = "getperf" })
    check(vm.sigfpe == nil, "no error while sampling")
    check(ids(r) == "1,2,3" and r.last_id == 3, "three windows in 31 s, ids 1-3")
    local w = r.windows[2]
    check(w.duration_ms == 10000 and w.ticks == 600, "10000 ms and 600 ticks per window")
    check(math.abs(w.tickrate - 60) < 0.01, "tickrate counted: 60 (not 1000/16 = 62.5)")
    check(math.abs(w.worst_tick_ms - 16.7) < 0.05, "worst tick 16.7 ms at 60 tick")
    check(w.idle_pct == 60 and w.moves_pct == 25 and w.entities_pct == 12,
          "idle, moves and entities % as DetailText computes them")
    check(w.moves_per_s == 1200 and math.abs(w.move_ms - 0.208) < 0.001,
          "moves per second and ms per move")
    check(w.players == 12 and w.score == 20 and w.quality == 90 and w.entities == 800,
          "players, score, quality, entities")
    check(w.interp_warns == 0 and w.interp_fails == 0 and w.incomplete == 0,
          "warn, fail and incomplete counts")
    check(type(w.lua_kb) == "number" and w.lua_kb > 0, "Lua heap in KB")
    check(r.config and r.config.tickrate == 60 and r.config.moverate == 40
          and r.config.sendrate == 40 and r.config.interp_ms == 85
          and r.config.max_players == 24, "config from the engine's settings")
end

-- 4. The cursor.
do
    local vm = NewVM()
    vm.seconds(31)
    local _, r = vm.request({ request = "getperf", since = "2" })
    check(ids(r) == "3" and r.last_id == 3, "since=2 returns window 3 only")
    _, r = vm.request({ request = "getperf", since = "3" })
    check(#r.windows == 0 and r.last_id == 3, "since=last returns none")
    _, r = vm.request({ request = "getperf", since = "junk" })
    check(ids(r) == "1,2,3", "a junk since reads as 0")
end

-- 5. A hitch shows in its window only; a slower tickrate is counted.
do
    local vm = NewVM()
    vm.seconds(11)
    vm.tick(75)
    vm.seconds(20)
    local _, r = vm.request({ request = "getperf" })
    check(r.windows[2].worst_tick_ms == 75, "a 75 ms tick is that window's worst")
    check(math.abs(r.windows[3].worst_tick_ms - 16.7) < 0.05, "and not the next one's")
    check(r.windows[2].tickrate < 60, "the hitch window counts fewer ticks per second")
end

-- 6. Nobody on, no moves: nothing divides by zero.
do
    local vm = NewVM()
    vm.next = { players = 0, score = 0, quality = 0, entities = 150, idle = 820,
                moves = 0, movesTime = 0, updTime = 25, entsUpdated = 0 }
    vm.seconds(12)
    local _, r, body = vm.request({ request = "getperf" })
    local w = r.windows[1]
    check(w and w.move_ms == nil and w.moves_per_s == 0 and w.players == 0,
          "no move_ms without moves, moves_per_s 0")
    check(not body:find("nan") and not body:find("inf"), "no nan or inf in the reply")
end

-- 7. Capacity: an hour of windows, the oldest dropped. Served in pages of
-- 60 from the cursor, oldest first, each saying whether more is held.
do
    local vm = NewVM({ tickrate = 20 })
    vm.seconds(3625)
    local all, pages, since, r = { }, 0, 0, nil
    repeat
        _, r = vm.request({ request = "getperf", since = tostring(since) })
        pages = pages + 1
        check(#r.windows <= 60, ("page %d holds at most 60 (%d)"):format(pages, #r.windows))
        for _, w in ipairs(r.windows) do all[#all + 1] = w.id end
        since = r.last_id
    until not r.more or pages > 10
    local newest = all[#all]
    local ordered = true
    for i = 2, #all do ordered = ordered and all[i] == all[i - 1] + 1 end
    check(pages == 6 and #all == 360 and ordered and all[1] == newest - 359,
          ("360 windows kept, oldest first, in 6 pages (%d in %d)"):format(#all, pages))
    check(r.more == false and r.last_id == newest, "the last page: more false, last_id the newest")
    _, r = vm.request({ request = "getperf" })
    check(#r.windows == 60 and r.more == true and r.last_id == r.windows[60].id,
          "a first page: 60, more, last_id its own last window")
    _, r = vm.request({ request = "getperf", since = tostring(newest - 60) })
    check(#r.windows == 60 and r.more == false and r.last_id == newest,
          "exactly 60 left: one page, no more")
end

-- 8. A runtime rate change shows in config at once, and in the tickrate.
do
    local vm = NewVM({ tickrate = 30 })
    vm.seconds(11)
    vm.tickrate = 80
    vm.ticks = 0
    vm.seconds(22)
    local _, r = vm.request({ request = "getperf" })
    check(r.config.tickrate == 80, "config follows a runtime tickrate")
    check(math.abs(r.windows[#r.windows].tickrate - 80) < 0.1, "and the counted tickrate too")
end

-- 9. A map change is a new VM: loaded_at moves, ids restart.
do
    local a = NewVM({ real = 1000 })
    a.seconds(21)
    local b = NewVM({ real = 2000, map = "ns2_veil" })
    b.seconds(11)
    local _, ra = a.request({ request = "getperf" })
    local _, rb = b.request({ request = "getperf" })
    check(ra.loaded_at == 1000 and rb.loaded_at == 2000 and rb.map == "ns2_veil",
          "loaded_at and map belong to the load")
    check(ids(rb) == "1", "ids restart at 1")
end

-- 10. getperfdata is vanilla: an array of four-key samples, one a minute.
do
    local vm = NewVM()
    vm.seconds(125)
    local _, r = vm.request({ request = "getperfdata" })
    local keys = { }
    for k in pairs(r[1] or { }) do keys[#keys + 1] = k end
    table.sort(keys)
    check(#r == 3 and table.concat(keys, ",") == "ent_count,players,tickrate,time",
          "getperfdata: 3 samples in 125 s, keys unchanged")
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

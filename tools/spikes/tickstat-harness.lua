-- Off-rig harness for getperf's `engine` part in lua/ServerWebInterface.lua:
-- tickstat windows from Server.GetTickStat(), and the scan of the server's
-- log for the engine's snapshot rate, bwlimit, perfmon: and `tickstat:` lines.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed.
-- GetTickStat answers what the harness sets, in the 10-12 engine's field names
-- (measured on the rig, 2026-10-12); Shared.ReadLog reads a log-Server.txt the
-- harness appends to, with the lines the rig's 09-27 engine really wrote
-- (tickstat-rig-20260928.txt). A clock the harness moves drives the polls and
-- scans through the UpdateServer hook. It checks the mapping, the parsing, the
-- cursor, the stamps and the edges -- not the engine: what the engine writes
-- and when is a rig question (docs/REQUIREMENTS.md item 10).
--
-- Usage: luajit tools/spikes/tickstat-harness.lua --core <core/lua> [dir]
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
--   dir defaults to a fresh temporary directory.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua> [dir]", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"
local RIG = HERE .. "tickstat-rig-20260928.txt"
local DISK = pos[1]
if not DISK then
    DISK = os.tmpname()
    os.remove(DISK)
end
os.execute("mkdir -p '" .. DISK .. "'")
local LOG = DISK .. "/log-Server.txt"

local realOpen = io.open
local dkjson = dofile(CORE .. "dkjson.lua")

local function header(time)
    return "Date: 09/28/2026\nTime: " .. time .. ":\nBuild: 344 (5dc97682bc beta)\n"
        .. string.rep("-", 62) .. "\n"
end
local function write(text) local f = realOpen(LOG, "wb"); f:write(text); f:close() end
local function append(text) local f = realOpen(LOG, "ab"); f:write(text); f:close() end

-- Shared.ReadLog(offset, maxBytes): the bytes, and the file's size.
local function ReadLog(offset, maxBytes)
    local f = realOpen(LOG, "rb")
    local data = f and f:read("*a") or ""
    if f then f:close() end
    offset = tonumber(offset) or 0
    if offset < 0 then offset = math.max(0, #data + offset) end
    local stop = maxBytes and (offset + maxBytes) or #data
    return data:sub(offset + 1, math.min(stop, #data)), #data
end

-- The rig's lines, comments dropped, in order.
local rig = { }
for line in realOpen(RIG, "rb"):lines() do
    if line:sub(1, 2) ~= "# " then rig[#rig + 1] = line end
end
local function rigLines(pred)
    local out = { }
    for _, l in ipairs(rig) do if pred(l) then out[#out + 1] = l end end
    return out
end
local tickstats = rigLines(function(l) return l:sub(1, 9) == "TICKSTAT|" end)
local rates = rigLines(function(l) return l:find("snapshot rate", 1, true) ~= nil end)
local warning = rigLines(function(l) return l:find(" leaves ", 1, true) ~= nil end)[1]
local function lastBlock()
    -- The last complete perfmon: block with players on (score 63).
    for i = #rig, 1, -1 do
        if rig[i]:find("^perfmon: score 63 ") then
            local out = { }
            for j = i - 5, i do out[#out + 1] = rig[j] end
            return out
        end
    end
end
local block = lastBlock()

-- A GetTickStat() window as the 10-12 engine returns it, a populated one.
local function Window(time, extra)
    local w = {
        time = time, window = 10.002, hz = 79.991, target = 80,
        intervalP50 = 12.55, intervalP99 = 14.4, intervalP999 = 14.55, intervalMax = 14.553,
        latenessMax = 2.0612, rearms = 0, stretchPct = 0, governorMax = 0,
        incomplete = 0, loops = 2422, incompleteLate = 0, incompleteWriters = 0, incompleteMoves = 0,
        waitOverP99 = 2.06, waitOverMax = 2.0601, waits = 1978, busyPct = 29.9,
        humans = 1, bots = 11, snapPerSecPerHuman = 40, bytesPerSecPerHuman = 7639,
        movesPerSecPerHuman = 40, movesPerSecPerBot = 80, injectedPct = 0,
        moveMsPerTick = 1.382, specMovesPerSec = 2.2, specMoveMsPerTick = 0.002,
        snapBytesP50 = 192, snapBytesP99 = 384, snapBytesMax = 2737, chokedPct = 0,
        humanMoveMsPerTick = 0.061, sendBufDrops = 0, rateStepped = 0,
        slowestSendrate = 0, creationsDeferred = 0,
    }
    for k, v in pairs(extra or { }) do w[k] = v end
    return w
end

-- `opts.bw`: what Server.GetBwLimit returns.
local function NewVM(opts)
    opts = opts or { }
    local hooks = { }
    local vm = { real = 1000, unix = 1790589400, stat = nil }
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "not in this harness" end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.table = setmetatable({ array = function() return { } end }, { __index = table })
    local rb = assert(loadfile(CORE .. "RingBuffer.lua"))
    setfenv(rb, env)
    rb()
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    -- Always an empty sample: the windows stay out of it, the config does not.
    local sample = {
        GetTimestamp = function() return 0 end, GetDurationMs = function() return 0 end,
        GetTickrate = function() return 80 end, GetMoverate = function() return 40 end,
        GetSendrate = function() return 40 end, GetInterpMs = function() return 85 end,
        GetMaxPlayers = function() return 16 end,
    }
    env.Shared = {
        Message = function(m) append(tostring(m) .. "\n") end,
        SetWebRoot = function() end,
        GetSystemTime = function() return math.floor(vm.unix) end,
        GetSystemTimeReal = function() return vm.real end,
        -- Server time: seconds since the map loaded, here the real clock.
        GetTime = function() return vm.real end,
        GetMapName = function() return "ns2_summit" end,
        GetEntitiesWithClassname = function() return players end,
        GetServerPerformanceData = function() return sample end,
        ReadLog = ReadLog,
    }
    env.ServerPerformanceData = function() return sample end
    env.ientitylist = function(list) return ipairs(list) end
    env.Server = {
        GetFrameRate = function() return 80 end,
        GetBwLimit = function() return opts.bw or 131072 end,
        GetTickStat = function() return vm.stat end,
    }
    env.Log = function() end
    local chunk = assert(loadfile(MOD))
    dofile(HERE .. "engine-stubs.lua")(env, dkjson)
    setfenv(chunk, env)
    chunk()

    -- `s` seconds of server time, ticking at 10 Hz: enough for 2 s scans.
    function vm.run(s)
        for _ = 1, math.floor(s * 10 + 0.5) do
            vm.real, vm.unix = vm.real + 0.1, vm.unix + 0.1
            for _, fn in ipairs(hooks.UpdateServer) do fn() end
        end
    end
    -- A window that closed just now, by the server's clock.
    function vm.window(extra)
        vm.stat = Window(vm.real, extra)
    end
    function vm.perf(params)
        params = params or { }
        params.request = "getperf"
        local ctype, body = hooks.WebRequest[1](params)
        return dkjson.decode(body).engine, body, ctype
    end
    return vm
end

local failures = 0
local function check(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-6 end

check(#tickstats >= 40 and #rates == 2 and warning and block,
      ("the rig's lines: %d tickstat, %d rate, a warning, a block"):format(#tickstats, #rates))

-- 1. Before anything: tickstat off, nothing from the log before the load.
do
    write(header("06:56:27 AM") .. table.concat(tickstats, "\n", 1, 5) .. "\n" .. rates[1] .. "\n")
    local vm = NewVM({ bw = 131072 })
    vm.run(3)
    local e, body = vm.perf()
    check(e.scan_s == 2 and e.now == math.floor(vm.unix),
          "a 2 s scan, the server's clock")
    check(#e.tickstats == 0 and #e.events == 0 and e.last_id == 0 and e.tickstat_last_at == nil,
          "nothing while tickstat is off, nothing from before the load")
    check(body:find('"tickstats":%[%]') and body:find('"perfmon":%[%]') and body:find('"events":%[%]'),
          "empty lists encode as []")
    local cfg = dkjson.decode(body).config
    check(cfg and cfg.bw_limit == 131072, "config.bw_limit from Server.GetBwLimit")
end

-- 2. One window, every field under getperf's names, stamped when it closed.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    vm.window()
    local closed = vm.unix
    vm.run(3)
    local e = vm.perf()
    local t = e.tickstats[1]
    check(#e.tickstats == 1 and t.id == 1 and e.last_id == 1, "one record, id 1, though polled three times")
    check(t.time >= math.floor(closed) - 1 and t.time <= closed and e.tickstat_last_at == t.time,
          "stamped when the window closed, on the system clock")
    local missing = { }
    for k in pairs(Window(0)) do
        if k ~= "time" and type(t[k]) ~= "number" then missing[#missing + 1] = k end
    end
    check(#missing == 0, "every field the engine gave, by its own name"
          .. (#missing > 0 and (": " .. table.concat(missing, ",")) or ""))
    check(t.humans == 1 and t.bots == 11 and t.target == 80 and near(t.window, 10.002)
          and near(t.intervalP99, 14.4) and t.loops == 2422, "values as the engine gave them")
end

-- 3. A field from a newer engine is sent too.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    vm.window({ futureThing = 3 })
    vm.run(1.5)
    local t = vm.perf().tickstats[1]
    check(t and t.futureThing == 3 and t.humans == 1, "a field from a newer engine passes through")
end

-- 4. The log's own TICKSTAT lines are not read: the windows come from the engine.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append(table.concat(tickstats, "\n", 1, 3) .. "\n")
    vm.run(2.5)
    check(#vm.perf().tickstats == 0, "TICKSTAT lines in the log make no records")
end

-- 5. Rate steps and the bwlimit warning, from the bwlimit 10000 run.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append(warning .. "\n" .. rates[1] .. "\n" .. rates[2] .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    local w, down, up = e.events[1], e.events[2], e.events[3]
    check(#e.events == 3, "three events")
    check(w and w.kind == "bwlimit_low" and w.bwlimit == 10000 and w.sendrate == 40
          and w.per_snapshot == 250 and w.needed == 2048 and w.suggested == 81920,
          "the bwlimit warning: 250 of 2048 bytes, 81920 avoids it")
    check(down and down.kind == "rate" and down.client == 1 and near(down.from_rate, 40)
          and near(down.to_rate, 26.7) and down.choked_pct == 29 and near(down.clear_ms, 24.9)
          and down.bwlimit == 10000, "a step down: 40 -> 26.7/s, 29% choked")
    check(up and near(up.from_rate, 26.7) and near(up.to_rate, 40) and up.bwlimit == 131072,
          "and back up at 131072")
    vm.window({ chokedPct = 15.75, rateStepped = 1, slowestSendrate = 26.7, creationsDeferred = 31 })
    vm.run(1.5)
    e = vm.perf()
    local t = e.tickstats[1]
    check(t and near(t.chokedPct, 15.75) and t.rateStepped == 1 and near(t.slowestSendrate, 26.7)
          and t.creationsDeferred == 31, "a choked window: 15.75%, stepped, 31 deferred")
    local ids = { }
    for _, r in ipairs(e.events) do ids[#ids + 1] = r.id end
    ids[#ids + 1] = t and t.id
    table.sort(ids)
    check(table.concat(ids, ",") == "1,2,3,4", "one id sequence across kinds")
end

-- 6. The perfmon: block, whole and split across two scans.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append(table.concat(block, "\n", 1, 3) .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(#e.perfmon == 0, "half a block is not served")
    append(table.concat(block, "\n", 4, 6) .. "\n")
    vm.run(2.5)
    e = vm.perf()
    local b = e.perfmon[1]
    check(#e.perfmon == 1, "the block, once its score line is in")
    check(b and near(b.jitter_avg_ms, 1.25) and near(b.jitter_max_ms, 2.05) and b.jitter_n == 80,
          "tick jitter")
    check(b and near(b.snapshot_write_avg_ms, 0.031) and b.snapshot_write_n == 40,
          "snapshot write")
    check(b and b.entities_skipped == 6438 and b.entities_total == 13198
          and near(b.entities_skipped_pct, 48.8), "entities skipped")
    check(b and b.rejected_time_credit == 0 and b.rejected_other == 0 and b.rewound_missing == 0,
          "moves rejected and rewound")
    check(b and b.score == 63 and near(b.idle_pct, 63) and b.delivery_pct == 0
          and b.overload_pct == 0 and b.updates == 40 and b.warn == 0 and b.fail == 0,
          "score = idle - delivery - overload, and its counts")
end

-- 7. tickstat's reply to the command, and the cursor.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append("tickstat: on\n")
    vm.window()
    vm.run(2.5)
    local e = vm.perf()
    check(e.tickstat_said and e.tickstat_said.text == "on", "tickstat: on is seen")
    vm.window(); vm.run(1.5)
    vm.window(); vm.run(1.5)
    local later = vm.perf({ esince = tostring(e.last_id) })
    check(#later.tickstats == 2 and later.tickstats[1].id == e.last_id + 1 and later.last_id == 3,
          "esince returns only what is newer")
    local none = vm.perf({ esince = "3" })
    check(#none.tickstats == 0 and none.last_id == 3, "esince=last returns none")
    append("tickstat: off\n")
    vm.stat = nil
    vm.run(2.5)
    check(vm.perf().tickstat_said.text == "off", "tickstat: off is seen")
end

-- 8. Impostors: lines that start with a player's name.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append("perfmon: tick jitter avg 9.00ms max 9.00ms (n=1) was killed by [BOT] Skulkovich\n")
    append("client 3: snapshot rate 40.0 -> 10.0/s (99% choked, 1.0 ms to clear each, bwlimit 1) is now known as x\n")
    append("tickstat: on and on\n")
    vm.run(2.5)
    local e = vm.perf()
    check(#e.perfmon == 0 and #e.events == 0 and e.tickstat_said == nil,
          "name-prefixed lines are not engine lines")
end

-- 9. A partial last line waits for its newline.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    local line = rates[1]
    append(line:sub(1, 30))
    vm.run(2.5)
    check(#vm.perf().events == 0, "a line without its newline is left")
    append(line:sub(31) .. "\n")
    vm.run(2.5)
    check(#vm.perf().events == 1, "and read whole once it has one")
end

-- 10. A new file, and a scan far behind.
do
    write(header("06:56:27 AM") .. string.rep("filler line\n", 50))
    local vm = NewVM()
    vm.run(1)
    write(header("07:30:00 AM") .. rates[1] .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(#e.events == 1, "a new file is read from its start")
    -- 300 KB of other lines, then one rate step, all between two scans.
    local junk = string.rep(string.rep("x", 99) .. "\n", 3000)
    append(rates[2] .. "\n" .. junk .. rates[1] .. "\n")
    vm.run(2.5)
    e = vm.perf({ esince = "1" })
    check(#e.events == 1 and e.events[1].id == 2,
          "far behind: only the latest 256 KB, from a line start")
end

-- 11. Capacity: an hour of 10 s windows, paged.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    for _ = 1, 400 do vm.window(); vm.run(1.1) end
    local all, pages, esince, e = { }, 0, 0, nil
    repeat
        e = vm.perf({ esince = tostring(esince) })
        pages = pages + 1
        for _, t in ipairs(e.tickstats) do all[#all + 1] = t.id end
        esince = e.last_id
    until not e.more or pages > 10
    check(#all == 360 and all[1] == 41 and all[360] == 400 and pages == 6 and e.last_id == 400,
          ("an hour at 10 s kept: the newest 360, in 6 pages of 60 (%d in %d)"):format(#all, pages))
    e = vm.perf()
    check(#e.tickstats == 60 and e.more == true and e.last_id == 100, "a first page: ids 41-100, more")
end

-- 12. One id sequence across the three lists: a page ends at the 60th lowest
-- id held, whichever list it is in.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    -- Two rate steps, then 70 windows, then the bwlimit warning.
    append(rates[1] .. "\n" .. rates[2] .. "\n")
    vm.run(2.5)
    for _ = 1, 70 do vm.window(); vm.run(1.1) end
    append(warning .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(e.more == true and e.last_id == 60 and #e.events == 2 and #e.tickstats == 58,
          ("page 1: the two events and 58 windows, up to id 60 (%d, %d, %s)"):format(
              #e.events, #e.tickstats, tostring(e.last_id)))
    e = vm.perf({ esince = "60" })
    check(e.more == false and e.last_id == 73 and #e.tickstats == 12 and #e.events == 1
          and e.events[1].kind == "bwlimit_low",
          ("page 2: the other 12 windows and the warning, no more (%d, %d, %s)"):format(
              #e.tickstats, #e.events, tostring(e.last_id)))
    e = vm.perf({ esince = "73" })
    check(e.more == false and #e.tickstats + #e.events == 0 and e.last_id == 73, "caught up: nothing, no more")
end

os.execute("rm -rf '" .. DISK .. "'")
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

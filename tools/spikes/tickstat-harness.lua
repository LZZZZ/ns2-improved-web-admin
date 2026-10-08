-- Off-rig harness for getperf's `engine` part in lua/ServerWebInterface.lua:
-- the scan of log-Server.txt for the engine's tickstat, snapshot rate,
-- bwlimit and perfmon: lines.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed,
-- over a directory standing in for config://, and appends to log-Server.txt
-- the lines the rig's 09-27 engine really wrote (tickstat-rig-20260928.txt).
-- Its io.open serves the file as it was at the open, as Spark's does. A clock
-- the harness moves drives the scans through the UpdateServer hook. It checks
-- the parsing, the cursor, the stamps and the edges -- not the engine: what
-- the engine writes and when is a rig question (docs/REQUIREMENTS.md item 10).
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
local populated = rigLines(function(l) return l:find("humans 1 bots 11", 1, true) ~= nil end)
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

-- `opts.stale`: the file is a copy the engine is not writing.
-- `opts.bw`: Server.GetBwLimit returns it; nil leaves the function out.
local function NewVM(opts)
    opts = opts or { }
    local hooks = { }
    local vm = { real = 1000, unix = 1790589400 }
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function(path, mode)
        local rel = path:match("^config://(.*)$")
        if not rel then return nil, "not a mounted root" end
        if mode ~= "r" and mode ~= "rb" then return realOpen(DISK .. "/" .. rel, mode) end
        local f, err = realOpen(DISK .. "/" .. rel, mode)
        if not f then return nil, err end
        local data = f:read("*a")
        f:close()
        local pos = 0
        return {
            seek = function(_, whence, off)
                off = off or 0
                if whence == "end" then pos = #data + off
                elseif whence == "cur" then pos = pos + off
                else pos = off end
                return pos
            end,
            read = function(_, n)
                if n == "*a" then local t = data:sub(pos + 1); pos = #data; return t end
                if pos >= #data then return nil end
                local t = data:sub(pos + 1, pos + n); pos = pos + #t; return t
            end,
            close = function() end,
        }
    end }
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
        Message = function(m) if not opts.stale then append(tostring(m) .. "\n") end end,
        SetWebRoot = function() end,
        GetSystemTime = function() return math.floor(vm.unix) end,
        GetSystemTimeReal = function() return vm.real end,
        GetTime = function() return vm.real end,
        GetMapName = function() return "ns2_summit" end,
        GetEntitiesWithClassname = function() return players end,
        GetServerPerformanceData = function() return sample end,
    }
    env.ServerPerformanceData = function() return sample end
    env.ientitylist = function(list) return ipairs(list) end
    env.Server = { GetFrameRate = function() return 80 end }
    if opts.bw then env.Server.GetBwLimit = function() return opts.bw end end
    env.Log = function() end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    -- `s` seconds of server time, ticking at 10 Hz: enough for 2 s scans.
    function vm.run(s)
        for _ = 1, math.floor(s * 10 + 0.5) do
            vm.real, vm.unix = vm.real + 0.1, vm.unix + 0.1
            for _, fn in ipairs(hooks.UpdateServer) do fn() end
        end
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

check(#tickstats >= 40 and #populated >= 10 and #rates == 2 and warning and block,
      ("the rig's lines: %d tickstat, %d populated, %d rate, a warning, a block"):format(
          #tickstats, #populated, #rates))

-- 1. The first scan starts at the end: lines already there are not stamped.
do
    write(header("06:56:27 AM") .. table.concat(tickstats, "\n", 1, 5) .. "\n")
    local vm = NewVM({ bw = 131072 })
    vm.run(3)
    local e, body = vm.perf()
    check(e.source == "log" and e.path == "config://log-Server.txt" and e.scan_s == 2
          and e.now == math.floor(vm.unix),
          "source log, the path, a 2 s scan")
    check(#e.tickstats == 0 and e.last_id == 0 and e.tickstat_last_at == nil,
          "nothing from before the load")
    check(body:find('"tickstats":%[%]') and body:find('"perfmon":%[%]') and body:find('"events":%[%]'),
          "empty lists encode as []")
    local cfg = dkjson.decode(body).config
    check(cfg and cfg.bw_limit == 131072, "config.bw_limit from Server.GetBwLimit")
end

-- 2. A populated line, every field, stamped with the scan that found it.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append(populated[#populated] .. "\n")
    local before = math.floor(vm.unix)
    vm.run(2.5)
    local e = vm.perf()
    local t = e.tickstats[1]
    check(#e.tickstats == 1 and t.id == 1 and e.last_id == 1, "one record, id 1")
    check(t.time >= before and t.time <= before + 3 and e.tickstat_last_at == t.time,
          "stamped at the scan, within its 2 s")
    local fields = { "win_s", "hz", "target", "int_p50_ms", "int_p99_ms", "int_p999_ms",
        "int_max_ms", "late_max_ms", "rearm", "stretch_pct", "gov_max", "incomplete",
        "incomplete_of", "late", "writers", "moves", "wait_p99_ms", "wait_max_ms", "wait_n",
        "busy_pct", "humans", "bots", "snaps_per_s_human", "bytes_per_s_human",
        "moves_per_s_human", "moves_per_s_bot", "injected_pct", "move_ms_tick",
        "spec_moves_per_s", "spec_move_ms_tick", "snap_p50_bytes", "snap_p99_bytes",
        "snap_max_bytes", "choked_pct", "human_move_ms_tick", "sendbuf_drops",
        "rate_stepped", "slowest_rate", "creations_deferred" }
    local missing = { }
    for _, k in ipairs(fields) do if type(t[k]) ~= "number" then missing[#missing + 1] = k end end
    check(#missing == 0 and t.unparsed == 0,
          "all 39 fields numbers, none unparsed" .. (#missing > 0 and (": " .. table.concat(missing, ",")) or ""))
    check(t.humans == 1 and t.bots == 11 and t.target == 80 and t.win_s == 10,
          "humans, bots, target, window")
    local _, body = vm.perf()
    check(dkjson.decode(body).config.bw_limit == nil, "no bw_limit without Server.GetBwLimit")
end

-- 3. The values of one line, exactly.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append("TICKSTAT| win 10.0 s hz 80.00 target 80 | int p50 12.55 p99 14.40 p999 14.55 max 14.55 ms | late max 2.06 ms rearm 0 stretch 0.00% gov max 0 | incomplete 0/2422 late 0 writers 0 moves 0 | wait over p99 2.06 max 2.06 ms (n=1978) | busy 29.9% | humans 1 bots 11 | snap/s/human 40.00 bytes/s/human 7639 | moves/s/human 40.00 moves/s/bot 80.00 injected 0.00% | move ms/tick 1.382 | spec moves/s 2.20 spec move ms/tick 0.002 | snap bytes p50 192 p99 384 max 2737 choked 0.00% | human move ms/tick 0.061 | sendbuf drops 0 | rate stepped 0 slowest 0.0/s | creations deferred 0\n")
    vm.run(2.5)
    local t = vm.perf().tickstats[1]
    check(t and near(t.hz, 80) and near(t.int_p99_ms, 14.4) and near(t.int_p999_ms, 14.55),
          "hz and tick spacing")
    check(t and t.incomplete == 0 and t.incomplete_of == 2422 and t.wait_n == 1978,
          "incomplete a/b and wait n")
    check(t and near(t.busy_pct, 29.9) and t.bytes_per_s_human == 7639
          and near(t.spec_moves_per_s, 2.2) and near(t.human_move_ms_tick, 0.061),
          "busy, bytes/s, spectators, human move cost")
    check(t and t.snap_p50_bytes == 192 and t.snap_p99_bytes == 384
          and t.snap_max_bytes == 2737 and t.choked_pct == 0, "snapshot sizes and choke")
end

-- 4. Choke, rate steps and the bwlimit warning, from the bwlimit 10000 run.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append(warning .. "\n" .. rates[1] .. "\n")
    for _, l in ipairs(tickstats) do
        if l:find("choked 15.75%", 1, true) then append(l .. "\n") end
    end
    append(rates[2] .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    local w, down, up = e.events[1], e.events[2], e.events[3]
    check(#e.events == 3 and #e.tickstats == 1, "three events and the choked window")
    check(w and w.kind == "bwlimit_low" and w.bwlimit == 10000 and w.sendrate == 40
          and w.per_snapshot == 250 and w.needed == 2048 and w.suggested == 81920,
          "the bwlimit warning: 250 of 2048 bytes, 81920 avoids it")
    check(down and down.kind == "rate" and down.client == 1 and near(down.from_rate, 40)
          and near(down.to_rate, 26.7) and down.choked_pct == 29 and near(down.clear_ms, 24.9)
          and down.bwlimit == 10000, "a step down: 40 -> 26.7/s, 29% choked")
    check(up and near(up.from_rate, 26.7) and near(up.to_rate, 40) and up.bwlimit == 131072,
          "and back up at 131072")
    local t = e.tickstats[1]
    check(t and near(t.choked_pct, 15.75) and t.rate_stepped == 1 and near(t.slowest_rate, 26.7)
          and t.creations_deferred == 31, "the window: 15.75% choked, stepped, 31 deferred")
    local ids = { }
    for _, r in ipairs(e.events) do ids[#ids + 1] = r.id end
    ids[#ids + 1] = t and t.id
    table.sort(ids)
    check(table.concat(ids, ",") == "1,2,3,4", "one id sequence across kinds")
end

-- 5. The perfmon: block, whole and split across two scans.
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

-- 6. tickstat's reply to the command, and the cursor.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    append("] tickstat 10\ntickstat: on\n" .. tickstats[1] .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(e.tickstat_said and e.tickstat_said.text == "on", "tickstat: on is seen")
    append(tickstats[2] .. "\n" .. tickstats[3] .. "\n")
    vm.run(2.5)
    local later = vm.perf({ esince = tostring(e.last_id) })
    check(#later.tickstats == 2 and later.tickstats[1].id == e.last_id + 1 and later.last_id == 3,
          "esince returns only what is newer")
    local none = vm.perf({ esince = "3" })
    check(#none.tickstats == 0 and none.last_id == 3, "esince=last returns none")
    append("] tickstat 0\ntickstat: off\n")
    vm.run(2.5)
    check(vm.perf().tickstat_said.text == "off", "tickstat: off is seen")
end

-- 7. Drift and impostors.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    local line = populated[1]
    append(line:gsub(" | sendbuf drops", " | future thing 3 | sendbuf drops") .. "\n")
    -- Four segments only: below the floor.
    append("TICKSTAT| win 10.0 s hz 80.00 target 80 | busy 20.0% | humans 1 bots 0 | sendbuf drops 0\n")
    -- Lines that start with a player's name.
    append("TICKSTAT| win 1 s hz 1 target 1 connected.\n")
    append("perfmon: tick jitter avg 9.00ms max 9.00ms (n=1) was killed by [BOT] Skulkovich\n")
    append("client 3: snapshot rate 40.0 -> 10.0/s (99% choked, 1.0 ms to clear each, bwlimit 1) is now known as x\n")
    append("[23:22:45]Chat All - x: TICKSTAT| win 10.0 s hz 1.00 target 80\n")
    vm.run(2.5)
    local e = vm.perf()
    check(#e.tickstats == 1 and e.tickstats[1].unparsed == 1 and e.tickstats[1].humans == 1,
          "an unknown segment is counted, the rest kept")
    check(#e.perfmon == 0 and #e.events == 0, "name-prefixed lines are not engine lines")
end

-- 8. A partial last line waits for its newline.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    -- The liveness check prints a line at the first getperf; the fake would
    -- append it mid-line, which the engine, writing whole lines, never does.
    vm.perf()
    local line = tickstats[10]
    append(line:sub(1, 200))
    vm.run(2.5)
    check(#vm.perf().tickstats == 0, "a line without its newline is left")
    append(line:sub(201) .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(#e.tickstats == 1 and e.tickstats[1].unparsed == 0, "and read whole once it has one" .. ((" (%d records, unparsed %s)"):format(#e.tickstats, tostring(e.tickstats[1] and e.tickstats[1].unparsed))))
end

-- 9. A new file, and a scan far behind.
do
    write(header("06:56:27 AM") .. string.rep("filler line\n", 50))
    local vm = NewVM()
    vm.run(1)
    write(header("07:30:00 AM") .. tickstats[1] .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(#e.tickstats == 1, "a new file is read from its start")
    -- 300 KB of other lines, then one tickstat, all between two scans.
    local junk = string.rep(string.rep("x", 99) .. "\n", 3000)
    append(tickstats[2] .. "\n" .. junk .. tickstats[3] .. "\n")
    vm.run(2.5)
    e = vm.perf({ esince = "1" })
    check(#e.tickstats == 1 and e.tickstats[1].id == 2 and e.error == nil,
          "far behind: only the latest 256 KB, from a line start")
end

-- 10. Capacity.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    local lines = { }
    for i = 1, 400 do lines[i] = tickstats[(i % #tickstats) + 1] end
    append(table.concat(lines, "\n") .. "\n")
    vm.run(2.5)
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

-- 10b. One id sequence across the three lists: a
-- page ends at the 60th lowest id held, whichever list it is in.
do
    write(header("06:56:27 AM"))
    local vm = NewVM()
    vm.run(1)
    -- Two rate steps, then 70 tickstat lines, then the bwlimit warning.
    append(rates[1] .. "\n" .. rates[2] .. "\n")
    local lines = { }
    for i = 1, 70 do lines[i] = tickstats[(i % #tickstats) + 1] end
    append(table.concat(lines, "\n") .. "\n" .. warning .. "\n")
    vm.run(2.5)
    local e = vm.perf()
    check(e.more == true and e.last_id == 60 and #e.events == 2 and #e.tickstats == 58,
          ("page 1: the two events and 58 lines, up to id 60 (%d, %d, %s)"):format(
              #e.events, #e.tickstats, tostring(e.last_id)))
    e = vm.perf({ esince = "60" })
    check(e.more == false and e.last_id == 73 and #e.tickstats == 12 and #e.events == 1
          and e.events[1].kind == "bwlimit_low",
          ("page 2: the other 12 lines and the warning, no more (%d, %d, %s)"):format(
              #e.tickstats, #e.events, tostring(e.last_id)))
    e = vm.perf({ esince = "73" })
    check(e.more == false and #e.tickstats + #e.events == 0 and e.last_id == 73, "caught up: nothing, no more")
end

-- 11. No log, and a stale one.
do
    os.remove(LOG)
    local vm = NewVM()
    vm.run(3)
    local e = vm.perf()
    check(e.source == "none" and type(e.error) == "string" and #e.tickstats == 0,
          "no file: source none, with the reason")
    write(header("06:56:27 AM"))
    vm = NewVM({ stale = true })
    vm.run(3)
    e = vm.perf()
    check(e.source == "none" and e.stale == true, "a file that does not grow: stale")
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

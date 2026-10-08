-- SPIKE 2026-09-28: what the engine's tickstat and perfmon: lines look like
-- from mod Lua, on the 09-27 engine.
--
-- Not loadable on its own. tools/spikes/make-tickstat-probe.sh splices this
-- into a copy of lua/ServerWebInterface.lua, at the top of OnWebRequest, so
-- the probe runs next to the shipped handlers.   /?request=tickprobe[&from=N]
--
-- Boot with -logdir equal to the config directory, as for getlog. Questions
-- (docs/REQUIREMENTS.md item 10; the rest are read off log-Server.txt):
--   4. Server.GetBwLimit(): does it exist, what does it return, does it
--      follow a runtime `bwlimit`
--   6. the clocks, to map the engine's `[ 123.456]` uptime prefix to wall time
--   7. what a scan of the log from byte `from` to its end costs, and what it
--      finds: TICKSTAT|, `snapshot rate` and perfmon: lines, raw

    if actions.request == "tickprobe" then

        local out = {
            time = Shared.GetTime(),
            system_time = Shared.GetSystemTime(),
            system_time_real = Shared.GetSystemTimeReal(),
            os_time = os and os.time and os.time() or nil,
            os_clock = os and os.clock and os.clock() or nil,
        }

        -- 4. The bandwidth limit, and every Server function that sounds related.
        out.has_getbwlimit = type(Server.GetBwLimit) == "function"
        if out.has_getbwlimit then
            local ok, v = pcall(Server.GetBwLimit)
            out.bwlimit = ok and v or nil
            out.bwlimit_error = (not ok) and tostring(v) or nil
        end
        local names = { }
        for k, v in pairs(Server) do
            local lk = string.lower(tostring(k))
            if type(v) == "function" and (lk:find("rate") or lk:find("bw") or lk:find("tick")
                    or lk:find("band") or lk:find("stat") or lk:find("limit") or lk:find("uptime")) then
                table.insert(names, tostring(k))
            end
        end
        table.sort(names)
        out.server_functions = names

        -- 7. One scan, as the mod would do it every 10 s.
        local t0 = Shared.GetSystemTimeReal()
        local ok, f, err = pcall(io.open, "config://log-Server.txt", "rb")
        if not ok or not f then
            out.log_error = tostring(ok and err or f)
            return "application/json", json.encode(out)
        end
        local head = f:read(160) or ""
        local size = f:seek("end")
        local from = tonumber(actions.from) or math.max(0, size - 256 * 1024)
        if from > size then from = size end
        f:seek("set", from)
        local text = f:read(size - from) or ""
        f:close()
        local t1 = Shared.GetSystemTimeReal()
        local found = { tickstat = { }, rate = { }, perfmon = { }, reply = { } }
        local lines = 0
        for line in string.gmatch(text, "([^\n]*)\n") do
            lines = lines + 1
            if line:find("TICKSTAT|", 1, true) then table.insert(found.tickstat, line)
            elseif line:find("snapshot rate", 1, true) then table.insert(found.rate, line)
            elseif line:find("perfmon:", 1, true) then table.insert(found.perfmon, line)
            elseif line:find("tickstat", 1, true) then table.insert(found.reply, line)
            end
        end
        local t2 = Shared.GetSystemTimeReal()
        out.log = {
            size = size, from = from, bytes = #text, lines = lines,
            read_ms = (t1 - t0) * 1000, scan_ms = (t2 - t1) * 1000, head = head,
        }
        -- The last few of each, raw.
        local function last(t, n)
            local r = { }
            for i = math.max(1, #t - n + 1), #t do table.insert(r, t[i]) end
            return r
        end
        out.tickstat = last(found.tickstat, 4)
        out.tickstat_count = #found.tickstat
        out.rate = last(found.rate, 6)
        out.rate_count = #found.rate
        out.perfmon = last(found.perfmon, 12)
        out.perfmon_count = #found.perfmon
        out.reply = last(found.reply, 8)
        return "application/json", json.encode(out)
    end


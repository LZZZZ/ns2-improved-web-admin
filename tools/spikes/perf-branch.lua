-- SPIKE 2026-09-27: what the Performance tab can rely on.
--
-- Not loadable on its own. tools/spikes/make-perf-probe.sh splices this into
-- a copy of lua/ServerWebInterface.lua, at the top of OnWebRequest, and appends
-- perf-sampler.lua (a second UpdateServer hook) at the end, so the probe runs
-- next to the shipped handlers.                      /?request=perfprobe
--
-- Questions (docs/REQUIREMENTS.md item 10):
--   1. how often Shared.GetServerPerformanceData()'s timestamp changes, and
--      GetDurationMs() per sample
--   2. whether ServerPerformanceData(), Accumulate, Copy, Clear and
--      GetIncompleteCount work from mod Lua
--   3. what the getters read with 0 players (and, driven by hand, with some)
--   4. UpdateServer calls per second against the tickrate, and which clock
--      measures a tick
--   5. what the config getters report
--   6. collectgarbage("count"), and whether io.open reaches /proc

    if actions.request == "perfprobe" then
        local P = perfProbe
        local out = { now_time = Shared.GetTime(), now_system = Shared.GetSystemTime() }
        if not P then
            out.error = "sampler not running"
            return "application/json", json.encode(out)
        end
        out.ticks = P.ticks
        out.since = P.started
        out.tick_rate_game = P.ticks / math.max(Shared.GetTime() - P.startedGame, 1e-6)
        out.tick_rate_real = P.ticks / math.max(Shared.GetSystemTimeReal() - P.startedReal, 1e-6)
        out.frame_rate = Server.GetFrameRate()
        out.worst_game_ms = P.worstGame * 1000
        out.worst_real_ms = P.worstReal * 1000
        out.intervals_game_ms = P.intervalsGame
        out.intervals_real_ms = P.intervalsReal
        out.changes = P.changes
        out.change_ticks = P.changeTicks
        out.samples = P.samples
        out.windows = P.windows
        out.errors = P.errors
        out.types = P.types
        out.lua_kb = collectgarbage("count")
        local ok, f = pcall(io.open, "/proc/self/status", "r")
        out.proc_open = { ok = ok, handle = f ~= nil, err = (not ok) and tostring(f) or nil }
        if ok and f then
            out.proc_head = f:read("*a"):sub(1, 400)
            f:close()
        end
        P.worstGame, P.worstReal = 0, 0
        return "application/json", json.encode(out)
    end


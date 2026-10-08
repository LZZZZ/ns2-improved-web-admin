

-- SPIKE 2026-09-27: the perf probe's sampler, appended by make-perf-probe.sh.
-- See perf-branch.lua for the questions.

local kProbeGetters = {
    "GetScore", "GetQuality", "GetTimestamp", "GetMoverate", "GetInterpMs",
    "GetTickrate", "GetSendrate", "GetMaxPlayers", "GetDurationMs",
    "GetNumPlayers", "GetUpdateIntervalMs", "GetNumEntitiesUpdated",
    "GetTimeSpentOnUpdate", "GetMovesProcessed", "GetTimeSpentOnMoves",
    "GetTimeSpentIdling", "GetTimeOverdraft", "GetNumInterpWarns",
    "GetNumInterpFails", "GetEntityCount", "GetIncompleteCount",
}

-- The first boot died with SIGFPE on the first sample, so each getter is
-- named in the log before it is called, for the first few reads: the last
-- name logged before a crash is the getter that divides by zero. Getters
-- listed in perfProbeSkip are not called at all while the sample is empty.
perfProbeSkip = perfProbeSkip or { }
perfProbeGuard = true
local probeLogReads = 4

local function ProbeRead(data, errors)
    local row = { }
    local logging = probeLogReads > 0
    probeLogReads = probeLogReads - 1
    local empty = data:GetDurationMs() <= 0
    if logging then Log("[perf-probe] read, duration %s", data:GetDurationMs()) end
    for _, name in ipairs(kProbeGetters) do
      if empty and perfProbeSkip[name] then
        row[name] = "skipped (empty)"
      else
        if logging then Log("[perf-probe] calling %s", name) end
        local ok, v = pcall(function() return data[name](data) end)
        if ok then row[name] = v else errors[name] = tostring(v) end
        if logging then Log("[perf-probe] %s = %s", name, tostring(v)) end
      end
    end
    return row
end

local function ProbeKeep(list, item, cap)
    table.insert(list, item)
    if #list > cap then table.remove(list, 1) end
end

local function ProbeUpdate()
    local P = perfProbe
    local nowGame, nowReal = Shared.GetTime(), Shared.GetSystemTimeReal()
    if not P then
        P = {
            ticks = 0, started = Shared.GetSystemTime(),
            startedGame = nowGame, startedReal = nowReal,
            lastGame = nowGame, lastReal = nowReal,
            worstGame = 0, worstReal = 0,
            intervalsGame = { }, intervalsReal = { },
            changes = { }, changeTicks = { }, ticksAtChange = 0,
            samples = { }, windows = { }, errors = { }, types = { },
            lastStamp = nil,
        }
        local ok, acc = pcall(ServerPerformanceData)
        P.types.constructor = ok and type(acc) or ("error: " .. tostring(acc))
        if ok then P.acc = acc end
        perfProbe = P
        return
    end

    P.ticks = P.ticks + 1
    local dGame, dReal = nowGame - P.lastGame, nowReal - P.lastReal
    P.lastGame, P.lastReal = nowGame, nowReal
    if dGame > P.worstGame then P.worstGame = dGame end
    if dReal > P.worstReal then P.worstReal = dReal end
    ProbeKeep(P.intervalsGame, dGame * 1000, 20)
    ProbeKeep(P.intervalsReal, dReal * 1000, 20)

    local ok, data = pcall(Shared.GetServerPerformanceData)
    if not ok then P.errors.get = tostring(data) return end
    P.types.data = type(data)
    local stamp = data:GetTimestamp()
    if stamp == P.lastStamp then return end
    if P.lastStamp then
        ProbeKeep(P.changes, stamp - P.lastStamp, 20)
        ProbeKeep(P.changeTicks, P.ticks - P.ticksAtChange, 20)
    end
    P.lastStamp = stamp
    P.ticksAtChange = P.ticks

    local row = ProbeRead(data, P.errors)
    row.system = Shared.GetSystemTime()
    ProbeKeep(P.samples, row, 15)

    if P.acc then
        -- Accumulating an empty sample is left in on purpose for one boot, with
        -- a log line either side (perfProbeGuard off), to confirm it is the
        -- SIGFPE; vanilla LogPerformance only accumulates when duration > 0.
        if perfProbeGuard and data:GetDurationMs() <= 0 then return end
        local logAcc = (P.accLogged or 0) < 3
        P.accLogged = (P.accLogged or 0) + 1
        if logAcc then Log("[perf-probe] accumulate, sample duration %s, acc duration %s", data:GetDurationMs(), P.acc:GetDurationMs()) end
        local okAcc, err = pcall(function() P.acc:Accumulate(data) end)
        if logAcc then Log("[perf-probe] accumulated, acc duration %s", P.acc:GetDurationMs()) end
        if not okAcc then P.errors.accumulate = tostring(err) return end
        if P.acc:GetDurationMs() >= 10000 then
            local w = ProbeRead(P.acc, P.errors)
            w.system = Shared.GetSystemTime()
            local copy = ServerPerformanceData()
            local okCopy, errCopy = pcall(function() copy:Copy(P.acc) end)
            w.copy_duration = okCopy and copy:GetDurationMs() or ("error: " .. tostring(errCopy))
            ProbeKeep(P.windows, w, 12)
            local okClear, errClear = pcall(function() P.acc:Clear() end)
            if not okClear then P.errors.clear = tostring(errClear) end
            w.after_clear = P.acc:GetDurationMs()
        end
    end
end

Event.Hook("UpdateServer", ProbeUpdate)

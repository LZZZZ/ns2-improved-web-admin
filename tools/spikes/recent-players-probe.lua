-- ======= Copyright (c) 2012, Unknown Worlds Entertainment, Inc. All rights reserved. ==========
--
-- lua\ServerWebInterface.lua
--
--    Created by:   Brian Cronin (brianc@unknownworlds.com)
--    Modified by:  LZZ (lzz@lzzbr.com)
--
-- ========= For more information, visit us at http://www.unknownworlds.com =====================

-- The server side of the web admin panel in web/.

Script.Load("lua/RingBuffer.lua")

-- recent-players probe ------------------------------------------------------
function ProbeLog(fmt, ...)
    Shared.Message("[recent-probe] " .. string.format(fmt, ...))
end
ProbeClock = Shared.GetSystemTimeReal or os.clock
ProbeLog("file load: system time %s, clock %s", tostring(Shared.GetSystemTime()),
         Shared.GetSystemTimeReal and "Shared.GetSystemTimeReal" or "os.clock")
do
    local ok, f = pcall(io.open, "config://webadmin/recent-players.json", "r")
    ProbeLog("Q4 read at file load: pcall %s, handle %s", tostring(ok), tostring(f))
    if ok and f then f:close() end
end
do
    local ok, value, pos, err = pcall(function() return json.decode('{"version":1,"players":') end)
    ProbeLog("Q3 json.decode on truncated input: pcall ok=%s, value=%s, 2nd=%s, 3rd=%s",
             tostring(ok), tostring(value), tostring(pos), tostring(err))
end
-- ---------------------------------------------------------------------------

-- Printed by every admin command before it runs (core/lua/ServerAdmin.lua).
local kAuditPattern = "^sv %- .- %- %d+: : .-: (%S+)"

-- Shine replaces ServerAdminPrint with one that prints nothing without a
-- client, so sv_ commands run from here returned no output. This puts the
-- nil-client branch back over whatever is current.
local ourServerAdminPrint

local function EnsureServerAdminPrintWrapped()

    local current = ServerAdminPrint
    if current == ourServerAdminPrint then return end

    ourServerAdminPrint = function(client, message, ...)
        if client == nil then
            Shared.Message(tostring(message))
            return
        end
        return current(client, message, ...)
    end
    ServerAdminPrint = ourServerAdminPrint

end

-- A command's output as lines. Script lines carry the log's "[hh:mm:ss]".
local function CapturedLines(text)

    local lines = { }
    local now = Shared.GetSystemTime()
    for line in string.gmatch(text, "[^\n]+") do
        line = string.gsub(string.gsub(line, "\r$", ""), "^%[%d%d:%d%d:%d%d%]", "")
        table.insert(lines, {
            id = #lines + 1,
            time = now,
            src = string.match(line, kAuditPattern) and "audit" or "server",
            text = line,
        })
    end
    return lines

end

-- Shine plugins that replace vanilla behaviour; basecommands holds sh_gag.
-- Shine loads after this file, so lookups happen per request.
local kShinePlugins = { "ban", "reservedslots", "mapvote", "basecommands" }

local function GetShinePlugin(name)

    if type(Shine) ~= "table" or type(Shine.IsExtensionEnabled) ~= "function" then
        return nil
    end

    local ok, enabled, plugin = pcall(Shine.IsExtensionEnabled, Shine, name)
    if ok and enabled and type(plugin) == "table" then
        return plugin
    end
    return nil

end

local function GetShineState()

    if type(Shine) ~= "table" then
        return nil
    end

    local state = { }
    for _, name in ipairs(kShinePlugins) do
        state[name] = GetShinePlugin(name) ~= nil
    end
    return state

end

-- An expiry further out than this means permanent (Shine stores e.g. 6e+24).
local kPermanentAfter = 100 * 365 * 24 * 60 * 60

-- The bans in force, newest first. Shine's table keeps issuer and issue time,
-- which GetBannedPlayersList() drops.
local function GetBansInForce()

    local now = Shared.GetSystemTime()
    local bans = { }

    local function Add(ban, expiry)
        expiry = tonumber(expiry) or 0
        if expiry ~= 0 and expiry <= now then
            return
        end
        ban.permanent = expiry == 0 or expiry - now > kPermanentAfter
        if not ban.permanent then
            ban.expires = expiry
        end
        table.insert(bans, ban)
    end

    local plugin = GetShinePlugin("ban")
    local shineBans = plugin and type(plugin.Config) == "table" and plugin.Config.Banned

    if type(shineBans) == "table" then

        for id, data in pairs(shineBans) do
            Add({
                id = tonumber(id) or id,
                name = tostring(data.Name or ""),
                reason = tostring(data.Reason or ""),
                issued = tonumber(data.Issued),
                banned_by = data.BannedBy and tostring(data.BannedBy) or nil,
            }, data.UnbanTime)
        end

        table.sort(bans, function(a, b)
            local x, y = a.issued or 0, b.issued or 0
            if x ~= y then return x > y end
            return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
        end)

        return "shine", now, bans

    end

    -- Vanilla appends, so the list is oldest first.
    local list = GetBannedPlayersList()
    for i = #list, 1, -1 do
        local ban = list[i]
        Add({
            id = tonumber(ban.id) or ban.id,
            name = tostring(ban.name or ""),
            reason = tostring(ban.reason or ""),
        }, ban.time)
    end

    return "vanilla", now, bans

end

-- Recent players: seen in the last 24 h, at most 100, saved under config://
-- to survive map changes. A torn save starts the list empty.
local kRecentWindow = 24 * 60 * 60
local kRecentCapacity = 100
local kRecentFormerNames = 5
local kRecentSweepSeconds = 10
local kRecentSaveSeconds = 60
local kRecentFileVersion = 1
local kRecentFile = "config://webadmin/recent-players.json"

-- Account id -> entry, as saved.
local recentPlayers = { }
-- Account id -> the time `played` was last updated to, for connected players.
local recentAccrued = { }
-- nil until loaded, then "ok", "empty" (no file) or "unreadable".
local recentLoadStatus
local recentDirty = false
local recentUrgent = false
local recentSaveError
local lastRecentSweep = 0
local lastRecentSave = 0

local function SanitizeRecentEntry(raw)

    if type(raw) ~= "table" then return nil end

    local id = tonumber(raw.steamid)
    local lastSeen = tonumber(raw.last_seen)
    if not id or id <= 0 or id ~= math.floor(id) or not lastSeen then
        return nil
    end

    local names = { }
    if type(raw.names) == "table" then
        for _, name in ipairs(raw.names) do
            if type(name) == "string" and #names < kRecentFormerNames then
                table.insert(names, name)
            end
        end
    end

    return {
        steamid = id,
        name = type(raw.name) == "string" and raw.name or "",
        names = names,
        ipaddress = type(raw.ipaddress) == "string" and raw.ipaddress or "",
        first_seen = tonumber(raw.first_seen) or lastSeen,
        last_seen = lastSeen,
        played = math.max(0, tonumber(raw.played) or 0),
    }

end

local function EnsureRecentLoaded()

    if recentLoadStatus then return end

    local file = io.open(kRecentFile, "r")
    if not file then
        recentLoadStatus = "empty"
        return
    end

    local text = file:read("*a")
    file:close()

    local ok, data = pcall(json.decode, text or "")
    if not (ok and type(data) == "table" and data.version == kRecentFileVersion
            and type(data.players) == "table") then
        recentLoadStatus = "unreadable"
        return
    end

    for _, raw in ipairs(data.players) do
        local entry = SanitizeRecentEntry(raw)
        if entry then
            recentPlayers[entry.steamid] = entry
        end
    end
    recentLoadStatus = "ok"

end

-- Connected humans, by account id.
local function GetConnectedClients()

    local connected = { }
    for _, player in ientitylist(Shared.GetEntitiesWithClassname("Player")) do
        local client = Server.GetOwner(player)
        if client and not client:GetIsVirtual() then
            connected[client:GetUserId()] = { client = client, player = player }
        end
    end
    return connected

end

local function ClientAddress(client)
    local address = Server.GetClientAddress(client)
    return address and IPAddressToString(address) or ""
end

-- Drops entries past the window, then the oldest past capacity. Connected
-- players are always kept.
local function PruneRecent(now, connected)

    local kept = { }
    for id, entry in pairs(recentPlayers) do
        if connected[id] or now - entry.last_seen <= kRecentWindow then
            table.insert(kept, entry)
        end
    end

    table.sort(kept, function(a, b)
        local x, y = connected[a.steamid] ~= nil, connected[b.steamid] ~= nil
        if x ~= y then return x end
        if a.last_seen ~= b.last_seen then return a.last_seen > b.last_seen end
        return a.steamid < b.steamid
    end)

    recentPlayers = { }
    for i, entry in ipairs(kept) do
        if i > kRecentCapacity and not connected[entry.steamid] then
            break
        end
        recentPlayers[entry.steamid] = entry
    end

end

local function RecentEntry(id, now)

    local entry = recentPlayers[id]
    if not entry then
        entry = {
            steamid = id, name = "", names = { }, ipaddress = "",
            first_seen = now, last_seen = now, played = 0,
        }
        recentPlayers[id] = entry
    end
    return entry

end

-- GetName() returns kDefaultPlayerName before a name is set; that never
-- replaces a real name or becomes a former one.
local function SetRecentName(entry, name)

    if type(name) ~= "string" or name == "" or name == entry.name then return end
    if name == kDefaultPlayerName and entry.name ~= "" then return end

    if entry.name ~= "" and entry.name ~= kDefaultPlayerName then
        for i = #entry.names, 1, -1 do
            if entry.names[i] == entry.name or entry.names[i] == name then
                table.remove(entry.names, i)
            end
        end
        table.insert(entry.names, 1, entry.name)
        while #entry.names > kRecentFormerNames do
            table.remove(entry.names)
        end
    end

    entry.name = name
    recentDirty = true

end

local function AccrueRecent(id, now)

    local entry = recentPlayers[id]
    local since = recentAccrued[id]
    if entry and since then
        entry.played = entry.played + math.max(0, now - since)
    end
    recentAccrued[id] = now

end

local function SaveRecent(now)

    local list = { }
    for _, entry in pairs(recentPlayers) do
        table.insert(list, entry)
    end

    local probeStart = ProbeClock()
    local ok, err = pcall(function()
        local file, openError = io.open(kRecentFile, "w")
        if not file then
            error(openError or ("cannot open " .. kRecentFile), 0)
        end
        file:write(Shared.JsonEncode({
            version = kRecentFileVersion, players = list,
        }))
        file:close()
    end)

    ProbeLog("Q5 save: %d players, ok=%s, %.3f ms, %s", #list, tostring(ok),
             (ProbeClock() - probeStart) * 1000, tostring(err))
    lastRecentSave = now
    recentDirty = false
    recentUrgent = false
    recentSaveError = not ok and tostring(err) or nil

end

Event.Hook("ClientConnect", function(client)

    if not client or client:GetIsVirtual() then return end
    EnsureRecentLoaded()

    local now = Shared.GetSystemTime()
    local entry = RecentEntry(client:GetUserId(), now)
    local address = ClientAddress(client)
    if address ~= "" then
        entry.ipaddress = address
    end
    entry.last_seen = now

    local player = client:GetControllingPlayer()
    if player then
        SetRecentName(entry, player:GetName())
    end

    recentAccrued[entry.steamid] = now
    recentDirty = true

end)

Event.Hook("ClientDisconnect", function(client)

    if not client or client:GetIsVirtual() then return end
    EnsureRecentLoaded()

    local now = Shared.GetSystemTime()
    local id = client:GetUserId()
    if recentPlayers[id] then
        AccrueRecent(id, now)
        recentPlayers[id].last_seen = now
    end
    recentAccrued[id] = nil

    -- Saved on the next tick, so a mass disconnect costs one write.
    recentDirty = true
    recentUrgent = true

end)

local function UpdateRecentPlayers()

    local now = Shared.GetSystemTime()
    if not recentUrgent and now - lastRecentSweep < kRecentSweepSeconds then
        return
    end
    lastRecentSweep = now
    EnsureRecentLoaded()

    local connected = GetConnectedClients()
    for id, live in pairs(connected) do
        local entry = RecentEntry(id, now)
        SetRecentName(entry, live.player:GetName())
        if entry.ipaddress == "" then
            entry.ipaddress = ClientAddress(live.client)
        end
        AccrueRecent(id, now)
        entry.last_seen = now
        recentDirty = true
    end

    if recentUrgent or (recentDirty and now - lastRecentSave >= kRecentSaveSeconds) then
        PruneRecent(now, connected)
        SaveRecent(now)
    end

end

local function GetRecentPlayers()

    EnsureRecentLoaded()

    local now = Shared.GetSystemTime()
    local connected = GetConnectedClients()
    PruneRecent(now, connected)

    local players = { }
    for id, entry in pairs(recentPlayers) do
        local since = recentAccrued[id]
        table.insert(players, {
            steamid = entry.steamid,
            name = entry.name,
            names = entry.names,
            ipaddress = entry.ipaddress,
            first_seen = entry.first_seen,
            -- Connected: seen now, and played up to now.
            last_seen = connected[id] and now or entry.last_seen,
            played = entry.played + ((connected[id] and since) and math.max(0, now - since) or 0),
            connected = connected[id] ~= nil,
        })
    end

    table.sort(players, function(a, b)
        if a.last_seen ~= b.last_seen then return a.last_seen > b.last_seen end
        return a.steamid < b.steamid
    end)

    return {
        now = now,
        window = kRecentWindow,
        capacity = kRecentCapacity,
        storage = {
            loaded = recentLoadStatus,
            error = recentSaveError,
        },
        players = players,
    }

end

-- Shine's sh_banid names an absent player "<unknown>"; use the name from
-- recent players instead. Shine can re-create the plugin, so this re-applies.
local kShineUnknownName = "<unknown>"
local shineAddBanWrappers = setmetatable({ }, { __mode = "k" })

local function EnsureShineAddBanWrapped()

    local plugin = GetShinePlugin("ban")
    if not plugin or type(plugin.AddBan) ~= "function"
            or plugin.AddBan == shineAddBanWrappers[plugin] then
        return
    end

    local original = plugin.AddBan
    local wrapper = function(self, id, name, ...)

        if name == kShineUnknownName then
            EnsureRecentLoaded()
            local entry = recentPlayers[tonumber(id)]
            if entry and entry.name ~= "" and entry.name ~= kDefaultPlayerName then
                name = entry.name
                Shared.Message(string.format('Named the ban of %s "%s", from recent players.',
                                             tostring(id), name))
            end
        end

        return original(self, id, name, ...)

    end

    shineAddBanWrappers[plugin] = wrapper
    plugin.AddBan = wrapper

end

-- getperf: the engine's ServerPerformanceData samples (about one a second),
-- accumulated into kPerfWindowSeconds windows. The ring and its ids restart
-- with the map; `loaded_at` tells clients.
local kPerfWindowSeconds = 10
local kMaxPerfWindows = 360   -- an hour
local perfWindows = CreateRingBuffer(kMaxPerfWindows)
local nextPerfWindowId = 1
local perfLoadedAt = Shared.GetSystemTime()
local perfAcc = nil           -- ServerPerformanceData, made on first use
local perfLastStamp = nil
local perfTicks = 0
local perfWorstTick = 0
local perfWindowStart = nil   -- Shared.GetSystemTimeReal() at the window's start
local perfLastTick = nil

local function PerfRound(v, places)
    local m = 10 ^ (places or 1)
    return math.floor(v * m + 0.5) / m
end

-- One closed window: ServerPerformanceData.DetailText's figures.
local function PerfWindowFromAcc(acc, ticks, elapsed, worstTick)
    local durationMs = acc:GetDurationMs()
    return {
        id = nextPerfWindowId,
        time = Shared.GetSystemTime(),
        tickrate = PerfRound(elapsed > 0 and ticks / elapsed or 0, 2),
        worst_tick_ms = PerfRound(worstTick * 1000, 1),
        players = acc:GetNumPlayers(),
        -- 0 with nobody on the server.
        score = acc:GetScore(),
        idle_pct = PerfRound(100 * acc:GetTimeSpentIdling() / durationMs),
        moves_pct = PerfRound(100 * acc:GetTimeSpentOnMoves() / durationMs),
        entities_pct = PerfRound(100 * acc:GetTimeSpentOnUpdate() / durationMs),
        entities = acc:GetEntityCount(),
        -- Counts over the window; perfmon prints them per second.
        interp_warns = acc:GetNumInterpWarns(),
        interp_fails = acc:GetNumInterpFails(),
        lua_kb = math.floor(collectgarbage("count")),
    }
end

local function UpdatePerfWindows()

    -- Ticks are counted here: GetUpdateIntervalMs() is whole milliseconds.
    local now = Shared.GetSystemTimeReal()
    if perfLastTick then
        local interval = now - perfLastTick
        if interval > perfWorstTick then perfWorstTick = interval end
    end
    perfLastTick = now
    perfTicks = perfTicks + 1

    local data = Shared.GetServerPerformanceData()
    local stamp = data:GetTimestamp()
    if stamp == perfLastStamp then return end
    perfLastStamp = stamp

    -- Accumulate() of an empty sample (as after a map load) crashes the
    -- server with SIGFPE, which pcall cannot catch.
    if data:GetDurationMs() <= 0 then return end

    if not perfAcc then
        perfAcc = ServerPerformanceData()
        -- Start here, so the tick count and the samples cover the same span.
        perfWindowStart, perfTicks, perfWorstTick = now, 0, 0
        return
    end

    perfAcc:Accumulate(data)
    if perfAcc:GetDurationMs() >= kPerfWindowSeconds * 1000 then
        perfWindows:Insert(PerfWindowFromAcc(perfAcc, perfTicks, now - perfWindowStart, perfWorstTick))
        nextPerfWindowId = nextPerfWindowId + 1
        perfAcc:Clear()
        perfWindowStart, perfTicks, perfWorstTick = now, 0, 0
    end

end

-- Most records per getperf reply; the client pages with `more`. An hour in
-- one reply took 8.4 ms to encode, 60 take 1.4 ms.
local kPerfReplyMax = 60

-- The windows after `sinceId`, the next cursor, and whether more are held.
local function PerfWindowsSince(sinceId)
    local windows = { }
    for _, w in ipairs(perfWindows:ToTable()) do
        if w.id > sinceId then
            if #windows == kPerfReplyMax then
                return windows, windows[#windows].id, true
            end
            table.insert(windows, w)
        end
    end
    return windows, nextPerfWindowId - 1, false
end

-- The rates the server runs at now. nil until the engine's first sample.
local function PerfConfig()
    local data = Shared.GetServerPerformanceData()
    if data:GetTickrate() <= 0 then return nil end
    return {
        tickrate = data:GetTickrate(),
        moverate = data:GetMoverate(),
        sendrate = data:GetSendrate(),
        interp_ms = data:GetInterpMs(),
        max_players = data:GetMaxPlayers(),
        bw_limit = Server.GetBwLimit(),
    }
end

-- getlog: the server's log by byte offset, at most 64 KB a reply (256 KB took
-- 4.4 ms to encode). The header's Date and Time identify the file: a
-- different file, or one shorter than the cursor, gets a fresh tail marked
-- `reset`.
local kLogTailBytes = 64 * 1024
local kLogMaxBytes = 64 * 1024

-- Bytes [from, to) of the log.
local function LogRead(from, to)
    if to <= from then return "" end
    return (Shared.ReadLog(from, to - from))
end

local function LogSize()
    local _, size = Shared.ReadLog(-1, 1)
    return size
end

-- "09/28/2026 02:50:11 AM" from the header, or "" for a file without one.
local function LogFileId()
    local date, time = string.match(LogRead(0, 128), "^Date: ([^\r\n]*)\r?\nTime: ([^\r\n]-):?\r?\n")
    return date and (date .. " " .. time) or ""
end

-- The complete lines in `text`, which starts at byte `from`, and where the
-- next read starts: a last line with no newline is left for it.
local function LogLines(text, from)
    local lines = { }
    local pos = 1
    while true do
        local nl = string.find(text, "\n", pos, true)
        if not nl then break end
        local line = string.sub(text, pos, nl - 1)
        if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
        table.insert(lines, { off = from + pos - 1, text = line })
        pos = nl + 1
    end
    return lines, from + pos - 1
end

-- `text`, read from byte `from`, cut to its first line start. nil when none.
local function FromLineStart(text, from)
    if from == 0 then return text, 0 end
    local nl = string.find(text, "\n", 1, true)
    if not nl then return nil end
    return string.sub(text, nl + 1), from + nl
end

local function LogTail(size)
    local start = math.max(0, size - kLogTailBytes)
    local text, from = FromLineStart(LogRead(start, size), start)
    if not text then text, from = "", size end
    local lines, to = LogLines(text, from)
    return from, to, lines, false
end

local function LogSince(size, since)
    local stop = math.min(size, since + kLogMaxBytes)
    local text = LogRead(since, stop)
    local lines, to = LogLines(text, since)
    -- A line longer than the cap would stall the cursor: serve it cut.
    if to == since and stop == since + kLogMaxBytes then
        lines, to = { { off = since, text = text } }, stop
    end
    return since, to, lines, to < size and stop < size
end

local function LogBefore(before)
    local from = math.max(0, before - kLogTailBytes)
    local raw = LogRead(from, before)
    local text, start = FromLineStart(raw, from)
    if not text then
        -- One line longer than a page: serve it cut.
        return from, before, { { off = from, text = raw } }, false
    end
    return start, before, (LogLines(text, start)), false
end

local function GetLog(actions)

    local size = LogSize()
    local fileId = LogFileId()
    local since = tonumber(actions.since)
    local before = tonumber(actions.before)
    local wanted = since or before

    local reset
    if wanted and actions.file ~= nil and actions.file ~= fileId then
        reset = "new_file"
    elseif wanted and (wanted > size or wanted < 0) then
        reset = "truncated"
    end

    local from, to, lines, more
    if since and not reset then
        from, to, lines, more = LogSince(size, math.floor(since))
    elseif before and not reset then
        from, to, lines, more = LogBefore(math.floor(before))
    else
        from, to, lines, more = LogTail(size)
    end

    return {
        file_id = fileId,
        size = size,
        from = from,
        to = to,
        lines = lines,
        more = more,
        at_start = from == 0,
        reset = reset,
    }

end

-- getperf's `engine`: tickstat windows from Server.GetTickStat(), which is
-- nil while `tickstat` is off; and, from the log, rate steps, the bwlimit
-- warning, `perfmon` blocks and `tickstat: on|off`. Log lines carry no time,
-- so each is stamped when a scan finds it. Patterns are anchored at both
-- ends, so a player name cannot fake a line.
local kTickstatPollSeconds = 1
local kEngineScanSeconds = 2
-- A scan normally meets about 1 KB; 256 KB takes 1.8 ms.
local kEngineScanMaxBytes = 256 * 1024
local kMaxTickstats = 360          -- an hour at `tickstat 10`
local kMaxPerfmonBlocks = 60
local kMaxEngineEvents = 200
local engineTickstats = CreateRingBuffer(kMaxTickstats)
local enginePerfmon = CreateRingBuffer(kMaxPerfmonBlocks)
local engineEvents = CreateRingBuffer(kMaxEngineEvents)
local nextEngineId = 1
local engineCursor = nil           -- byte offset; set by the first scan
local engineFileId = nil
local enginePartialBlock = nil     -- a perfmon block still being read
local engineLastScan = nil
local tickstatLastPoll = nil
local tickstatLastWindow = nil     -- the engine's `time` of the last window kept
local tickstatLastAt = nil
local tickstatSaid = nil           -- the last `tickstat: on|off`

-- The perfmon block, one line each; `score` closes it.
local kPerfmonLines = {
    { "^perfmon: tick jitter avg (%S+)ms max (%S+)ms %(n=(%S+)%)$",
      "jitter_avg_ms", "jitter_max_ms", "jitter_n" },
    { "^perfmon: snapshot write avg (%S+)ms max (%S+)ms %(n=(%S+)%)$",
      "snapshot_write_avg_ms", "snapshot_write_max_ms", "snapshot_write_n" },
    { "^perfmon: entities skipped (%S+) / (%S+) %((%S+)%%%)$",
      "entities_skipped", "entities_total", "entities_skipped_pct" },
    { "^perfmon: moves rejected: time credit (%S+), other (%S+)$",
      "rejected_time_credit", "rejected_other" },
    { "^perfmon: moves rewound with missing snapshots (%S+) %(since map load%)$", "rewound_missing" },
    { "^perfmon: score (%S+) = idle (%S+)%% %- delivery (%S+)%% %- overload (%S+)%% " ..
      "%(updates (%S+), warn (%S+), fail (%S+)%)$",
      "score", "idle_pct", "delivery_pct", "overload_pct", "updates", "warn", "fail" },
}

-- On a match, set the spec's fields on `into`.
local function EngineMatch(spec, text, into)
    local caps = { string.match(text, spec[1]) }
    if #caps == 0 then return false end
    for i = 2, #spec do
        into[spec[i]] = tonumber(caps[i - 1])
    end
    return true
end

local function EngineRecord(fields, now)
    fields.id = nextEngineId
    fields.time = now
    nextEngineId = nextEngineId + 1
    return fields
end

local function UpdateTickstat()

    local now = Shared.GetSystemTimeReal()
    if tickstatLastPoll and now - tickstatLastPoll < kTickstatPollSeconds then return end
    tickstatLastPoll = now

    local stat = Server.GetTickStat()
    if not stat or stat.time == tickstatLastWindow then return end
    tickstatLastWindow = stat.time

    -- Sent as the engine gives it, but `time` becomes the window's end on the
    -- system clock: the engine's is the server's. A copy, so the engine's
    -- table keeps its own `time`.
    local record = { }
    for k, v in pairs(stat) do record[k] = v end
    local at = Shared.GetSystemTime() - math.max(0, Shared.GetTime() - stat.time)
    engineTickstats:Insert(EngineRecord(record, at))
    tickstatLastAt = at

end

local function ClosePerfmonBlock()
    if enginePartialBlock then
        enginePerfmon:Insert(enginePartialBlock)
        enginePartialBlock = nil
    end
end

local function ParseEngineLine(text, now)

    if string.sub(text, 1, 9) == "perfmon: " then
        local fields = { }
        for i, spec in ipairs(kPerfmonLines) do
            if EngineMatch(spec, text, fields) then
                if i == 1 then
                    ClosePerfmonBlock()
                    enginePartialBlock = EngineRecord({ }, now)
                end
                if enginePartialBlock then
                    for k, v in pairs(fields) do enginePartialBlock[k] = v end
                    if i == #kPerfmonLines then ClosePerfmonBlock() end
                end
                return
            end
        end
        return
    end

    local client, from, to, choked, clear, bw = string.match(text,
        "^client (%d+): snapshot rate (%S+) %-> (%S+)/s %((%S+)%% choked, (%S+) ms to clear each, bwlimit (%S+)%)$")
    if client then
        engineEvents:Insert(EngineRecord({
            kind = "rate", client = tonumber(client), from_rate = tonumber(from),
            to_rate = tonumber(to), choked_pct = tonumber(choked),
            clear_ms = tonumber(clear), bwlimit = tonumber(bw) }, now))
        return
    end

    local bwlimit, sendrate, per, needed, suggested = string.match(text,
        "^bwlimit (%d+) bytes/sec at sendrate (%d+) leaves (%d+) bytes per snapshot, " ..
        "below the (%d+) a full game needs: .- bwlimit (%d+) or more avoids it%.$")
    if bwlimit then
        engineEvents:Insert(EngineRecord({
            kind = "bwlimit_low", bwlimit = tonumber(bwlimit), sendrate = tonumber(sendrate),
            per_snapshot = tonumber(per), needed = tonumber(needed),
            suggested = tonumber(suggested) }, now))
        return
    end

    local said = string.match(text, "^tickstat: (%a+)$")
    if said then
        tickstatSaid = { text = said, time = now }
    end

end

-- What the engine wrote since the last scan. The first scan after a map load
-- only sets the cursor.
local function ScanEngineLog()

    local size = LogSize()
    local fileId = LogFileId()
    if engineCursor == nil then
        engineCursor, engineFileId = size, fileId
        return
    end
    if fileId ~= engineFileId or size < engineCursor then
        -- A new file, or this one cut: all of it is new.
        engineCursor, engineFileId = 0, fileId
        enginePartialBlock = nil
    end
    if size - engineCursor > kEngineScanMaxBytes then
        -- Too far behind: only the last kEngineScanMaxBytes.
        local from = size - kEngineScanMaxBytes
        local _, start = FromLineStart(LogRead(from, size), from)
        engineCursor = start or size
    end
    local lines, to = LogLines(LogRead(engineCursor, size), engineCursor)
    local now = Shared.GetSystemTime()
    for _, line in ipairs(lines) do
        ParseEngineLine(line.text, now)
    end
    engineCursor = to

end

local function UpdateEngineLog()
    local now = Shared.GetSystemTimeReal()
    if engineLastScan and now - engineLastScan < kEngineScanSeconds then return end
    engineLastScan = now
    ScanEngineLog()
end

local function EngineSince(buffer, sinceId)
    local list = { }
    for _, r in ipairs(buffer:ToTable()) do
        if r.id > sinceId then table.insert(list, r) end
    end
    return list
end

-- Records since `sinceId`, at most kPerfReplyMax across the three lists. They
-- share one id sequence but leave their rings at different rates, so a page
-- ends at the kPerfReplyMax-th lowest id held.
local function EngineReport(sinceId)
    local report = {
        last_id = nextEngineId - 1,
        more = false,
        -- The server's clock, for judging whether tickstat is still running.
        now = Shared.GetSystemTime(),
        scan_s = kEngineScanSeconds,
        tickstat_last_at = tickstatLastAt,
        tickstat_said = tickstatSaid,
    }
    local lists = {
        EngineSince(engineTickstats, sinceId),
        EngineSince(enginePerfmon, sinceId),
        EngineSince(engineEvents, sinceId),
    }
    if #lists[1] + #lists[2] + #lists[3] > kPerfReplyMax then
        local ids = { }
        for _, list in ipairs(lists) do
            for _, r in ipairs(list) do ids[#ids + 1] = r.id end
        end
        table.sort(ids)
        local upTo = ids[kPerfReplyMax]
        for i, list in ipairs(lists) do
            local kept = { }
            for _, r in ipairs(list) do
                if r.id <= upTo then kept[#kept + 1] = r end
            end
            lists[i] = kept
        end
        report.last_id = upTo
        report.more = true
    end
    report.tickstats, report.perfmon, report.events = lists[1], lists[2], lists[3]
    return report
end

Shared.SetWebRoot("web")

-- The installed mods. `active`: mounted now, hotfix mods included.
local function GetModList()

    local active = { }
    for i = 1, Server.GetNumActiveMods() do
        active[Server.GetActiveModId(i)] = true
    end

    local returnList = { }
    for i = 1, Server.GetNumMods() do
        local id = Server.GetModId(i)
        returnList[i] = {
            id = id, name = Server.GetModTitle(i), active = active[id] == true,
            whitelisted = Server.GetIsModWhitelisted(id),
        }
    end
    return returnList

end

local function GetMapList()

    local returnList = { }
    for i = 1, Server.GetNumMaps() do
        returnList[i] = { name = Server.GetMapName(i), modId = Server.GetMapModId(i) }
    end
    return returnList

end

local function GetTeamResourceCount()

    local marineRes = 0
    local alienRes = 0

    local teamInfo = GetEntitiesForTeam("TeamInfo", 1)
    if table.icount(teamInfo) > 0 then
        marineRes = teamInfo[1]:GetTeamResources()
    end

    teamInfo = GetEntitiesForTeam("TeamInfo", 2)
    if table.icount(teamInfo) > 0 then
        alienRes = teamInfo[1]:GetTeamResources()
    end

    return marineRes, alienRes

end

-- A ScoringMixin number, or nil when the method is missing, errors or does
-- not return a number.
local function SkillOf(player, method)
    local f = player[method]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, player)
    return ok and tonumber(v) or nil
end

local function GetServerState()

    local playerRecords = Shared.GetEntitiesWithClassname("Player")

    -- Shine's gags. IsClientGagged also expires a timed gag.
    local gags = GetShinePlugin("basecommands")
    if gags and type(gags.IsClientGagged) ~= "function" then
        gags = nil
    end

    local playerList = { }
    for _, player in ientitylist(playerRecords) do

        -- nil if the player was just removed.
        local client = Server.GetOwner(player)
        if client then

            local scoring = HasMixin(player, "Scoring")
            local playerData =
            {
                name = player:GetName(),
                steamid = client:GetUserId(),
                isbot = client:GetIsVirtual() == true,
                team = player:GetTeamNumber(),
                iscomm = player:GetIsCommander(),
                score = scoring and player:GetScore() or 0,
                kills = scoring and player:GetKills() or 0,
                assists = scoring and player:GetAssistKills() or 0,
                deaths = scoring and player:GetDeaths() or 0,
                resources = player:GetResources(),
                ping = client:GetPing(),
                ipaddress = IPAddressToString(Server.GetClientAddress(client)),
                familyshared = Server.GetIsFamilyShared(client),
                -- Time-credit rejections usually mean a modified client;
                -- "other" can be a poor connection.
                moves_rejected_time = client:GetMovesRejectedTimeCredit(),
                moves_rejected_other = client:GetMovesRejectedOther(),
            }
            if playerData.familyshared then
                playerData.owner_steamid = tonumber(Server.GetOwnerUserId(client))
            end
            if gags then
                local ok, gagged = pcall(gags.IsClientGagged, gags, client)
                if ok then
                    playerData.gagged = gagged == true
                end
            end
            -- Marines play at skill + offset, aliens at skill - offset.
            local skill = SkillOf(player, "GetPlayerSkill")
            if skill then
                playerData.skill = skill
                playerData.skill_offset = SkillOf(player, "GetPlayerSkillOffset")
                playerData.comm_skill = SkillOf(player, "GetCommanderSkill")
                playerData.comm_skill_offset = SkillOf(player, "GetCommanderSkillOffset")
                -- -1 bot, -2 no skill, 0 rookie, 1-7. GetSkillTier() caches
                -- its first answer for the map; keep that cache as it was.
                local kept = player.skillTier
                playerData.skill_tier = SkillOf(player, "GetSkillTier")
                player.skillTier = kept
            end
            table.insert(playerList, playerData)

        end

    end

    local marineRes, alienRes = GetTeamResourceCount()
    local gamestarted = GetGamerules():GetGameStarted()
    local gametime = gamestarted and math.floor(Shared.GetTime() - GetGamerules():GetGameStartTime()) or 0

    return
    {
        cheats  = Shared.GetCheatsEnabled() == true,
        devmode = Shared.GetDevMode() == true,
        map = tostring(Shared.GetMapName()),
        players_online = playerRecords:GetSize(),
        marines = GetGamerules():GetTeam1():GetNumPlayers(),
        aliens = GetGamerules():GetTeam2():GetNumPlayers(),
        uptime = math.floor(Shared.GetTime()),
        player_list = playerList,
        marine_res = marineRes,
        alien_res = alienRes,
        server_name = Server.GetName(),
        frame_rate = Server.GetFrameRate(),
        game_started = gamestarted,
        game_time = gametime,
        -- Upper bound for the reserved slot amount.
        max_players = Server.GetMaxPlayers(),
        -- The Lua VM is rebuilt at a map change.
        map_loaded_at = perfLoadedAt,
        -- One condition is that every mounted mod is whitelisted.
        ranking_active = Server.GetIsRankingActive(),
        -- Absent without Shine.
        shine = GetShineState()
    }

end

local function ModsIdsToHex(t)
    if t.mods then
        for i, mod in ipairs(t.mods) do
            if type(mod) ~= "string" then
                t.mods[i] = string.format("%x", mod)
            end
        end
    end
end

local function ModIdsFromHex(t)
    if t.mods then
        for i, mod in ipairs(t.mods) do
            if type(mod) == "string" and not string.find(mod, ":") then
                local value = tonumber64("0x"..mod)

                if value then
                    t.mods[i] = value
                else
                    Log("Failed to convert mod id string %s", mod)
                end
            end
        end
    end
end

local kMapCycleFile = "config://MapCycle.json"

-- table.copyDict (Table.lua) returns the original, not a copy. The metatable
-- is kept: dkjson uses it to tell an empty object from an empty array.
local function DeepCopy(value)

    if type(value) ~= "table" then
        return value
    end
    local copy = { }
    for k, v in pairs(value) do
        copy[k] = DeepCopy(v)
    end
    return setmetatable(copy, getmetatable(value))

end

-- MapCycle.json, which rotation reads, rather than the copy loaded with the
-- map; LoadConfigFile would log a line per call. nil unless it is a cycle.
local function ReadMapCycleFile()

    local file = io.open(kMapCycleFile, "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()

    local ok, cycle = pcall(json.decode, text)
    if ok and type(cycle) == "table" and type(cycle.maps) == "table" then
        return cycle
    end
    return nil

end

-- Mod ids go out as hex: JSON has no 64-bit integers.
local function MapCycleForClient(cycle)

    ModsIdsToHex(cycle)
    for _, map in ipairs(cycle.maps) do
        if type(map) == "table" then
            ModsIdsToHex(map)
        end
    end
    return cycle

end

local function CheckModIds(mods, where)

    if mods == nil then
        return nil
    end
    if type(mods) ~= "table" then
        return where .. " must be a list"
    end
    for i, mod in ipairs(mods) do
        if type(mod) == "string" then
            -- A `:` marks a non-workshop source, passed through as is.
            if not string.find(mod, ":")
                and not (string.find(mod, "^%x+$") and tonumber64("0x" .. mod)) then
                return string.format("%s[%d] is not a hex mod id: %s", where, i, mod)
            end
        elseif type(mod) ~= "number" then
            return string.format("%s[%d] is not a mod id", where, i)
        end
    end
    return nil

end

-- Why the game could not use this cycle, or nil.
local function CheckMapCycle(cycle)

    if type(cycle) ~= "table" then
        return "not a JSON object"
    end
    if type(cycle.maps) ~= "table" or #cycle.maps == 0 then
        return "`maps` must be a list with at least one map"
    end
    for i, entry in ipairs(cycle.maps) do
        if type(entry) == "table" then
            if type(entry.map) ~= "string" or entry.map == "" then
                return string.format("maps[%d] has no map name", i)
            end
            local err = CheckModIds(entry.mods, string.format("maps[%d].mods", i))
            if err then
                return err
            end
        elseif type(entry) ~= "string" or entry == "" then
            return string.format("maps[%d] is not a map name", i)
        end
    end
    if cycle.time ~= nil and (type(cycle.time) ~= "number" or cycle.time < 0) then
        return "`time` must be a number of minutes, 0 or more"
    end
    if cycle.mode ~= nil and cycle.mode ~= "order" and cycle.mode ~= "random" then
        return "`mode` must be \"order\" or \"random\""
    end
    return CheckModIds(cycle.mods, "mods")

end

-- Shine's mapvote. It reads the cycle at plugin start, so a cycle edit
-- reaches the vote at the next map.
local function GetMapVote()

    local plugin = GetShinePlugin("mapvote")
    if not plugin then
        return { enabled = false }
    end

    local config = type(plugin.Config) == "table" and plugin.Config or { }

    local nextMap
    if type(plugin.GetNextMap) == "function" then
        local ok, result = pcall(plugin.GetNextMap, plugin)
        if ok and type(result) == "string" then
            nextMap = result
        end
    end

    local options = { }
    if type(plugin.MapChoices) == "table" then
        for _, choice in ipairs(plugin.MapChoices) do
            local name = type(choice) == "table" and choice.map or choice
            if type(name) == "string" then
                table.insert(options, name)
            end
        end
    end

    return {
        enabled = true,
        maps_from_cycle = config.GetMapsFromMapCycle == true,
        -- The plugin's value can differ from its config per map.
        round_limit = tonumber(plugin.RoundLimit) or tonumber(config.RoundLimit) or 0,
        next_map = nextMap,
        options = options,
    }

end

-- Workshop search. Server.SearchWorshop returns at most 50 results and
-- ignores the page, so only the first is asked for. Its callback gets an
-- empty table both for no matches and for a failed search, so an empty
-- result is not reported as an error.
local kWorkshopLimit = 50
local kWorkshopTimeout = 30         -- seconds before a search is given up
local kWorkshopCacheSeconds = 60

-- By search text: running ({ started, generation }) or done
-- ({ cached_at, result }, the reply already encoded).
local workshopSearches = { }
local workshopGeneration = 0

local function SearchWorkshop(searchtext)

    local now = Shared.GetTime()
    for key, entry in pairs(workshopSearches) do
        if entry.cached_at and now - entry.cached_at >= kWorkshopCacheSeconds then
            workshopSearches[key] = nil
        end
    end

    local entry = workshopSearches[searchtext]
    if entry then
        if entry.cached_at then
            return entry.result
        end
        if now - entry.started < kWorkshopTimeout then
            return Shared.JsonEncode({ loading = true, elapsed = now - entry.started })
        end
        -- Reported once; the next request starts a fresh search.
        workshopSearches[searchtext] = nil
        return Shared.JsonEncode({
            items = { },
            error = string.format("The workshop search had no answer after %d s.",
                                  kWorkshopTimeout),
        })
    end

    workshopGeneration = workshopGeneration + 1
    local generation = workshopGeneration
    workshopSearches[searchtext] = { started = now, generation = generation }

    Server.SearchWorshop(searchtext, 1, function(results)

        -- Ignore a search that was given up on and restarted.
        local current = workshopSearches[searchtext]
        if not current or current.generation ~= generation then
            return
        end

        local items = { }
        if type(results) == "table" then
            for _, mod in ipairs(results) do
                if type(mod) == "table" and type(mod.id) == "number" then
                    mod.whitelisted = Server.GetIsModWhitelisted(mod.id)
                    mod.id = string.format("%x", mod.id)
                    table.insert(items, mod)
                end
            end
        end

        workshopSearches[searchtext] = {
            cached_at = Shared.GetTime(),
            result = Shared.JsonEncode({
                items = items,
                -- There may be more matches than the engine returns.
                capped = #items >= kWorkshopLimit,
            }),
        }

    end)

    return Shared.JsonEncode({ loading = true, elapsed = 0 })

end

-- Server.InstallMod returns nothing and silently drops or misreads bad ids
-- (`-5` becomes 18446744073709551611), so only plain hex ids are passed on.
-- Whether the download worked shows later in getinstalledmodslist.
local function InstallMod(modid)

    if type(modid) ~= "string" or not string.find(modid, "^%x+$") or #modid > 16 then
        return { ok = false, error = "Not a hex workshop id: "
                 .. string.sub(tostring(modid), 1, 40) }
    end
    local id = string.gsub(string.lower(modid), "^0+", "")
    if id == "" then
        return { ok = false, error = "0 is not a workshop id." }
    end

    local installed = false
    for i = 1, Server.GetNumMods() do
        if Server.GetModId(i) == id then
            installed = true
            break
        end
    end

    Server.InstallMod(id)
    return { ok = true, id = id, already_installed = installed }

end

-- If web/index.html cannot be read. Lua cannot redirect, hence the refresh.
local kRootPage = [[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=/index.html">
<title>NS2 web admin</title>
</head>
<body>
<p>The web admin panel is at <a href="/index.html">/index.html</a>.</p>
</body>
</html>
]]

-- Handlers by `request`. Each returns a table to send as JSON, or the content
-- type and body itself.
local kRequests = { }

function kRequests.runcommand(actions)
    local command = tostring(actions.cmd or "")
    local lines = CapturedLines(Shared.CaptureConsoleCommand(command))
    local dispatched = false
    for _, line in ipairs(lines) do
        if line.src == "audit" then dispatched = true end
    end
    return {
        cmd = command,
        -- False for a plain console command and for no such command alike:
        -- the server cannot tell them apart.
        dispatched = dispatched,
        lines = lines,
    }
end

function kRequests.getbans()
    local source, now, bans = GetBansInForce()
    -- `now` is the server's clock, for computing time left.
    return { source = source, now = now, bans = bans }
end

kRequests.getrecentplayers = GetRecentPlayers
kRequests.getlog = GetLog
kRequests.getinstalledmodslist = GetModList
kRequests.getmaplist = GetMapList
kRequests.getmapvote = GetMapVote

function kRequests.getreservedslots()
    -- Under Shine's reservedslots plugin, Shine's count is what is enforced.
    local data = GetReservedSlotData()
    local plugin = GetShinePlugin("reservedslots")
    if plugin and type(plugin.Config) == "table" then
        data.shine = { slots = tonumber(plugin.Config.Slots) or 0 }
    end
    return data
end

function kRequests.getperf(actions)
    local windows, lastId, more = PerfWindowsSince(tonumber(actions.since) or 0)
    return {
        engine = EngineReport(tonumber(actions.esince) or 0),
        window_s = kPerfWindowSeconds,
        capacity = kMaxPerfWindows,
        loaded_at = perfLoadedAt,
        map = Shared.GetMapName(),
        config = PerfConfig(),
        windows = windows,
        last_id = lastId,
        more = more,
    }
end

function kRequests.getchatlist(actions)
    local all = Server.recentChatMessages:ToTable()
    local since = tonumber(actions.since) or 0
    local entries = { }
    for _, entry in ipairs(all) do
        if entry.id > since then table.insert(entries, entry) end
    end
    return {
        entries = entries,
        last_id = #all > 0 and all[#all].id or 0,
        -- Messages pushed out of the ring.
        dropped = #all > 0 and all[1].id - 1 or 0,
        buffer_size = Server.recentChatMessages.size,
    }
end

function kRequests.getmapcycle()
    return MapCycleForClient(ReadMapCycleFile() or DeepCopy(MapCycle_GetMapCycle()))
end

-- Refuses a cycle the game cannot use, and replies with what the file holds
-- afterwards.
function kRequests.setmapcycle(actions)
    local ok, mapcycle = pcall(json.decode, actions.data or "")
    local problem = (not ok or mapcycle == nil) and "not valid JSON" or CheckMapCycle(mapcycle)
    if problem then
        Log("setmapcycle refused: %s", problem)
        return { ok = false, error = problem }
    end

    ModIdsFromHex(mapcycle)
    for _, map in ipairs(mapcycle.maps) do
        if type(map) == "table" then
            ModIdsFromHex(map)
        end
    end
    MapCycle_SetMapCycle(mapcycle)

    local written = ReadMapCycleFile()
    if not written then
        return { ok = false, error = "the game took the cycle, but MapCycle.json did not read back" }
    end
    return { ok = true, cycle = MapCycleForClient(written) }
end

function kRequests.installmod(actions)
    return InstallMod(actions.modid)
end

function kRequests.getmods(actions)
    local searchtext = type(actions.searchtext) == "string" and actions.searchtext or ""
    return "application/json", SearchWorkshop(searchtext)
end

-- The panel itself, so a browser at / stays at /.
local function PanelPage()
    local file = io.open("web/index.html", "r")
    if not file then return kRootPage end
    local html = file:read("*a")
    file:close()
    return html
end

-- The engine serves files under web/ itself; everything else reaches this
-- hook. `request` is { path, method, headers }, header names in lower case.
local function OnWebRequest(actions, request)

    if next(actions) == nil then
        if request.path ~= "/" or string.find(request.headers.accept or "", "text/html", 1, true) then
            return "text/html", PanelPage()
        end
        -- Scripts (auto-shutdown and the like) read the state here.
        return "application/json", Shared.JsonEncode(GetServerState())
    end

    -- Before the request can print or ban.
    EnsureServerAdminPrintWrapped()
    EnsureShineAddBanWrapped()

    local handler = kRequests[actions.request]
    if handler then
        local result, body = handler(actions)
        if type(result) == "table" then
            return "application/json", Shared.JsonEncode(result)
        end
        return result, body
    end

    return "application/json", Shared.JsonEncode(GetServerState())

end
Event.Hook("WebRequest", OnWebRequest)

local function UpdateServerWebInterface()

    -- Shine replaces ServerAdminPrint on its first tick.
    EnsureServerAdminPrintWrapped()
    EnsureShineAddBanWrapped()

    UpdateRecentPlayers()
    UpdatePerfWindows()
    UpdateTickstat()
    UpdateEngineLog()

end

Event.Hook("UpdateServer", UpdateServerWebInterface)


-- recent-players probe: what the hooks see ----------------------------------
local function Try(f)
    local ok, v = pcall(f)
    return ok and tostring(v) or ("error: " .. tostring(v))
end

local function Describe(event, client)
    ProbeLog("Q1/Q2 %s at %s: virtual=%s id=%s address=%s player=%s players-now=%s",
        event, tostring(Shared.GetSystemTime()),
        Try(function() return client:GetIsVirtual() end),
        Try(function() return client:GetUserId() end),
        Try(function()
            local a = Server.GetClientAddress(client)
            return a and IPAddressToString(a) or "nil"
        end),
        Try(function()
            local p = client:GetControllingPlayer()
            return p and p:GetName() or "nil"
        end),
        Try(function() return Shared.GetEntitiesWithClassname("Player"):GetSize() end))
end

Event.Hook("ClientConnect", function(client) Describe("ClientConnect", client) end)
Event.Hook("ClientDisconnect", function(client) Describe("ClientDisconnect", client) end)

local probeFirstTick = true
Event.Hook("UpdateServer", function()
    if probeFirstTick then
        probeFirstTick = false
        ProbeLog("first tick at %s", tostring(Shared.GetSystemTime()))
    end
end)

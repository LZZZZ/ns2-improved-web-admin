-- ======= Copyright (c) 2012, Unknown Worlds Entertainment, Inc. All rights reserved. ==========
--
-- lua\ServerWebAPI.lua
--
--    Created by:   Brian Cronin (brianc@unknownworlds.com)
--
-- ========= For more information, visit us at http://www.unknownworlds.com =====================

Script.Load("lua/RingBuffer.lua")

-- ===================== improved-webadmin ================================
--
-- Replaces ns2/lua/ServerWebInterface.lua. Additions over vanilla:
--
--   runcommand, getconsole  console output, captured by wrapping
--                           ServerAdminPrint and Shared.Message
--   getchatlist&since=N     200-message chat ring with ids
--   getbans                 bans in force; Shine's table under its ban plugin
--   getrecentplayers        players seen in the last 24 h, saved under config://
--   getperf                 10 s performance windows and parsed engine log lines
--   getlog                  log-Server.txt by byte offset
--   getmapvote              Shine's mapvote state
--   getwhitelist            the ranked-mod whitelist, read from Steam
--   server state            mod_version, max_players, map_loaded_at,
--                           ranking_active, shine; per player: skill, gag,
--                           family sharing, rejected moves
--
-- Vanilla bugs fixed: setreservedslotamount never applied; sv_unban never
-- matched; an unbanned player stayed refused until restart;
-- sv_remove_reserved_slot was not saved; getbanlist listed expired bans;
-- getmapcycle rewrote the live cycle's mod ids; setmapcycle wrote invalid
-- cycles. The stock request types keep their response shapes.
--
-- =========================================================================

local kModVersion = "0.1.0"

-- Console lines, each with an increasing id: a client polls with `since` and
-- detects a gap.
local kConsoleBufferSize = 500
local consoleBuffer = CreateRingBuffer(kConsoleBufferSize)
local nextConsoleId = 1
local droppedConsoleLines = 0

-- Lines dropped at capture, counted in `filtered`. Empty: nothing noisy
-- reaches Lua on an idle server.
local kNoisePatterns = {
}
local filteredConsoleLines = 0

local function IsNoise(text)
    for _, pattern in ipairs(kNoisePatterns) do
        if string.find(text, pattern) then
            return true
        end
    end
    return false
end

-- GenerateBannedPlayersMap (ServerAdminCommands.lua:304) only adds to
-- bannedPlayersMap and UnbanUser never removes from it, so GetIsUserBanned
-- refuses an unbanned player until restart. These read the live list instead.
-- Ids compare as numbers: Shine's GetBannedPlayersList() returns string ids.
local function FindLiveBan(userId)

    local id = tonumber(userId)
    if not id then return nil end

    for _, ban in ipairs(GetBannedPlayersList()) do
        if tonumber(ban.id) == id then
            return ban
        end
    end

    return nil

end

if type(GetIsUserBanned) == "function" then

    function GetIsUserBanned(userId)
        local ban = FindLiveBan(userId)
        if not ban then return false end
        return ban.time == 0 or Shared.GetSystemTime() < ban.time
    end

end

if type(GetIsUserBannedPermanently) == "function" then

    function GetIsUserBannedPermanently(userId)
        local ban = FindLiveBan(userId)
        return ban ~= nil and ban.time == 0
    end

end

-- sv_unban passes the id as a string (ServerAdminCommands.lua:485), but bans
-- are keyed by number (:446), so it never matched.
local originalUnbanUser = UnbanUser
if type(originalUnbanUser) == "function" then

    function UnbanUser(userId)
        return originalUnbanUser(tonumber(userId) or userId)
    end

end

-- sv_remove_reserved_slot saves with Server.SaveConfigSettings() rather than
-- Server.SaveReservedSlotsConfig() (ServerAdminCommands.lua:670), so the
-- removal is lost on restart. RemoveReservedSlot is local and cannot be
-- wrapped: a second hook marks the config dirty and the next tick saves it.
local reservedSlotsDirty = false
Event.Hook("Console_sv_remove_reserved_slot", function()
    reservedSlotsDirty = true
end)

local function SaveReservedSlotsIfDirty()
    if reservedSlotsDirty then
        reservedSlotsDirty = false
        Server.SaveReservedSlotsConfig()
    end
end

-- Printed by every CreateServerAdminCommand command before it runs
-- (core/lua/ServerAdmin.lua:113), so it marks a dispatched admin command.
local kAuditPattern = "^sv %- .- %- %d+: : .-: (%S+)"

-- The last line captured, for spotting Shine's echoes to in-game admins.
local lastTeedText, lastTeedAt = nil, nil

local function TeeConsoleLine(source, text)

    text = tostring(text)
    lastTeedText, lastTeedAt = text, Shared.GetSystemTime()

    -- Here rather than in runcommand, so game-console commands are labelled too.
    if string.match(text, kAuditPattern) then
        source = "audit"
    end
    if IsNoise(text) then
        filteredConsoleLines = filteredConsoleLines + 1
        return
    end

    if consoleBuffer:GetNumElements() == kConsoleBufferSize then
        droppedConsoleLines = droppedConsoleLines + 1
    end

    consoleBuffer:Insert({
        id = nextConsoleId,
        time = Shared.GetSystemTime(),
        src = source,
        text = text,
    })
    nextConsoleId = nextConsoleId + 1

end

-- ServerAdminPrint calls Shared.Message; this stops the inner call capturing
-- the line a second time.
local inServerAdminPrint = false

-- Shine replaces ServerAdminPrint on its first tick without chaining, and its
-- version prints nothing without a client, which is every web command. So the
-- wrapper re-installs itself over the current function every tick and before
-- every web request. Extra arguments pass through: Shine's takes a third.
local ourServerAdminPrint

local function EnsureServerAdminPrintWrapped()

    local current = ServerAdminPrint
    if type(current) ~= "function" or current == ourServerAdminPrint then
        return
    end

    ourServerAdminPrint = function(client, message, ...)

        if inServerAdminPrint then
            return current(client, message, ...)
        end

        -- Shine's AdminPrint prints a line, then sends it to each in-game admin
        -- through ServerAdminPrint(admin, line). Skip those copies.
        local echo = client ~= nil and tostring(message) == lastTeedText
            and lastTeedAt ~= nil and Shared.GetSystemTime() - lastTeedAt <= 1
        if not echo then
            TeeConsoleLine("admin", message)
        end

        inServerAdminPrint = true
        local ok, err = pcall(current, client, message, ...)
        inServerAdminPrint = false

        if not ok then
            error(err, 0)
        end

    end
    ServerAdminPrint = ourServerAdminPrint

end

EnsureServerAdminPrintWrapped()

local originalSharedMessage = Shared.Message
if type(originalSharedMessage) == "function" then

    Shared.Message = function(message, ...)
        if not inServerAdminPrint then
            TeeConsoleLine("server", message)
        end
        return originalSharedMessage(message, ...)
    end

end

-- Print and Log are not wrapped: they format and call Shared.Message, so
-- wrapping them captures each line twice, once as the unformatted template.


-- Chat for getchatlist&since=N. The game keeps 20 messages (Server.lua:74);
-- this keeps 200 with ids. Fed by wrapping Server.AddChatToHistory, which
-- player chat, sv_say, sv_tsay and Shine's sh_say all call. It is defined
-- after this file loads (Server.lua:82), so it is wrapped on first use and
-- re-wrapped if replaced.
local kChatBufferSize = 200
local chatBuffer = CreateRingBuffer(kChatBufferSize)
local nextChatId = 1
local droppedChatEntries = 0
local ourAddChatToHistory

-- If our wrapper ends up in the chain twice, only the outer one records.
local inAddChatToHistory = false

local function RecordChat(message, playerName, steamId, teamNumber, teamOnly)

    if chatBuffer:GetNumElements() == kChatBufferSize then
        droppedChatEntries = droppedChatEntries + 1
    end

    chatBuffer:Insert({
        id = nextChatId,
        time = Shared.GetSystemTime(),
        message = tostring(message),
        player = playerName ~= nil and tostring(playerName) or "",
        steamId = tonumber(steamId) or 0,
        team = tonumber(teamNumber) or 0,
        teamOnly = teamOnly == true,
    })
    nextChatId = nextChatId + 1

end

local function EnsureChatWrapped()

    local current = Server.AddChatToHistory
    if type(current) ~= "function" or current == ourAddChatToHistory then
        return
    end

    ourAddChatToHistory = function(message, playerName, steamId, teamNumber, teamOnly, ...)

        if inAddChatToHistory then
            return current(message, playerName, steamId, teamNumber, teamOnly, ...)
        end

        inAddChatToHistory = true
        local ok, err = pcall(current, message, playerName, steamId, teamNumber, teamOnly, ...)
        inAddChatToHistory = false

        if not ok then
            error(err, 0)
        end

        -- After the original, so a refused message is not recorded; pcall so
        -- recording cannot break chat.
        pcall(RecordChat, message, playerName, steamId, teamNumber, teamOnly)

    end
    Server.AddChatToHistory = ourAddChatToHistory

end

local function ChatSince(sinceId)

    local entries = { }
    for _, entry in ipairs(chatBuffer:ToTable()) do
        if entry.id > sinceId then
            table.insert(entries, entry)
        end
    end
    return entries

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

-- The bans in force, newest first. Under Shine's ban plugin, from Shine's
-- table, which keeps issuer, issue time and duration;
-- GetBannedPlayersList() drops those and returns pairs() order.
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
                duration = tonumber(data.Duration),
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
-- to survive map changes. Mod Lua has no os.rename, so saves alternate
-- between two files stamped with an increasing `seq`, and the loader takes
-- the newest that parses: a torn write loses one save, not the list.
-- `connected` is read from the live player list, not from disconnect events.
local kRecentWindow = 24 * 60 * 60
local kRecentCapacity = 100
local kRecentFormerNames = 5
local kRecentSweepSeconds = 10
local kRecentSaveSeconds = 60
local kRecentFileVersion = 1
local kRecentSlots = {
    "config://improved-webadmin/recent-players-a.json",
    "config://improved-webadmin/recent-players-b.json",
}

-- Account id -> entry, as saved.
local recentPlayers = { }
-- Account id -> the time `played` was last updated to, for connected players.
local recentAccrued = { }
-- nil until loaded, then "ok", "fallback" (newest file torn, older one used),
-- "empty" (no file) or "unreadable".
local recentLoadStatus
local recentSeq = 0
local recentNextSlot = 1
local recentDirty = false
local recentUrgent = false
local recentSavedAt
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

-- "absent", "torn", or the decoded document.
local function ReadRecentSlot(path)

    local file = io.open(path, "r")
    if not file then return "absent" end

    local text = file:read("*a")
    file:close()

    local ok, data = pcall(json.decode, text or "")
    if ok and type(data) == "table" and data.version == kRecentFileVersion
            and tonumber(data.seq) and type(data.players) == "table" then
        data.seq = tonumber(data.seq)
        return data
    end
    return "torn"

end

local function EnsureRecentLoaded()

    if recentLoadStatus then return end

    local best, bestSlot
    local torn, present = 0, 0
    for slot, path in ipairs(kRecentSlots) do
        local data = ReadRecentSlot(path)
        if data ~= "absent" then present = present + 1 end
        if data == "torn" then
            torn = torn + 1
        elseif type(data) == "table" and (not best or data.seq > best.seq) then
            best, bestSlot = data, slot
        end
    end

    if best then
        for _, raw in ipairs(best.players) do
            local entry = SanitizeRecentEntry(raw)
            if entry then
                recentPlayers[entry.steamid] = entry
            end
        end
        recentSeq = best.seq
        recentNextSlot = bestSlot % #kRecentSlots + 1
        recentSavedAt = tonumber(best.saved)
    end

    if present == 0 then
        recentLoadStatus = "empty"
    elseif not best then
        recentLoadStatus = "unreadable"
    elseif torn > 0 then
        -- The torn file is the next one written.
        recentLoadStatus = "fallback"
    else
        recentLoadStatus = "ok"
    end

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

    local seq = recentSeq + 1
    local path = kRecentSlots[recentNextSlot]
    local ok, err = pcall(function()
        local file, openError = io.open(path, "w")
        if not file then
            error(openError or ("cannot open " .. path), 0)
        end
        file:write(json.encode({
            version = kRecentFileVersion, seq = seq, saved = now, players = list,
        }))
        file:close()
    end)

    lastRecentSave = now
    recentDirty = false
    recentUrgent = false

    if ok then
        recentSeq = seq
        recentNextSlot = recentNextSlot % #kRecentSlots + 1
        recentSavedAt = now
        recentSaveError = nil
    else
        recentSaveError = tostring(err)
    end

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

-- Once per tick; does real work every kRecentSweepSeconds.
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
            saved_at = recentSavedAt,
            error = recentSaveError,
        },
        players = players,
    }

end

-- Shine's sh_banid names an absent player "<unknown>". Plugin:AddBan is where
-- the name is stored, so the wrapper substitutes the recent-players name.
-- Shine can re-create the plugin, so it is re-applied every tick and before
-- every web request.
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

local function ConsoleLinesSince(sinceId)

    local lines = { }
    for _, line in ipairs(consoleBuffer:ToTable()) do
        if line.id > sinceId then
            table.insert(lines, line)
        end
    end
    return lines

end



local kMaxPerfDatas = 30

-- How often to log performance data in seconds.
local kLogPerfDataRate = 60

-- The last kMaxPerfDatas performance samples (one is taken every kLogPerfDataRate seconds).
local perfDataBuffer = CreateRingBuffer(kMaxPerfDatas)

-- The last time performance data was sampled.
local lastPerfDataTime = 0

-- Performance windows for getperf. The engine completes a
-- ServerPerformanceData about once a second; these are accumulated into
-- kPerfWindowSeconds windows.
--
--   * Accumulate() of a sample with GetDurationMs() == 0 crashes the server
--     with SIGFPE, which pcall cannot catch. The first samples after a map
--     load are empty.
--   * GetUpdateIntervalMs() is whole milliseconds (16 at tickrate 60), so the
--     tickrate is counted from UpdateServer calls instead.
--   * The rate getters follow runtime changes, so they are read per request.
--
-- The buffer resets with the map; a new `loaded_at` means the ids restarted.
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

-- One closed window. Same figures as ServerPerformanceData.DetailText, with
-- its divisions guarded.
local function PerfWindowFromAcc(acc, ticks, elapsed, worstTick)
    local durationMs = acc:GetDurationMs()
    local moves = acc:GetMovesProcessed()
    local players = acc:GetNumPlayers()
    return {
        id = nextPerfWindowId,
        time = Shared.GetSystemTime(),
        duration_ms = durationMs,
        ticks = ticks,
        tickrate = PerfRound(elapsed > 0 and ticks / elapsed or 0, 2),
        worst_tick_ms = PerfRound(worstTick * 1000, 1),
        players = players,
        -- Both 0 with nobody on the server.
        score = acc:GetScore(),
        quality = acc:GetQuality(),
        idle_pct = PerfRound(100 * acc:GetTimeSpentIdling() / durationMs),
        moves_pct = PerfRound(100 * acc:GetTimeSpentOnMoves() / durationMs),
        entities_pct = PerfRound(100 * acc:GetTimeSpentOnUpdate() / durationMs),
        moves_per_s = PerfRound(moves / (durationMs / 1000)),
        move_ms = moves > 0 and PerfRound(acc:GetTimeSpentOnMoves() / moves, 3) or nil,
        entities = acc:GetEntityCount(),
        -- Counts over the window; perfmon prints them per second.
        incomplete = acc:GetIncompleteCount(),
        interp_warns = acc:GetNumInterpWarns(),
        interp_fails = acc:GetNumInterpFails(),
        lua_kb = math.floor(collectgarbage("count")),
    }
end

-- Once per tick, from UpdateServerWebInterface.
local function UpdatePerfWindows()

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

    -- An empty sample would SIGFPE in Accumulate().
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

-- Most records per getperf reply, per cursor, oldest first; the client pages
-- with `more`. An hour in one reply took 8.4 ms to encode, 60 take 1.4 ms.
local kPerfReplyMax = 60

-- The windows after `sinceId` (at most kPerfReplyMax), the next cursor, and
-- whether more are held.
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
        -- 09-27 beta engine and later.
        bw_limit = Server.GetBwLimit and tonumber((select(2, pcall(Server.GetBwLimit)))) or nil,
    }
end

-- getlog: log-Server.txt by byte offset. io.open reaches only mounted roots,
-- so this works only when the log is in the config directory (no -logdir, or
-- -logdir equal to -config_path). A reply holds at most 64 KB (256 KB took
-- 4.4 ms to encode); a client further behind gets `more`.
--
-- Every line carries its byte offset. The header's Date and Time identify the
-- file: a different file, or one shorter than the cursor, gets a fresh tail
-- marked `reset`.
local kLogPath = "config://log-Server.txt"
local kLogTailBytes = 64 * 1024
local kLogMaxBytes = 64 * 1024

local function LogRead(f, from, to)
    if to <= from then return "" end
    f:seek("set", from)
    return f:read(to - from) or ""
end

-- "09/28/2026 02:50:11 AM" from the header, or "" for a file without one.
-- Seconds suffice: a restart takes longer.
local function LogFileId(f)
    local head = LogRead(f, 0, 128)
    local date, time = string.match(head, "^Date: ([^\r\n]*)\r?\nTime: ([^\r\n]-):?\r?\n")
    return date and (date .. " " .. time) or ""
end

-- The complete lines in `text`, which starts at byte `from`. A last line with
-- no newline is left for the next read; `to` is where that read starts.
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

-- The last kLogTailBytes, from the first line start in them.
local function LogTail(f, size)
    local from = math.max(0, size - kLogTailBytes)
    local text = LogRead(f, from, size)
    if from > 0 then
        local nl = string.find(text, "\n", 1, true)
        if nl then
            text, from = string.sub(text, nl + 1), from + nl
        else
            text, from = "", size
        end
    end
    local lines, to = LogLines(text, from)
    return from, to, lines, false
end

local function LogSince(f, size, since)
    local stop = math.min(size, since + kLogMaxBytes)
    local text = LogRead(f, since, stop)
    local lines, to = LogLines(text, since)
    -- A line longer than the cap would stall the cursor: serve it cut.
    if to == since and stop == since + kLogMaxBytes then
        lines, to = { { off = since, text = text } }, stop
    end
    return since, to, lines, to < size and stop < size
end

local function LogBefore(f, before)
    local from = math.max(0, before - kLogTailBytes)
    local text = LogRead(f, from, before)
    if from > 0 then
        local nl = string.find(text, "\n", 1, true)
        if nl then
            text, from = string.sub(text, nl + 1), from + nl
        else
            -- One line longer than a page: serve it cut.
            return from, before, { { off = from, text = text } }, false
        end
    end
    local lines = LogLines(text, from)
    return from, before, lines, false
end

-- Whether config://log-Server.txt is the live log, not a copy left by an
-- earlier run while this one has -logdir elsewhere. Prints a marker and looks
-- for it through a handle opened after the print. Once per map, bypassing the
-- console capture.
local logIsLive = nil

local function CheckLogIsLive()

    if logIsLive ~= nil then return logIsLive end
    local f = io.open(kLogPath, "rb")
    if not f then return nil end
    local before = f:seek("end")
    f:close()

    local marker = string.format(
        "improved-webadmin: checking that %s is this server's log (%d)",
        kLogPath, math.floor(Shared.GetSystemTimeReal() * 1000) % 1000000)
    originalSharedMessage(marker)

    f = io.open(kLogPath, "rb")
    if not f then return nil end
    local after = f:seek("end")
    local text = LogRead(f, math.min(before, after), after)
    f:close()
    logIsLive = string.find(text, marker, 1, true) ~= nil
    return logIsLive

end

local function GetLog(actions)

    -- Before the open: a handle does not see later writes, and the first
    -- reply should include the marker line.
    local checked, live = pcall(CheckLogIsLive)

    local opened, f, err = pcall(io.open, kLogPath, "rb")
    if not opened or not f then
        -- A deleted stale copy reads as missing.
        return { source = "none", path = kLogPath, error = tostring(opened and err or f) }
    end

    if checked and live == false then
        f:close()
        return { source = "none", path = kLogPath, stale = true,
                 error = "the file does not grow: a line this server printed did not reach it" }
    end

    local ok, reply = pcall(function()

        local size = f:seek("end")
        local fileId = LogFileId(f)
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
            from, to, lines, more = LogSince(f, size, math.floor(since))
        elseif before and not reset then
            from, to, lines, more = LogBefore(f, math.floor(before))
        else
            from, to, lines, more = LogTail(f, size)
        end

        return {
            source = "file",
            path = kLogPath,
            file_id = fileId,
            size = size,
            from = from,
            to = to,
            lines = lines,
            more = more,
            at_start = from == 0,
            reset = reset,
            tail_bytes = kLogTailBytes,
            max_bytes = kLogMaxBytes,
        }

    end)
    f:close()

    if not ok then
        return { source = "none", path = kLogPath, error = "reading failed: " .. tostring(reply) }
    end
    return reply

end

-- Engine output that reaches only log-Server.txt, for getperf's `engine`:
--
--   * `TICKSTAT| ...` lines, one every N s after `tickstat N`. They carry no
--     timestamp, so each is stamped when a scan finds it, every
--     kEngineScanSeconds. The first scan after a map load starts at the end
--     of the file.
--   * `client N: snapshot rate A -> B/s (...)` steps and the bwlimit warning.
--   * The `perfmon:` block, printed when someone runs `perfmon`.
--
-- Patterns are anchored at both ends and a TICKSTAT line must parse at least
-- kTickstatMinSegments segments, so a player name cannot fake one. Unknown
-- segments are counted in `unparsed`.
local kEngineScanSeconds = 2
-- The most one scan reads. A scan normally meets about 1 KB; 256 KB takes 1.8 ms.
local kEngineScanMaxBytes = 256 * 1024
local kMaxTickstats = 360          -- an hour at `tickstat 10`
local kMaxPerfmonBlocks = 60
local kMaxEngineEvents = 200
local kTickstatMinSegments = 12
local engineTickstats = CreateRingBuffer(kMaxTickstats)
local enginePerfmon = CreateRingBuffer(kMaxPerfmonBlocks)
local engineEvents = CreateRingBuffer(kMaxEngineEvents)
local nextEngineId = 1
local engineCursor = nil           -- byte offset; set by the first scan
local engineFileId = nil
local enginePartialBlock = nil     -- a perfmon: block still being read
local engineLastScan = nil
local engineScanError = nil
local tickstatLastAt = nil
local tickstatSaid = nil           -- the last `tickstat: on|off` reply

-- One per segment of server_linux's TICKSTAT format, in order.
local kTickstatSegments = {
    { "^win (%S+) s hz (%S+) target (%S+)$", "win_s", "hz", "target" },
    { "^int p50 (%S+) p99 (%S+) p999 (%S+) max (%S+) ms$",
      "int_p50_ms", "int_p99_ms", "int_p999_ms", "int_max_ms" },
    { "^late max (%S+) ms rearm (%S+) stretch (%S+)%% gov max (%S+)$",
      "late_max_ms", "rearm", "stretch_pct", "gov_max" },
    { "^incomplete (%S+)/(%S+) late (%S+) writers (%S+) moves (%S+)$",
      "incomplete", "incomplete_of", "late", "writers", "moves" },
    { "^wait over p99 (%S+) max (%S+) ms %(n=(%S+)%)$", "wait_p99_ms", "wait_max_ms", "wait_n" },
    { "^busy (%S+)%%$", "busy_pct" },
    { "^humans (%S+) bots (%S+)$", "humans", "bots" },
    { "^snap/s/human (%S+) bytes/s/human (%S+)$", "snaps_per_s_human", "bytes_per_s_human" },
    { "^moves/s/human (%S+) moves/s/bot (%S+) injected (%S+)%%$",
      "moves_per_s_human", "moves_per_s_bot", "injected_pct" },
    { "^move ms/tick (%S+)$", "move_ms_tick" },
    { "^spec moves/s (%S+) spec move ms/tick (%S+)$", "spec_moves_per_s", "spec_move_ms_tick" },
    { "^snap bytes p50 (%S+) p99 (%S+) max (%S+) choked (%S+)%%$",
      "snap_p50_bytes", "snap_p99_bytes", "snap_max_bytes", "choked_pct" },
    { "^human move ms/tick (%S+)$", "human_move_ms_tick" },
    { "^sendbuf drops (%S+)$", "sendbuf_drops" },
    { "^rate stepped (%S+) slowest (%S+)/s$", "rate_stepped", "slowest_rate" },
    { "^creations deferred (%S+)$", "creations_deferred" },
}

-- The perfmon: block, one line each; `score` closes it.
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

-- Match `text` against one spec; on a match, set its fields on `into`.
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

local function ParseTickstat(text, now)
    local body = string.match(text, "^TICKSTAT|%s*(.*)$")
    if not body then return nil end
    local record, parsed, unparsed = { }, 0, 0
    for segment in string.gmatch(body .. " | ", "(.-) | ") do
        local known = false
        for _, spec in ipairs(kTickstatSegments) do
            if EngineMatch(spec, segment, record) then known = true break end
        end
        if known then parsed = parsed + 1 else unparsed = unparsed + 1 end
    end
    if parsed < kTickstatMinSegments then return nil end
    record.unparsed = unparsed
    return EngineRecord(record, now)
end

local function ClosePerfmonBlock()
    if enginePartialBlock then
        enginePerfmon:Insert(enginePartialBlock)
        enginePartialBlock = nil
    end
end

local function ParseEngineLine(text, now)

    local head = string.sub(text, 1, 9)
    if head == "TICKSTAT|" then
        local record = ParseTickstat(text, now)
        if record then
            engineTickstats:Insert(record)
            tickstatLastAt = now
        end
        return
    end

    if head == "perfmon: " then
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

-- Parse what the engine wrote since the last scan. The first scan after a map
-- load only sets the cursor.
local function ScanEngineLog()

    local opened, f, err = pcall(io.open, kLogPath, "rb")
    if not opened or not f then
        engineScanError = tostring(opened and err or f)
        return
    end

    local ok, scanErr = pcall(function()
        local size = f:seek("end")
        local fileId = LogFileId(f)
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
            -- Too far behind: only the last kEngineScanMaxBytes, from a line start.
            local from = size - kEngineScanMaxBytes
            local nl = string.find(LogRead(f, from, size), "\n", 1, true)
            engineCursor = nl and from + nl or size
        end
        local text = LogRead(f, engineCursor, size)
        local lines, to = LogLines(text, engineCursor)
        local now = Shared.GetSystemTime()
        for _, line in ipairs(lines) do
            ParseEngineLine(line.text, now)
        end
        engineCursor = to
    end)
    f:close()
    engineScanError = (not ok) and ("reading failed: " .. tostring(scanErr)) or nil

end

-- Once per tick, from UpdateServerWebInterface; scans every kEngineScanSeconds.
local function UpdateEngineLog()
    local now = Shared.GetSystemTimeReal()
    if engineLastScan and now - engineLastScan < kEngineScanSeconds then return end
    engineLastScan = now
    ScanEngineLog()
end

local function EngineSince(buffer, sinceId, into)
    for _, r in ipairs(buffer:ToTable()) do
        if r.id > sinceId then table.insert(into, r) end
    end
    return into
end

-- getperf's `engine`: records since `sinceId`, at most kPerfReplyMax across
-- the three lists. They share one id sequence but leave their rings at
-- different rates, so the page ends at the kPerfReplyMax-th lowest id held.
local function EngineReport(sinceId)
    -- As in getlog: a stale copy of the log opens but never grows.
    local checked, live = pcall(CheckLogIsLive)
    -- The server's clock, for judging whether tickstat is still logging.
    local report = { last_id = nextEngineId - 1, more = false, now = Shared.GetSystemTime() }
    if checked and live == false then
        report.source = "none"
        report.stale = true
        report.error = "the file does not grow: a line this server printed did not reach it"
    elseif not checked or live == nil then
        report.source = "none"
        report.error = engineScanError or (checked and "cannot open the log" or tostring(live))
    else
        report.source = "log"
        report.error = engineScanError
    end
    report.path = kLogPath
    report.scan_s = kEngineScanSeconds
    report.tickstat_last_at = tickstatLastAt
    report.tickstat_said = tickstatSaid
    local lists = {
        EngineSince(engineTickstats, sinceId, { }),
        EngineSince(enginePerfmon, sinceId, { }),
        EngineSince(engineEvents, sinceId, { }),
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

--
-- Returns a list of all of the mods installed on the server (not necessarily active)
--
-- `active`: mounted now, which includes hotfix mods the cycle does not name.
-- GetModTitle takes only the installed index, hence the set.
local function GetModList()

    local active = { }
    for i = 1, Server.GetNumActiveMods() do
        active[Server.GetActiveModId(i)] = true
    end

    local returnList = { }

    for i = 1, Server.GetNumMods() do
        local id   = Server.GetModId(i)
        local name = Server.GetModTitle(i)
        returnList[i] = { id = id, name = name, active = active[id] == true }
    end

    return returnList

end

local function GetMapList()

    local returnList = { }

    for i = 1, Server.GetNumMaps() do
        local name  = Server.GetMapName(i)
        local modId = Server.GetMapModId(i)
        returnList[i] = { name = name, modId = modId }
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

-- Returns a Lua table containing the state of the server.
local function GetServerState()

    local playerRecords = Shared.GetEntitiesWithClassname("Player")

    -- Shine's gags. IsClientGagged also expires a timed gag.
    local gags = GetShinePlugin("basecommands")
    if gags and type(gags.IsClientGagged) ~= "function" then
        gags = nil
    end

    -- Family Sharing, 09-26 beta engine and later. Keys are omitted without it.
    local getShared = Server.GetIsFamilyShared
    local getOwner = Server.GetOwnerUserId

    -- A ScoringMixin number, or nil when the method is missing, errors or does
    -- not return a number.
    local function skillOf(player, method)
        local f = player[method]
        if type(f) ~= "function" then return nil end
        local ok, v = pcall(f, player)
        return ok and tonumber(v) or nil
    end

    local playerList = { }
    for _, player in ientitylist(playerRecords) do

        local client = Server.GetOwner(player)
        -- The ServerClient may be nil if this player was just removed from the server
        -- right before this function was called.
        if client then

            local playerData =
            {
                name = player:GetName(),
                steamid = client:GetUserId(),
                -- A boolean; vanilla sends "true"/"false" strings.
                isbot = client:GetIsVirtual() == true,
                team = player:GetTeamNumber(),
                iscomm = player:GetIsCommander(),
                score = HasMixin(player, "Scoring") and player:GetScore() or 0,
                kills = HasMixin(player, "Scoring") and player:GetKills() or 0,
                assists = HasMixin(player, "Scoring") and player:GetAssistKills() or 0,
                deaths = HasMixin(player, "Scoring") and player:GetDeaths() or 0,
                resources = player:GetResources(),
                ping = client:GetPing(),
                ipaddress = IPAddressToString(Server.GetClientAddress(client))
            }
            if gags then
                local ok, gagged = pcall(gags.IsClientGagged, gags, client)
                if ok then
                    playerData.gagged = gagged == true
                end
            end
            -- Bots, the listen host and LAN players read as not shared.
            if type(getShared) == "function" then
                local ok, shared = pcall(getShared, client)
                if ok and type(shared) == "boolean" then
                    playerData.familyshared = shared
                    if shared and type(getOwner) == "function" then
                        local okOwner, owner = pcall(getOwner, client)
                        if okOwner and tonumber(owner) then
                            playerData.owner_steamid = tonumber(owner)
                        end
                    end
                end
            end
            -- Rejected moves (beta engine). Time-credit rejections usually mean
            -- a modified client; "other" can be a poor connection.
            if type(client.GetMovesRejectedTimeCredit) == "function" then
                local ok, n = pcall(client.GetMovesRejectedTimeCredit, client)
                if ok and tonumber(n) then
                    playerData.moves_rejected_time = tonumber(n)
                end
            end
            if type(client.GetMovesRejectedOther) == "function" then
                local ok, n = pcall(client.GetMovesRejectedOther, client)
                if ok and tonumber(n) then
                    playerData.moves_rejected_other = tonumber(n)
                end
            end
            -- Hive skill as the server holds it. Marines play at skill +
            -- offset, aliens at skill - offset; likewise the commander pair.
            local skill = skillOf(player, "GetPlayerSkill")
            if skill then
                playerData.skill = skill
                playerData.skill_offset = skillOf(player, "GetPlayerSkillOffset")
                playerData.comm_skill = skillOf(player, "GetCommanderSkill")
                playerData.comm_skill_offset = skillOf(player, "GetCommanderSkillOffset")
                -- Badge tier: -1 bot, -2 no skill, 0 rookie, 1-7. GetSkillTier()
                -- caches its first answer in player.skillTier for the map, so
                -- the old value is restored and a poll does not fix it.
                local kept = player.skillTier
                playerData.skill_tier = skillOf(player, "GetSkillTier")
                player.skillTier = kept
            end
            table.insert(playerList, playerData)

        end

    end

    -- Whether the engine counts this server's rounds for ranking. One of its
    -- conditions is that every mounted mod is whitelisted. nil when the
    -- binding is missing or errors.
    local rankingActive
    if type(Server.GetIsRankingActive) == "function" then
        local ok, active = pcall(Server.GetIsRankingActive)
        if ok and type(active) == "boolean" then
            rankingActive = active
        end
    end

    local marineRes, alienRes = GetTeamResourceCount()
    local gamestarted = GetGamerules():GetGameStarted()
    local gametime = gamestarted and math.floor(Shared.GetTime() - GetGamerules():GetGameStartTime()) or 0

    return
    {
        webdomain = "[[webdomain]]",
        webport = "[[webport]]",
        -- Booleans, as above.
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
        -- Absent on a stock server.
        mod_version = kModVersion,
        -- Upper bound for the reserved slot amount.
        max_players = Server.GetMaxPlayers(),
        -- Unix time of the map load (the Lua VM is rebuilt at a map change).
        map_loaded_at = perfLoadedAt,
        ranking_active = rankingActive,
        -- Absent without Shine.
        shine = GetShineState()
    }

end

local function DecToHex(id)
    return string.format("%x", tonumber(id))
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

-- Map cycle.

local kMapCycleFile = "config://MapCycle.json"

-- table.copyDict (Table.lua:441) returns the original rather than its copy, so
-- hex-encoding it rewrote the live cycle. The metatable is kept: dkjson uses
-- it to tell an empty object from an empty array.
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
-- map. Read directly because LoadConfigFile logs a line on every call. nil
-- when the file is missing or not a cycle.
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
            -- A `:` marks a non-workshop source, which ModIdsFromHex passes
            -- through. Anything else must be hex.
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

-- Why a cycle cannot be written, or nil when it can.
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

-- Shine's mapvote. It reads its options from the cycle at plugin start, so a
-- cycle edit reaches the vote at the next map.
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
-- ignores the page. Its callback gets an empty table both for no matches and
-- for a failed search, so an empty result is not reported as an error. A
-- search with no answer after kWorkshopTimeout is given up.
local kWorkshopLimit = 50           -- SearchWorshop's maximum
local kWorkshopTimeout = 30         -- seconds before a search is given up
local kWorkshopCacheSeconds = 60

-- By search text and page. An entry is running ({ started, generation }) or
-- done ({ cached_at, result }, the reply already encoded).
local workshopSearches = { }
local workshopGeneration = 0

local function SearchWorkshop(searchtext, page)

    local now = Shared.GetTime()
    for key, entry in pairs(workshopSearches) do
        if entry.cached_at and now - entry.cached_at >= kWorkshopCacheSeconds then
            workshopSearches[key] = nil
        end
    end

    local key = searchtext .. "\0" .. page
    local entry = workshopSearches[key]
    if entry then
        if entry.cached_at then
            return entry.result
        end
        if now - entry.started < kWorkshopTimeout then
            return json.encode({ loading = true, elapsed = now - entry.started })
        end
        -- Reported once; the next request starts a fresh search.
        workshopSearches[key] = nil
        return json.encode({
            done = true, page = page, items = { }, count = 0,
            error = string.format("The workshop search had no answer after %d s.",
                                  kWorkshopTimeout),
        })
    end

    workshopGeneration = workshopGeneration + 1
    local generation = workshopGeneration
    workshopSearches[key] = { started = now, generation = generation }

    Server.SearchWorshop(searchtext, page, function(results)

        -- Ignore a search that was given up on and restarted.
        local current = workshopSearches[key]
        if not current or current.generation ~= generation then
            return
        end

        local items = { }
        if type(results) == "table" then
            for _, mod in ipairs(results) do
                if type(mod) == "table" and type(mod.id) == "number" then
                    mod.id = string.format("%x", mod.id)
                    table.insert(items, mod)
                end
            end
        end

        workshopSearches[key] = {
            cached_at = Shared.GetTime(),
            result = json.encode({
                done = true, page = page, items = items, count = #items,
                -- There may be more matches than the engine returns.
                capped = #items >= kWorkshopLimit,
            }),
        }

    end)

    return json.encode({ loading = true, elapsed = 0 })

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

-- Ranked-mod whitelist: a mounted mod not on it turns ranking off. It is the
-- "Required items" of an unlisted Workshop item per branch, hard-coded in
-- libSpark_Network.so; Lua can get only the hotfix list's id. Steam's keyless
-- API reports unlisted items as not found, so the item's public page is
-- parsed instead. Ids are decimal strings, as Steam spells them.
local kWhitelistPage = "https://steamcommunity.com/sharedfiles/filedetails/?id="
local kWhitelistFile = "config://improved-webadmin/whitelist.json"
local kWhitelistFileVersion = 1
local kWhitelistMaxAge = 60 * 60    -- read Steam again once the copy is older
local kWhitelistRetrySeconds = 5 * 60
local kWhitelistTimeout = 30
local kWhitelistMaxItems = 2000

-- ModServices.GetHotfixListModId() -> that branch's whitelist.
local kWhitelistBranches = {
    ["2633436686"] = { branch = "live", whitelist = "2909200101" },
    ["2708090797"] = { branch = "beta", whitelist = "2860343495" },
}

local whitelistLoaded = false
-- { version, branch, hotfix_list_id, whitelist_id, read_at, whitelist, hotfix }
local whitelistData
-- { started, generation } while a read runs.
local whitelistFetch
local whitelistGeneration = 0
local whitelistError
local whitelistErrorAt

local function GetHotfixListId()

    if type(ModServices) ~= "table" or type(ModServices.GetHotfixListModId) ~= "function" then
        return nil
    end
    -- A uint64 through the FFI: tonumber, not tostring, which appends ULL.
    local ok, id = pcall(ModServices.GetHotfixListModId)
    id = ok and tonumber(id)
    if not id or id <= 0 then return nil end
    return string.format("%.0f", id)

end

local function IsIdList(t)

    if type(t) ~= "table" or #t == 0 or #t > kWhitelistMaxItems then return false end
    for _, id in ipairs(t) do
        if type(id) ~= "string" or not string.find(id, "^%d+$") then return false end
    end
    return true

end

-- The ids in a Workshop page's "Required items", in order. Each is an
-- <a href=".../filedetails/?id=N"><div class="requiredItem">title</div></a>,
-- back to back after the block's opening tag. nil when there is no block.
local function ParseRequiredItems(page)

    if type(page) ~= "string" then return nil end
    local _, pos = string.find(page, 'id="RequiredItems"[^>]*>')
    if not pos then return nil end

    local ids = { }
    while #ids < kWhitelistMaxItems do
        local _, last, id = string.find(page,
            '^%s*<a [^>]-filedetails/%?id=(%d+)"[^>]*>%s*<div class="requiredItem">.-</div>%s*</a>',
            pos + 1)
        if not id then break end
        table.insert(ids, id)
        pos = last
    end
    return #ids > 0 and ids or nil

end

local function LoadWhitelistFile()

    if whitelistLoaded then return end
    whitelistLoaded = true

    local file = io.open(kWhitelistFile, "r")
    if not file then return end
    local text = file:read("*a")
    file:close()

    -- A torn write fails to parse and costs one read from Steam.
    local ok, data = pcall(json.decode, text or "")
    if ok and type(data) == "table" and data.version == kWhitelistFileVersion
            and tonumber(data.read_at) and type(data.hotfix_list_id) == "string"
            and IsIdList(data.whitelist) and IsIdList(data.hotfix) then
        data.read_at = tonumber(data.read_at)
        whitelistData = data
    end

end

local function SaveWhitelistFile()

    local ok, err = pcall(function()
        local file, openError = io.open(kWhitelistFile, "w")
        if not file then
            error(openError or ("cannot open " .. kWhitelistFile), 0)
        end
        file:write(json.encode(whitelistData))
        file:close()
    end)
    if not ok then
        Log("improved-webadmin: whitelist not saved: %s", tostring(err))
    end

end

-- Read one item's page; callback(ids) or callback(nil, why). SendHTTPRequest's
-- callback gets (body, curl error message, curl code, HTTP status). Steam
-- answers 200 for an item it does not have, so a page without "Required
-- items" is the failure case.
local function FetchRequiredItems(id, callback)

    local ok, err = pcall(Shared.SendHTTPRequest, kWhitelistPage .. id, "GET",
                          function(page, message, _, status)
        local ids = ParseRequiredItems(page)
        if ids then
            callback(ids)
        elseif type(message) == "string" and message ~= "" then
            callback(nil, "Steam could not be reached: " .. message)
        elseif (tonumber(status) or 0) > 0 and tonumber(status) ~= 200 then
            callback(nil, string.format("Steam answered HTTP %d for item %s.", status, id))
        elseif type(page) ~= "string" or page == "" then
            callback(nil, string.format("Steam did not answer for item %s.", id))
        else
            callback(nil, string.format(
                "Steam's page for item %s lists no required items (%d bytes).", id, #page))
        end
    end)
    if not ok then
        callback(nil, "SendHTTPRequest failed: " .. tostring(err))
    end

end

local function StartWhitelistFetch(hotfixListId, branch)

    whitelistGeneration = whitelistGeneration + 1
    local generation = whitelistGeneration
    whitelistFetch = { started = Shared.GetTime(), generation = generation }

    -- Ignore a read that was given up on and restarted.
    local function current()
        return whitelistFetch ~= nil and whitelistFetch.generation == generation
    end
    local function fail(why)
        if not current() then return end
        whitelistFetch = nil
        whitelistError, whitelistErrorAt = why, Shared.GetSystemTime()
        Log("improved-webadmin: whitelist not read: %s", why)
    end

    -- One page at a time: concurrent HTTPS crashed the 09-03 engine's libcurl.
    FetchRequiredItems(branch.whitelist, function(whitelist, why)
        if not current() then return end
        if not whitelist then return fail(why) end
        FetchRequiredItems(hotfixListId, function(hotfix, why2)
            if not current() then return end
            if not hotfix then return fail(why2) end
            whitelistFetch = nil
            whitelistError, whitelistErrorAt = nil, nil
            whitelistData = {
                version = kWhitelistFileVersion,
                branch = branch.branch,
                hotfix_list_id = hotfixListId,
                whitelist_id = branch.whitelist,
                read_at = Shared.GetSystemTime(),
                whitelist = whitelist,
                hotfix = hotfix,
            }
            SaveWhitelistFile()
        end)
    end)

end

local function GetWhitelist()

    LoadWhitelistFile()

    local now = Shared.GetSystemTime()
    local hotfixListId = GetHotfixListId()
    local branch = hotfixListId and kWhitelistBranches[hotfixListId]
    local reply = {
        now = now,
        hotfix_list_id = hotfixListId,
        branch = branch and branch.branch,
        whitelist_id = branch and branch.whitelist,
    }
    if not branch then
        reply.error = hotfixListId
            and string.format("No whitelist is known for hotfix list %s.", hotfixListId)
            or "The server has no hotfix list, so no whitelist to read."
        return reply
    end

    if whitelistFetch and Shared.GetTime() - whitelistFetch.started >= kWhitelistTimeout then
        whitelistFetch = nil
        whitelistError = string.format("Steam did not answer within %d s.", kWhitelistTimeout)
        whitelistErrorAt = now
    end

    -- A copy saved for another branch does not count.
    local data = whitelistData
    if data and data.hotfix_list_id ~= hotfixListId then
        data = nil
    end

    local stale = not data or now - data.read_at >= kWhitelistMaxAge
    local resting = whitelistErrorAt and now - whitelistErrorAt < kWhitelistRetrySeconds
    if stale and not whitelistFetch and not resting then
        StartWhitelistFetch(hotfixListId, branch)
    end

    reply.fetching = whitelistFetch ~= nil
    reply.error = whitelistError
    if data then
        reply.read_at = data.read_at
        reply.whitelist = data.whitelist
        reply.hotfix = data.hotfix
    end
    return reply

end

-- The reply to a request with no parameters, i.e. a browser at the root.
-- Vanilla served the full state there, player IPs included. Lua gets neither
-- path nor headers and cannot redirect, so this page links to the panel.
local kRootPage = [[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=/index.html">
<title>NS2 web admin</title>
</head>
<body>
<p>The web admin panel is at <a href="/index.html">/index.html</a>.</p>
<p>Server state, for a script, is at <a href="/?request=json">/?request=json</a>.</p>
</body>
</html>
]]

local function OnWebRequest(actions)

    if type(actions) ~= "table" or next(actions) == nil then
        return "text/html", kRootPage
    end

    -- Before the request can print, ban or chat.
    EnsureServerAdminPrintWrapped()
    EnsureShineAddBanWrapped()
    EnsureChatWrapped()

    if actions.request == "runcommand" then

        local command = actions.cmd or ""
        local firstId = nextConsoleId
        local started = Shared.GetTime()

        Shared.ConsoleCommand(command)

        local elapsed = Shared.GetTime() - started
        local produced = ConsoleLinesSince(firstId - 1)

        local dispatched = false
        for _, line in ipairs(produced) do
            if line.src == "audit" then
                dispatched = true
            end
        end
        local lines = produced

        return "application/json", json.encode({
            cmd = command,
            -- True for an admin command. False for a plain console command
            -- and for no such command alike: the server cannot tell them apart.
            dispatched = dispatched,
            elapsed = elapsed,
            lines = lines,
            last_id = nextConsoleId - 1,
        })

    elseif actions.request == "getconsole" then

        local since = tonumber(actions.since) or 0
        local lines = ConsoleLinesSince(since)

        return "application/json", json.encode({
            lines = lines,
            last_id = nextConsoleId - 1,
            -- Lines lost to ring overflow, and lines dropped as noise.
            dropped = droppedConsoleLines,
            filtered = filteredConsoleLines,
            buffer_size = kConsoleBufferSize,
        })

    elseif actions.request == "getbans" then

        local source, now, bans = GetBansInForce()
        return "application/json", json.encode({
            source = source,
            -- The server's clock, for computing time left.
            now = now,
            bans = bans,
        })

    elseif actions.request == "getrecentplayers" then

        return "application/json", json.encode(GetRecentPlayers())

    elseif actions.request == "getlog" then

        return "application/json", json.encode(GetLog(actions))

    end

    if actions.request == "getbanlist" then

        -- The game prunes expired bans only when the ban file is loaded or
        -- saved (ServerAdminCommands.lua:312); list only bans in force.
        local now = Shared.GetSystemTime()
        local inForce = { }
        for _, ban in ipairs(GetBannedPlayersList()) do
            if ban.time == 0 or ban.time > now then
                table.insert(inForce, ban)
            end
        end

        return "application/json", json.encode(inForce)
    elseif actions.request == "getreservedslots" then

        -- Under Shine's reservedslots plugin the vanilla list is not what is
        -- enforced; add Shine's slot count.
        local data = GetReservedSlotData()
        local plugin = GetShinePlugin("reservedslots")
        if plugin and type(plugin.Config) == "table" then
            data.shine = { slots = tonumber(plugin.Config.Slots) or 0 }
        end
        return "application/json", json.encode(data)
    elseif actions.request == "getperfdata" then
        return "application/json", json.encode(perfDataBuffer:ToTable())

    elseif actions.request == "getperf" then

        -- Paged; see kPerfReplyMax.
        local since = tonumber(actions.since) or 0
        local windows, lastId, more = PerfWindowsSince(since)
        return "application/json", json.encode({
            -- Engine log records, with their own cursor.
            engine = EngineReport(tonumber(actions.esince) or 0),
            window_s = kPerfWindowSeconds,
            capacity = kMaxPerfWindows,
            loaded_at = perfLoadedAt,
            map = Shared.GetMapName(),
            config = PerfConfig(),
            windows = windows,
            last_id = lastId,
            more = more,
        })

    elseif actions.request == "getchatlist" then

        -- With `since`, this mod's ring from that id on. Without it, the
        -- game's 20 in the stock shape, which the 2012 panel polls.
        local since = tonumber(actions.since)
        if since then
            return "application/json", json.encode({
                entries = ChatSince(since),
                last_id = nextChatId - 1,
                -- Entries lost to ring overflow.
                dropped = droppedChatEntries,
                buffer_size = kChatBufferSize,
            })
        end
        return "application/json", Server.recentChatMessages and json.encode(Server.recentChatMessages:ToTable()) or "{ }"
    elseif actions.request == "getinstalledmodslist" then
        return "application/json", json.encode(GetModList())
    elseif actions.request == "getmaplist" then
        return "application/json", json.encode(GetMapList())
    elseif actions.request == "getmapcycle" then

        -- Mod ids go out as hex: JSON has no 64-bit integers.
        local mapcycle = ReadMapCycleFile() or DeepCopy(MapCycle_GetMapCycle())
        return "application/json", json.encode(MapCycleForClient(mapcycle))

    elseif actions.request == "setmapcycle" then

        -- Refuse a cycle the game cannot use, without writing it, and reply
        -- with what the file holds afterwards.
        local ok, mapcycle = pcall(json.decode, actions.data or "")
        local problem = (not ok or mapcycle == nil) and "not valid JSON"
                        or CheckMapCycle(mapcycle)
        if problem then
            Log("setmapcycle refused: %s", problem)
            return "application/json", json.encode({ ok = false, error = problem })
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
            return "application/json", json.encode({
                ok = false,
                error = "the game took the cycle, but MapCycle.json did not read back",
            })
        end
        return "application/json", json.encode({ ok = true, cycle = MapCycleForClient(written) })

    elseif actions.request == "getmapvote" then

        return "application/json", json.encode(GetMapVote())

    elseif actions.request == "setreservedslotamount" then

        -- SetReservedSlotAmount takes (client, amount); vanilla passed only
        -- the amount, so every call was rejected.
        SetReservedSlotAmount(nil, actions.amount)
        return ""

    elseif actions.request == "installmod" then

        return "application/json", json.encode(InstallMod(actions.modid))

    elseif actions.request == "getwhitelist" then

        return "application/json", json.encode(GetWhitelist())

    elseif actions.request == "getmods" then

        -- Replies keep `loading` and `items`, the keys the 2012 panel reads.
        local searchtext = type(actions.searchtext) == "string" and actions.searchtext or ""
        local page = math.floor(tonumber(actions.p) or 1)
        if not (page >= 1 and page <= 1000) then   -- also NaN and inf
            page = 1
        end
        return "application/json", SearchWorkshop(searchtext, page)

    end

    if actions.command then
        Shared.ConsoleCommand(actions.rcon)
    end

    return "application/json", json.encode(GetServerState())

end
Event.Hook("WebRequest", OnWebRequest)

--
-- This function should be called once per tick.
--
local function UpdateServerWebInterface()

    -- Re-wrap what Shine or another mod replaced: Shine replaces
    -- ServerAdminPrint on its first tick.
    EnsureServerAdminPrintWrapped()
    EnsureShineAddBanWrapped()
    EnsureChatWrapped()

    SaveReservedSlotsIfDirty()
    UpdateRecentPlayers()
    UpdatePerfWindows()
    UpdateEngineLog()

    if Shared.GetSystemTime() - lastPerfDataTime >= kLogPerfDataRate then

        local playerRecords = Shared.GetEntitiesWithClassname("Player")
        local entCount = Shared.GetEntitiesWithClassname("Entity"):GetSize()
        local newData = { players = playerRecords:GetSize(), tickrate = Server.GetFrameRate(), time = Shared.GetSystemTime(), ent_count = entCount }
        perfDataBuffer:Insert(newData)

        lastPerfDataTime = Shared.GetSystemTime()

    end

end

Event.Hook("UpdateServer", UpdateServerWebInterface)

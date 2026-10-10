-- ======= Copyright (c) 2012, Unknown Worlds Entertainment, Inc. All rights reserved. ==========
--
-- lua\ServerWebAPI.lua
--
--    Created by:   Brian Cronin (brianc@unknownworlds.com)
--
-- ========= For more information, visit us at http://www.unknownworlds.com =====================

Script.Load("lua/RingBuffer.lua")

-- ===================== improved-webadmin =====================================
--
-- The mod's copy of ns2/lua/ServerWebInterface.lua. A mod's lua/ shadows the
-- game's, so this file replaces the vanilla one wholesale. It started as a
-- verbatim copy of the 344 / 26-09-03 original; the changes below are each
-- marked `improved-webadmin:`. The vanilla code is a starting point, not something
-- to preserve: change it wherever that improves the result, keeping the HTTP
-- API backward compatible when that is cheap (docs/DESIGN.md, "Design decisions").
--
-- 1. Console output is captured and returned.
--
--    Vanilla runs `Shared.ConsoleCommand(actions.rcon)` and answers with the
--    ordinary state blob, so a kick that worked and a kick that matched nobody
--    are byte-identical over HTTP. The panel has never been able to tell them
--    apart and fakes it with a timed refresh.
--
--    ServerAdminPrint (core/lua/ServerAdmin.lua:156) and Shared.Message are
--    both plain writable globals that nobody aliases locally, and
--    Shared.ConsoleCommand is synchronous, so wrapping them tees every line
--    into a ring buffer and a command's own output is available the moment it
--    returns. Measured in tools/spikes/console-output-probe.lua; findings in
--    docs/REQUIREMENTS.md item 5.
--
--    Two request types read it:
--
--      request=runcommand&cmd=...   run it and return the lines it produced
--      request=getconsole&since=N   everything since line N, for a console
--
--    The legacy `command`/`rcon` fallthrough still works exactly as before, so
--    the 2012 panel keeps functioning against this server.
--
-- 2. `mod_version` in the server-state response, so a panel can tell whether
--    it is talking to this Lua or to a stock server and say so rather than
--    quietly offering features that cannot work.
--
-- 3. Three one-line bugs fixed, all of them cases where the server reports
--    success it never had. Details in docs/CONSTRAINTS.md items 7-9.
--
--      setreservedslotamount  called SetReservedSlotAmount(amount) against a
--                             function declared (client, amount), so the guard
--                             rejected every call and the whole Reserved Slots
--                             tab has never worked.
--      sv_unban               passed the console argument through as a string
--                             to a map keyed by number, so it could never
--                             match a ban that was plainly in getbanlist.
--      getbanlist             listed bans that had expired and no longer
--                             blocked anyone.
--
--    Found later (CONSTRAINTS items 10 and 11): an unban that did not let the
--    player back in, and sv_remove_reserved_slot never saving its removal.
--
--    Two are fixed here. `sv_unban` is fixed by wrapping the UnbanUser global
--    rather than by shipping a second copy of ServerAdminCommands.lua: it is a
--    global, nobody aliases it, and ServerAdminCommands.lua loads before this
--    file (Server.lua:34 and :35), so the wrapper is in place before anything
--    can call it -- and it fixes the game console's own sv_unban too, not just
--    the web one.
--
-- 4. Shine is first-class (docs/CONSTRAINTS.md, "Shine"). The state blob says
--    whether Shine is loaded and which of the plugins that replace vanilla
--    behaviour are on, and `getbans` reads Shine's own ban table when its ban
--    plugin owns the list -- who banned, when, for how long, none of which
--    GetBannedPlayersList() keeps.
--
-- 5. Recent players: everyone seen in the last 24 hours, up to 100, with name,
--    former names, IP, first and last seen and time played, kept in
--    config://improved-webadmin/ so the list outlives a map change. Read with
--    request=getrecentplayers. See docs/REQUIREMENTS.md item 6.
--
--    Under Shine's ban plugin, a ban of someone who is not connected is
--    recorded with the name this list last saw instead of "<unknown>".
--    Vanilla's sv_ban keeps "Unknown": its ban table is file-local.
--
-- 6. The map cycle (docs/CONSTRAINTS.md items 12 and 13). `getmapcycle` reads
--    MapCycle.json, which is what rotation reads, instead of the copy loaded
--    with the map, and no longer rewrites the live cycle's mod ids to hex on
--    the way out. `setmapcycle` refuses a cycle the game could not use
--    without writing it, and answers with what the file holds afterwards.
--    `getmapvote` says what Shine's mapvote will do with the cycle.
--
-- 7. `getinstalledmodslist` marks each mod `active` when it is mounted now
--    (docs/REQUIREMENTS.md item 3). Installed is not loaded, and the cycle is
--    not what is loaded either: it takes effect at the next map change.
--
-- 8. `getperf`: what `perfmon` logs, in 10 s windows, for the Performance tab
--    (docs/REQUIREMENTS.md item 10). Vanilla `getperfdata` keeps one reading a
--    minute of three numbers and stays as it was, for the 2012 panel. Each
--    window adds the engine's own ServerPerformanceData (score, idle, moves,
--    entities, interp warns and fails, the configured rates) plus the tickrate
--    counted from UpdateServer calls and the worst tick, which the engine's
--    whole-millisecond interval cannot give at 60 tick and up.
--
--    Its `engine` part is what the engine prints only to the log: `tickstat`
--    lines (tick spacing, snapshot sizes, choke), players' snapshot rate
--    steps, a bwlimit warning, and the `perfmon:` block. The log is scanned
--    every 2 s, with a cursor of its own (`esince`).
--
-- 9. `getlog`: the engine's own log-Server.txt, tailed by byte offset, for the
--    Log tab (docs/REQUIREMENTS.md item 7). It holds what never passes through
--    Lua -- connects, auth, engine errors, Script tracing -- and, unlike the
--    console buffer, it outlives a map change. Reachable only when -logdir is
--    the config directory, which the default layout is; otherwise the reply
--    says so and the console buffer is what there is.
--
-- 10. `getwhitelist`: the ranked-mod whitelist, read from Steam (docs/CONSTRAINTS.md item 17).
--    The engine reads it at boot from a Workshop item and gives Lua no way
--    to see it, so the mod reads the item's public page itself, once an hour
--    at most and only when a panel asks, and keeps it in
--    config://improved-webadmin/ across map changes.
--
-- =========================================================================

local kModVersion = "0.1.0"

-- Lines kept for the console tab. Each carries an increasing id, so a client
-- polls with `since` and learns from a gap that it missed some.
local kConsoleBufferSize = 500
local consoleBuffer = CreateRingBuffer(kConsoleBufferSize)
local nextConsoleId = 1
local droppedConsoleLines = 0

-- Engine chatter that would drown a console. Filtered at capture, and counted
-- so the count is visible rather than the lines just going missing.
--
-- Empty by measurement rather than by omission: an idle server produced zero
-- lines over 75 s, because the periodic `Script tracing` messages in
-- log-Server.txt are written engine-side and never pass through Lua. The
-- mechanism stays for a busy server that proves otherwise.
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

-- A fourth bug, found while testing the third and worse than it: an unban
-- that works does not actually let the player back in.
--
-- GenerateBannedPlayersMap (ServerAdminCommands.lua:304) only ever *adds* to
-- `bannedPlayersMap`, and UnbanUser removes from `bannedPlayers` without
-- clearing the map, so the removed ban survives in it. GetIsUserBanned and
-- GetIsUserBannedPermanently read that map, and OnCheckConnectionAllowed
-- (line 376) reads them, so until the server restarts the unbanned player is
-- still refused -- while every list says they are not banned. Measured on the
-- rig: after a successful unban, getbanlist was empty and GetIsUserBanned
-- still answered true.
--
-- It cannot bite on a stock server only because sv_unban never works there.
-- Fixing item 8 is what exposes it, so both have to be fixed together.
--
-- Both functions are globals that OnCheckConnectionAllowed calls by name, so
-- replacing them here is enough. They consult the live ban list instead of the
-- map: a linear scan over a list of bans, against a hash lookup, on a path
-- that runs once per connection attempt.
--
-- Compare ids as numbers on both sides. Vanilla stores them as numbers, but
-- Shine's ban plugin replaces GetBannedPlayersList() with one built from its
-- own table, keyed by *string* ids -- seen on a Shine server, where all 119
-- ids came back as strings. A plain `ban.id == id` never matches those.
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

-- CONSTRAINTS item 8. Ban records key `bannedPlayersMap` by a number
-- (`tonumber(playerId)`, ServerAdminCommands.lua:446) but UnBan hands the raw
-- console argument -- a string -- straight to UnbanUser (line 485), so the
-- lookup always missed and the server answered "No matching Steam Id in ban
-- list" about an entry it was listing at the same moment.
local originalUnbanUser = UnbanUser
if type(originalUnbanUser) == "function" then

    function UnbanUser(userId)
        return originalUnbanUser(tonumber(userId) or userId)
    end

end

-- sv_remove_reserved_slot takes the slot out of memory and then saves with
-- Server.SaveConfigSettings() (ServerAdminCommands.lua:670), where adding a
-- slot and setting the amount use Server.SaveReservedSlotsConfig(). The
-- removal never reaches ReservedSlotsConfig.json: measured on the rig
-- 2026-09-27, the file still held the slot after "Removed reserved slot for
-- One", until an unrelated sv_reserved_slots saved it. A restart in between
-- brings the removed slot back.
--
-- RemoveReservedSlot is a local, so it cannot be wrapped. A second hook on the
-- same console command marks the config dirty and the next tick saves it,
-- which is right whichever of the two hooks the engine runs first.
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

-- Every command created by CreateServerAdminCommand emits this line before it
-- runs (core/lua/ServerAdmin.lua:113), so its presence is a receipt that the
-- command existed and was dispatched. Absence means an Event.Hook-style
-- command such as sv_help, or nothing at all.
local kAuditPattern = "^sv %- .- %- %d+: : .-: (%S+)"

-- The last line teed, for telling an echo from a new line (see the wrapper).
local lastTeedText, lastTeedAt = nil, nil

local function TeeConsoleLine(source, text)

    text = tostring(text)
    lastTeedText, lastTeedAt = text, Shared.GetSystemTime()

    -- Classified here rather than in runcommand, so a command someone runs
    -- from the game console is labelled the same way as one from the panel.
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

-- ServerAdminPrint calls Shared.Message itself, so without this flag every
-- admin message would be captured twice -- sv_help yields 74 lines for 37
-- commands. The flag suppresses the inner call, not the outer one.
local inServerAdminPrint = false

-- Shine replaces ServerAdminPrint on its first tick, without chaining to what
-- was there, and its version returns at once when there is no client -- which
-- is every command run from the web admin. On a Shine server that dropped our
-- wrapper and, with it, the output of every vanilla admin command: sv_kick's
-- "No matching player", the whole of sv_listbans. Measured on the rig with a
-- Shine config, 2026-09-27; Shine's source is lua/shine/core/server/logging.lua.
--
-- So the wrapper re-installs itself over whatever ServerAdminPrint currently
-- is, every tick and before every web request. The flag also keeps a chain
-- that runs through our wrapper twice (another mod wrapping ours, then ours
-- wrapping it) from teeing a line twice. Extra arguments pass through: Shine's
-- version takes a third.
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

        -- Shine's AdminPrint prints a line to the server console and then
        -- sends the same line to every admin in game, each through
        -- ServerAdminPrint(admin, line). The server printed it once; the
        -- copies are deliveries. Measured on the rig with an admin joined,
        -- 2026-10-06: without this, every Shine line arrived twice. A line
        -- for a player that is not such an echo -- an in-game admin's own
        -- command output -- is still captured.
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

-- Print and Log are deliberately NOT wrapped. They are distinct functions, so
-- an identity check does not rule them out, but they are format-string front
-- ends onto Shared.Message: wrapping them captured `Requesting server ranking
-- be enabled, request success: %s` from Print and then the formatted
-- `... success: false` from Shared.Message underneath it. Every line arrived
-- twice, once as a useless template. Shared.Message already sees everything
-- they emit, formatted. Measured on the rig, 2026-09-05.


-- improved-webadmin: chat for the Chat tab (CONSTRAINTS item 3).
--
-- The game keeps the last 20 messages (Server.lua:74) and getchatlist hands
-- over all of them every time. This keeps 200, with times and increasing ids,
-- so a client polls with `since` and learns from `dropped` what it missed.
--
-- It is fed by wrapping Server.AddChatToHistory, which player chat
-- (NetworkMessages_Server.lua:285), sv_say and sv_tsay
-- (ServerAdminCommands.lua:196, :222) and Shine's sh_say
-- (shine/core/server/logging.lua:209) all call. Wrapped rather than replaced,
-- because Server.lua is not ours: two installed workshop mods ship their own.
-- And wrapped late, because this file is loaded at Server.lua:35, before the
-- function is defined at :82. Re-installed when something replaces it, like
-- the ServerAdminPrint wrapper above.
local kChatBufferSize = 200
local chatBuffer = CreateRingBuffer(kChatBufferSize)
local nextChatId = 1
local droppedChatEntries = 0
local ourAddChatToHistory

-- As with ServerAdminPrint: if another mod wraps ours and we then wrap
-- theirs, the chain runs through our wrapper twice. Only the outer one records.
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

        -- After the original, so what it refuses is not recorded, and guarded,
        -- so nothing here can break chat itself.
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


-- Shine, and its plugins that replace something vanilla does. Shine loads
-- after this file, so every lookup happens per request rather than at load.
-- Nil when Shine is absent, which also keeps the key out of the state blob.
-- basecommands holds sh_gag, the only mute there is: the game has none.
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

-- An expiry further out than this is not a date but a way of writing "never":
-- Shine was seen storing 6e+24 on a real server. Reported as permanent, so no
-- client has to guess where the line is.
local kPermanentAfter = 100 * 365 * 24 * 60 * 60

-- The bans in force, newest first, from whichever table actually decides them.
-- Under Shine's ban plugin that is Shine's own table, which keeps who banned,
-- when and for how long; GetBannedPlayersList() throws all three away, and
-- hands the rest over in pairs() order, which changes between calls.
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

    -- Vanilla appends, so the list is already oldest first.
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

-- Recent players (docs/REQUIREMENTS.md item 6): everyone seen in the last day,
-- so a player who has already left can still be found and banned.
--
-- It has to outlive a map change, and a map change rebuilds all Lua state, so
-- the list lives in a file under config://. Measured on 09-26: mod Lua can
-- write there, but "a" truncates like "w" and there is no os.rename or
-- os.remove. The file is therefore rewritten whole, and a crash mid-write
-- leaves it torn with no way to swap a finished copy in.
--
-- Two slots stand in for write-then-rename. Saves alternate between them,
-- each stamped with an increasing `seq`, and the loader takes the newest one
-- that parses. A torn write costs one save, not the list, and the next save
-- overwrites the torn slot.
--
-- Nothing here depends on whether ClientDisconnect fires at a map change: a
-- disconnect only stamps a time, and `connected` is read off the live player
-- list at request time, so a map change never reads as everyone leaving.
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
-- Account id -> the system time `played` was last brought up to, while that
-- player is connected on this map.
local recentAccrued = { }
-- nil until the file has been read. Then "ok", "fallback" (the newest slot was
-- torn and the older one was used), "empty" (no file yet) or "unreadable".
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

-- One slot: "absent", or "torn", or the decoded document.
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
        -- The torn slot is the next one written, so it is gone after one save.
        recentLoadStatus = "fallback"
    else
        recentLoadStatus = "ok"
    end

end

-- The humans connected right now, by account id, from the same walk the state
-- blob does.
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

-- Oldest out first, then the rest past the capacity. Someone still connected
-- is never dropped, however long they have been on.
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

-- Player:GetName() answers kDefaultPlayerName while a name is still empty, so
-- that placeholder never replaces a real name or becomes a former one.
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

    -- Saved on the next tick rather than here, so a map change or a mass
    -- disconnect costs one write, not one per player.
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
            -- A connected player is being seen now, whatever the last sweep
            -- wrote, and has played up to now.
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

-- Shine's sh_banid records an absent player as "<unknown>" (its BanID, in
-- lua/shine/extensions/ban/server.lua), and every consumer of the ban -- its
-- table, the vanilla file it syncs, its net data, the OnPlayerBanned hook --
-- takes the name from Plugin:AddBan's second argument. AddBan is a public
-- method on the plugin, so the name is supplied there, from the recent list,
-- before anything stores it. Shine's own console line prints a local and
-- still says "<unknown>"; the line below says what was actually recorded.
--
-- Shine loads after this file and can re-create a plugin, so the wrapper is
-- re-applied every tick and before every web request, per plugin table.
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

-- improved-webadmin: performance windows for `getperf` (item 8 above).
--
-- The engine completes a ServerPerformanceData about once a second (measured:
-- every 1.00 s, 30 UpdateServer calls apart at tickrate 30). Each fresh one is
-- accumulated until the window holds kPerfWindowSeconds, the way perfmon
-- accumulates its 30 s. Measured on the rig (REQUIREMENTS item 10):
--
--   * Accumulate() of a sample with GetDurationMs() == 0 kills the server with
--     SIGFPE, which pcall cannot catch. The engine's first samples after a map
--     load are empty. Never pass one in.
--   * GetUpdateIntervalMs() is whole milliseconds: 16 at tickrate 60, which
--     reads as 62.5 (the `tick 62.5` in perfmon lines). The tickrate here is
--     counted instead: UpdateServer runs once per tick.
--   * The getters that report settings follow a runtime `tickrate`, `sendrate`,
--     `moverate` or `interp` at once, so the configured rates are read per
--     request, not at load.
--
-- The buffer lives and dies with the Lua VM, i.e. with the map. `loaded_at`
-- says when it started, so a client that sees it change knows the ids restarted.
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

-- One closed window, as the panel reads it. Computed as ServerPerformanceData.
-- DetailText computes its perfmon line, with its divisions guarded.
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
        -- Both 0 with nobody on the server, and DetailText refuses to describe
        -- such a sample; the panel says "no players" rather than "score 0".
        score = acc:GetScore(),
        quality = acc:GetQuality(),
        idle_pct = PerfRound(100 * acc:GetTimeSpentIdling() / durationMs),
        moves_pct = PerfRound(100 * acc:GetTimeSpentOnMoves() / durationMs),
        entities_pct = PerfRound(100 * acc:GetTimeSpentOnUpdate() / durationMs),
        moves_per_s = PerfRound(moves / (durationMs / 1000)),
        move_ms = moves > 0 and PerfRound(acc:GetTimeSpentOnMoves() / moves, 3) or nil,
        entities = acc:GetEntityCount(),
        -- Raw counts over the window. perfmon prints warns and fails per second.
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

    -- See above: an empty sample in Accumulate() is a SIGFPE.
    if data:GetDurationMs() <= 0 then return end

    if not perfAcc then
        perfAcc = ServerPerformanceData()
        -- The window starts here, so its tick count and its engine samples
        -- cover the same span.
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

local function PerfWindowsSince(sinceId)
    local windows = { }
    for _, w in ipairs(perfWindows:ToTable()) do
        if w.id > sinceId then
            table.insert(windows, w)
        end
    end
    return windows
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
        -- 09-27 and later; follows a runtime `bwlimit` (REQUIREMENTS item 10).
        bw_limit = Server.GetBwLimit and tonumber((select(2, pcall(Server.GetBwLimit)))) or nil,
    }
end

-- improved-webadmin: the log tail (item 9 above).
--
-- io.open reaches only mounted roots, so the log is readable when the engine
-- writes it into the config directory: -logdir equal to -config_path, or
-- neither flag, the default layout. Measured on the rig (09-26, REQUIREMENTS
-- item 7): what a read returns is fresh, never ended mid-line in 5404 reads
-- under load, and costs about 0.2 ms for 64 KB and 0.7 ms for 256 KB. The
-- engine serves a 16 MB reply without complaint, so the cap is ours: a reply
-- is a poll, not a download.
--
-- Offsets are bytes and every line carries its own, so a client merges replies
-- without duplicates and pages back from its first line. The header's Date and
-- Time name the file: a restart moves the old file to log-Server.old.txt and
-- starts a new one, which can be longer than the cursor by the time anyone
-- asks. A file shorter than the cursor was cut. Either way the reply is a
-- fresh tail, marked `reset`, rather than bytes read from the wrong place.
local kLogPath = "config://log-Server.txt"
local kLogTailBytes = 64 * 1024
local kLogMaxBytes = 256 * 1024

local function LogRead(f, from, to)
    if to <= from then return "" end
    f:seek("set", from)
    return f:read(to - from) or ""
end

-- "09/28/2026 02:50:11 AM" from the header, or "" for a file without one.
-- The engine writes it to the second; a restart takes longer than that.
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

-- The bytes from `from` to the end of the file, as lines, from the first line
-- that starts at or after `from` unless `from` is a line start already.
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
    -- A line longer than the cap would hold the cursor still forever. Serve
    -- the cap's worth of it as a line and go on.
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
            -- One line longer than a page: serve it cut rather than nothing.
            return from, before, { { off = from, text = text } }, false
        end
    end
    local lines = LogLines(text, from)
    return from, before, lines, false
end

-- Is config://log-Server.txt the file this server is writing? It opens just
-- as well when it is a copy an earlier run left behind with -logdir pointing
-- here, and then it is frozen: found on the rig, 2026-09-28, where a boot with
-- -logdir elsewhere served the previous run's log as if it were live. The
-- engine writes a line to the log before Shared.Message returns (measured:
-- item 7), so print one and look for it, through a handle opened after the
-- print. Once per map load, on the first getlog; the line says why it is
-- there. Around the console tee, which it would only clutter.
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

    -- Before the open: a handle sees the file as it was when it was opened
    -- (measured on the rig: the check's own line, written after the open,
    -- was not in that read), and the first reply should show that line.
    local checked, live = pcall(CheckLogIsLive)

    local opened, f, err = pcall(io.open, kLogPath, "rb")
    if not opened or not f then
        -- A stale copy that was deleted reads as missing, not as stale.
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

-- improved-webadmin: the engine's own reports from the log, for `getperf` (item 8
-- above). Some of what the Performance tab wants is printed by the engine
-- straight into log-Server.txt and never passes through Lua. Measured on the
-- rig, 09-27 engine (docs/REQUIREMENTS.md item 10):
--
--   * `tickstat N` prints one bare `TICKSTAT| ...` line every N seconds, with
--     no timestamp, even with nobody on; it survives a map change. So a line
--     is stamped with the time this scan found it, and the scan runs every
--     kEngineScanSeconds to keep that close. There is no backfill at a map
--     load: an unstamped line from before it would land at the wrong time.
--   * A player whose updates keep hitting bwlimit logs
--     `client N: snapshot rate A -> B/s (...)`; a bwlimit too small for a full
--     game logs a warning naming the value that avoids it.
--   * The `perfmon:` block is printed only when someone types `perfmon`, and
--     covers the last second.
--
-- Lines are recognised only by a match anchored at both ends, and a TICKSTAT
-- line only when most of its segments parse, so a line that merely starts
-- with a player's name (`<name> connected.`) cannot pass for one. A segment
-- the parser does not know -- a later engine adding one -- is counted in
-- `unparsed` rather than failing the line.
local kEngineScanSeconds = 2
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

-- One per segment of the format string in server_linux, in order.
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

-- Read what the engine wrote since the last scan. The first scan after a map
-- load starts at the end of the file (see above).
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
        if size - engineCursor > kLogMaxBytes then
            -- Far behind (a hitch longer than any scan interval): the latest
            -- stretch only, from a line start.
            local from = size - kLogMaxBytes
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

-- `getperf`'s `engine`: what the scans found since `sinceId`.
local function EngineReport(sinceId)
    -- As getlog does: a copy an earlier run left in the config directory
    -- opens as well as the live file, and would never grow.
    local checked, live = pcall(CheckLogIsLive)
    -- The server's clock, so a client judges "is tickstat still logging"
    -- against it rather than against its own.
    local report = { last_id = nextEngineId - 1, now = Shared.GetSystemTime() }
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
    report.tickstats = EngineSince(engineTickstats, sinceId, { })
    report.perfmon = EngineSince(enginePerfmon, sinceId, { })
    report.events = EngineSince(engineEvents, sinceId, { })
    return report
end

Shared.SetWebRoot("web")

--
-- Returns a list of all of the mods installed on the server (not necessarily active)
--
-- improved-webadmin: `active` says which are mounted now, so a client need not
-- guess from the map cycle -- the engine mounts two hotfix mods the cycle does
-- not name, and a map's own mods only with that map. Active ids are spelled
-- as GetModId spells them (measured on 09-26); GetModTitle takes only the
-- installed index, as ServerStats.lua notes, hence the set.
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

    -- improved-webadmin: Shine's gags, under its basecommands plugin. Read through
    -- its own IsClientGagged, which also expires a timed gag.
    local gags = GetShinePlugin("basecommands")
    if gags and type(gags.IsClientGagged) ~= "function" then
        gags = nil
    end

    -- improved-webadmin: Family Sharing, from the 09-26 beta engine on (its
    -- CHANGELOG). Looked up per request: a stock engine has neither function,
    -- and then the keys stay out of the blob.
    local getShared = Server.GetIsFamilyShared
    local getOwner = Server.GetOwnerUserId

    -- improved-webadmin: one of ScoringMixin's numbers, or nil when the player has
    -- no such method, it errors or it is not a number.
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
                -- improved-webadmin: a real boolean, like `iscomm` beside it. Stock
                -- sends tostring()'s "true"/"false" (CONSTRAINTS item 4).
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
            -- improved-webadmin: beta engine only. Bots, the listen host and LAN
            -- players always read as not shared (CHANGELOG).
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
            -- improved-webadmin: moves the server rejected. Time-credit rejections
            -- usually mean a modified client; "other" can be a poor connection
            -- (CHANGELOG). ServerClient methods, also beta only.
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
            -- improved-webadmin: Hive skill, as the server holds it for ranking and
            -- team balance (ScoringMixin; under UWE Hotfix 344, from Steam
            -- User Stats). Marines play at skill + offset and aliens at skill -
            -- offset; the commander's pair works the same way. Out of the blob
            -- for a player without them.
            local skill = skillOf(player, "GetPlayerSkill")
            if skill then
                playerData.skill = skill
                playerData.skill_offset = skillOf(player, "GetPlayerSkillOffset")
                playerData.comm_skill = skillOf(player, "GetCommanderSkill")
                playerData.comm_skill_offset = skillOf(player, "GetCommanderSkillOffset")
            end
            table.insert(playerList, playerData)
            
        end
        
    end
    
    local marineRes, alienRes = GetTeamResourceCount()
    local gamestarted = GetGamerules():GetGameStarted()
    local gametime = gamestarted and math.floor(Shared.GetTime() - GetGamerules():GetGameStartTime()) or 0
    
    return
    {
        webdomain = "[[webdomain]]",
        webport = "[[webport]]",
        -- improved-webadmin: real booleans, as above.
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
        -- improved-webadmin: absent on a stock server, which is how a panel knows.
        mod_version = kModVersion,
        -- improved-webadmin: the reserved slot amount cannot exceed it.
        max_players = Server.GetMaxPlayers(),
        -- improved-webadmin: when this map loaded, Unix seconds: the Lua VM is
        -- rebuilt at a map change, so this is that change's time. The panel
        -- shows it rather than timing a change it may not have seen.
        map_loaded_at = perfLoadedAt,
        -- improved-webadmin: absent when Shine is not loaded.
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

-- improved-webadmin: the map cycle. CONSTRAINTS items 12 and 13.

local kMapCycleFile = "config://MapCycle.json"

-- table.copyDict (Table.lua:441) computes a deep copy and then stores the
-- original, so hex-encoding its result rewrote the live cycle. The metatable
-- is kept because dkjson uses it to tell an empty object from an empty array.
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

-- The cycle rotation will actually use: MapCycle_CycleMap and sv_changemap
-- read the file, not the table loaded with the map, so a hand edit shows up
-- here at once. Read directly because LoadConfigFile prints a line on every
-- call, which would land in the console capture. Nil when the file is missing
-- or does not parse as a cycle.
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
            -- through. Anything else must convert, or it is written as a
            -- string the game then skips or mounts as garbage.
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

-- Why a cycle cannot be written, or nil when it can. Vanilla wrote anything
-- that parsed and errored on a cycle without `maps`, answering 200 either way.
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

-- What Shine's mapvote will do with the cycle. Its options are read from the
-- cycle once, at plugin start, so an edit reaches the vote at the next map.
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
        -- The plugin's own value can differ from its config per map.
        round_limit = tonumber(plugin.RoundLimit) or tonumber(config.RoundLimit) or 0,
        next_map = nextMap,
        options = options,
    }

end

-- improved-webadmin: the workshop search. CONSTRAINTS item 2, measured on 09-26
-- (REQUIREMENTS item 4). Server.SearchWorshop answers at most 50 hits and
-- ignores its page: pages 1, 2, 3 and 500 were the same 50. Its callback gets
-- one table, and an empty one both for no matches and for a search Steam
-- failed (NoConnection, with the rig offline), so an empty result is not an
-- error and must not be reported as one. What vanilla got wrong and this
-- fixes: a search that never answers restarted silently forever, a missing
-- `searchtext` never started a search at all, a `p` that is not a number
-- errored (an empty 200), and "a" page 11 shared a cache key with "a1" page 1.

local kWorkshopLimit = 50           -- the most SearchWorshop answers, measured
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

        -- A search given up on, and since restarted, must not answer for the
        -- new one.
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
                -- There may be more matches than the engine hands over.
                capped = #items >= kWorkshopLimit,
            }),
        }

    end)

    return json.encode({ loading = true, elapsed = 0 })

end

-- improved-webadmin: installmod says what it did. Server.InstallMod returns nothing
-- and drops what it cannot parse without a word: `zz`, `0` and an empty id
-- left no trace in the log, and `-5` became mod 18446744073709551611, which
-- Steam then reported as not found (measured on 09-26). So what is not a plain
-- hex id is refused before the call. Whether a download worked shows only in
-- getinstalledmodslist: a mod is listed once it is downloaded and unpacked,
-- under its real title, and never before.
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

-- improved-webadmin: the ranked-mod whitelist (docs/CONSTRAINTS.md item 17, item 10 above).
--
-- A mod that is not on it turns ranking off. The engine reads it at boot:
-- it is the "Required items" of an unlisted Workshop item, fetched in one
-- query with the hotfix list (whose required items, the hotfix mods, are
-- never checked). libSpark_Network.so hard-codes the items per branch
-- (ModServices::s_LiveModIds); Lua can read only the hotfix list's id, and
-- the server has no call that lists an item's children. Steam's keyless API
-- answers "not found" for unlisted items, so the mod reads the item's public
-- page instead, the same 115 ids the keyed API gives (2026-10-08).
--
-- Ids are decimal strings, as Steam spells them. The panel compares them with
-- the hex ids the rest of the API uses.
local kWhitelistPage = "https://steamcommunity.com/sharedfiles/filedetails/?id="
local kWhitelistFile = "config://improved-webadmin/whitelist.json"
local kWhitelistFileVersion = 1
local kWhitelistMaxAge = 60 * 60    -- read Steam again once the copy is older
local kWhitelistRetrySeconds = 5 * 60
local kWhitelistTimeout = 30
local kWhitelistMaxItems = 2000

-- What ModServices.GetHotfixListModId() returns -> that branch's whitelist.
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

-- The ids in a Workshop page's "Required items", in page order. Each one is an
-- <a href=".../filedetails/?id=N"><div class="requiredItem">title</div></a>,
-- back to back after the block's opening tag; the first thing that is not one
-- ends the list. Nil when the page has no such block.
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

    -- One file, rewritten whole: a torn write fails here and costs one read
    -- from Steam, which is all the file saves.
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

-- Read one item's page; callback(ids) or callback(nil, why).
local function FetchRequiredItems(id, callback)

    local ok, err = pcall(Shared.SendHTTPRequest, kWhitelistPage .. id, "GET", function(page)
        local ids = ParseRequiredItems(page)
        if ids then
            callback(ids)
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

    -- A read given up on, and since restarted, must not answer for the new one.
    local function current()
        return whitelistFetch ~= nil and whitelistFetch.generation == generation
    end
    local function fail(why)
        if not current() then return end
        whitelistFetch = nil
        whitelistError, whitelistErrorAt = why, Shared.GetSystemTime()
        Log("improved-webadmin: whitelist not read: %s", why)
    end

    -- One page after the other: concurrent HTTPS is what aborted the 09-03
    -- libcurl (crash-20260905-0329).
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

    -- Another branch's copy is no copy at all.
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

-- improved-webadmin: what a request with no parameters at all gets (CONSTRAINTS
-- item 6). That is a browser at the address the boot log prints, which used
-- to be handed every player's name, Steam id and IP. The engine passes Lua
-- neither the path nor the headers, so this cannot tell `/` from a missing
-- file, nor a browser from a script: both get this page, which holds no
-- server data. A script asking for state sends `request=json`, as both panels
-- do. Lua returns only a type and a body, so no HTTP redirect.
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

-- whitelist probe (docs/CONSTRAINTS.md item 17): what Shared.SendHTTPRequest hands its callback
-- on success and on each kind of failure, and what
-- ModServices.GetHotfixListModId() returns. The calls run one after the
-- other, never two at once. Top-level, not in the OnWebRequest branch: with
-- this code nested in the branch the engine's Lua preprocessor stopped after
-- OnWebRequest and the rest of the file was dropped (2026-10-08).
local whitelistProbe

local function WhitelistProbeRecord(name, nextStep)
    return function(...)
        local n = select(string.char(35), ...)
        local args = { }
        for k = 1, n do
            local v = select(k, ...)
            args[k] = { type = type(v),
                        len = type(v) == "string" and #v or nil,
                        head = type(v) == "string" and string.sub(v, 1, 80) or tostring(v) }
        end
        whitelistProbe.results[name] = { n = n, args = args,
                                         after = Shared.GetTime() - whitelistProbe.started }
        nextStep()
    end
end

local kWhitelistProbeCalls = {
    { "page", "https://steamcommunity.com/sharedfiles/filedetails/?id=2633436686" },
    { "refused", "https://127.0.0.1:9/" },
    { "nxdomain", "https://improved-webadmin-probe.invalid/" },
    { "http404", "https://steamcommunity.com/improved-webadmin-probe-404" },
}

local function WhitelistProbeStep(i)
    local c = kWhitelistProbeCalls[i]
    if c then
        Shared.SendHTTPRequest(c[2], "GET",
            WhitelistProbeRecord(c[1], function() WhitelistProbeStep(i + 1) end))
        return
    end
    FetchRequiredItems("1", function(ids, why)
        whitelistProbe.results.no_such_item = { ids = ids and #ids, why = why,
            after = Shared.GetTime() - whitelistProbe.started }
        whitelistProbe.done = true
    end)
end

local function WhitelistProbe(reset)
    if whitelistProbe and not reset then return whitelistProbe end
    whitelistProbe = { started = Shared.GetTime(), results = { } }
    local okId, rawId = pcall(ModServices.GetHotfixListModId)
    whitelistProbe.hotfix_list_id_raw = okId and (type(rawId) .. " " .. tostring(rawId))
                                        or ("error " .. tostring(rawId))
    whitelistProbe.hotfix_list_id = GetHotfixListId()
    WhitelistProbeStep(1)
    return whitelistProbe
end

local function OnWebRequest(actions)
    if actions.request == "whitelistprobe" then
        return "application/json", json.encode(WhitelistProbe(actions.reset ~= nil))
    end

    -- improved-webadmin: no parameters at all, so no client of the API.
    if type(actions) ~= "table" or next(actions) == nil then
        return "text/html", kRootPage
    end

    -- improved-webadmin: before anything a request runs can print.
    EnsureServerAdminPrintWrapped()

    -- improved-webadmin: before a request can ban someone who has left.
    EnsureShineAddBanWrapped()

    -- improved-webadmin: before a request can send chat.
    EnsureChatWrapped()

    -- improved-webadmin: run a command and return what it printed.
    if actions.request == "runcommand" then

        local command = actions.cmd or ""
        local firstId = nextConsoleId
        local started = Shared.GetTime()

        Shared.ConsoleCommand(command)

        local elapsed = Shared.GetTime() - started
        local produced = ConsoleLinesSince(firstId - 1)

        -- The audit line is already labelled; its presence is the receipt.
        local dispatched = false
        for _, line in ipairs(produced) do
            if line.src == "audit" then
                dispatched = true
            end
        end
        local lines = produced

        return "application/json", json.encode({
            cmd = command,
            -- True when the command was dispatched as an admin command. False
            -- means either a plain console command or no such command -- the
            -- server does not distinguish those, and neither should a client.
            dispatched = dispatched,
            elapsed = elapsed,
            lines = lines,
            last_id = nextConsoleId - 1,
        })

    -- improved-webadmin: the console stream, everything captured since `since`.
    elseif actions.request == "getconsole" then

        local since = tonumber(actions.since) or 0
        local lines = ConsoleLinesSince(since)

        return "application/json", json.encode({
            lines = lines,
            last_id = nextConsoleId - 1,
            -- Lines that fell out of the ring before anyone read them, and
            -- lines dropped as engine noise. Both are reported rather than
            -- silently vanishing.
            dropped = droppedConsoleLines,
            filtered = filteredConsoleLines,
            buffer_size = kConsoleBufferSize,
        })

    -- improved-webadmin: the bans in force, from the table that decides them.
    elseif actions.request == "getbans" then

        local source, now, bans = GetBansInForce()
        return "application/json", json.encode({
            source = source,
            -- The server's clock, so a client measures time left against it
            -- rather than against its own.
            now = now,
            bans = bans,
        })

    -- improved-webadmin: players seen in the last day, connected or not.
    elseif actions.request == "getrecentplayers" then

        return "application/json", json.encode(GetRecentPlayers())

    -- improved-webadmin: the engine's log, since a byte offset (item 9 above).
    elseif actions.request == "getlog" then

        return "application/json", json.encode(GetLog(actions))

    end

    if actions.request == "getbanlist" then

        -- CONSTRAINTS item 9. The game prunes expired bans only when the ban
        -- file is loaded or saved (ServerAdminCommands.lua:312), so between
        -- those moments getbanlist reports bans that stopped blocking anyone
        -- some time ago -- and the Unban button on them does nothing, because
        -- there is nothing left to unban. Report what is actually in force.
        local now = Shared.GetSystemTime()
        local inForce = { }
        for _, ban in ipairs(GetBannedPlayersList()) do
            if ban.time == 0 or ban.time > now then
                table.insert(inForce, ban)
            end
        end

        return "application/json", json.encode(inForce)
    elseif actions.request == "getreservedslots" then

        -- improved-webadmin: when Shine's reservedslots plugin is on, it sets the
        -- slot count and grants access by permission; the vanilla list is not
        -- what is enforced. Its count rides along, and the 2012 panel ignores
        -- the extra key.
        local data = GetReservedSlotData()
        local plugin = GetShinePlugin("reservedslots")
        if plugin and type(plugin.Config) == "table" then
            data.shine = { slots = tonumber(plugin.Config.Slots) or 0 }
        end
        return "application/json", json.encode(data)
    elseif actions.request == "getperfdata" then
        return "application/json", json.encode(perfDataBuffer:ToTable())

    -- improved-webadmin: performance windows since `since` (item 8 above).
    elseif actions.request == "getperf" then

        local since = tonumber(actions.since) or 0
        return "application/json", json.encode({
            -- The engine's log lines, read with their own cursor.
            engine = EngineReport(tonumber(actions.esince) or 0),
            window_s = kPerfWindowSeconds,
            capacity = kMaxPerfWindows,
            loaded_at = perfLoadedAt,
            map = Shared.GetMapName(),
            config = PerfConfig(),
            windows = PerfWindowsSince(since),
            last_id = nextPerfWindowId - 1,
        })

    elseif actions.request == "getchatlist" then

        -- improved-webadmin: with `since`, this mod's 200-entry ring, from that id
        -- on. Without it, the game's 20 exactly as stock serves them: the
        -- 2012 panel polls that shape.
        local since = tonumber(actions.since)
        if since then
            return "application/json", json.encode({
                entries = ChatSince(since),
                last_id = nextChatId - 1,
                -- Entries that fell out of the ring before anyone read them.
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

        -- improved-webadmin: the file rotation reads, and a copy that is really a
        -- copy. Json doesn't really have 64 numbers just use the old hex format
        local mapcycle = ReadMapCycleFile() or DeepCopy(MapCycle_GetMapCycle())
        return "application/json", json.encode(MapCycleForClient(mapcycle))

    elseif actions.request == "setmapcycle" then

        -- improved-webadmin: refuse what the game cannot use, without writing it,
        -- and answer with what the file holds afterwards. Vanilla answered an
        -- empty 200 to all of it; the 2012 panel ignores the body either way.
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

    -- improved-webadmin: Shine's mapvote, as far as it concerns the cycle.
    elseif actions.request == "getmapvote" then

        return "application/json", json.encode(GetMapVote())

    elseif actions.request == "setreservedslotamount" then
    
        -- CONSTRAINTS item 7. Vanilla calls SetReservedSlotAmount(amount)
        -- against a function declared (client, amount), so the amount landed
        -- in `client`, `amount` was nil, and the guard rejected every call
        -- while the request still answered 200.
        SetReservedSlotAmount(nil, actions.amount)
        return ""
        
    elseif actions.request == "installmod" then

        -- improved-webadmin: a reply that says what was done. The 2012 panel
        -- ignores the body, so it is unaffected.
        return "application/json", json.encode(InstallMod(actions.modid))

    -- improved-webadmin: the ranked-mod whitelist, as Steam last gave it.
    elseif actions.request == "getwhitelist" then

        return "application/json", json.encode(GetWhitelist())

    elseif actions.request == "getmods" then

        -- improved-webadmin: see SearchWorkshop. The replies keep `loading` and
        -- `items`, the two keys the 2012 panel reads.
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

    -- improved-webadmin: catch a replacement (Shine's, on its first tick) before an
    -- in-game command's output is lost from the console stream.
    EnsureServerAdminPrintWrapped()

    -- improved-webadmin: name absent players' bans under Shine (see above).
    EnsureShineAddBanWrapped()

    -- improved-webadmin: record chat for getchatlist's cursor (see above).
    EnsureChatWrapped()

    -- improved-webadmin: persist a reserved slot removal (see above).
    SaveReservedSlotsIfDirty()

    -- improved-webadmin: keep the recent-players list and its file current.
    UpdateRecentPlayers()

    -- improved-webadmin: the windows `getperf` serves.
    UpdatePerfWindows()

    -- improved-webadmin: and the engine's own lines from the log.
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

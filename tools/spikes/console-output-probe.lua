-- ======= Copyright (c) 2012, Unknown Worlds Entertainment, Inc. All rights reserved. ==========
--
-- lua\ServerWebAPI.lua
--
--    Created by:   Brian Cronin (brianc@unknownworlds.com)
--
-- ========= For more information, visit us at http://www.unknownworlds.com =====================

Script.Load("lua/RingBuffer.lua")

-- SPIKE: can the mod read back what a console command printed?
--
-- Generated from the vanilla ns2/lua/ServerWebInterface.lua with two probe
-- request types added. Not shipped -- this exists to answer REQUIREMENTS.md
-- item 5, "RCON returns nothing", before the console tab is designed.
--
-- ServerAdminPrint is a plain Lua global defined in core/lua/ServerAdmin.lua
-- (not ns2/lua, which is why the first search missed it), and no caller takes
-- a local alias of it, so wrapping it here should be seen by every command.
-- What this measures:
--
--   /?request=probe            what is writable, and where each print global
--                              actually comes from
--   /?request=runcmd&cmd=...   run a command with capture on, and return what
--                              each print path emitted while it ran
--
-- Copy to the mod's mount directory as lua/ServerWebInterface.lua, put the mod
-- in the map cycle, change map.

-- ---------------------------------------------------------------- capture

-- Non-nil while a command is running: a list of { src, msg } in order.
local capturing = nil

local function capture(src, msg)
    if capturing then
        table.insert(capturing, { src = src, msg = tostring(msg) })
    end
end

-- What we could learn about each print path at load time.
local probeNotes = { }

local originalServerAdminPrint = ServerAdminPrint
probeNotes.ServerAdminPrint_type_at_load = type(ServerAdminPrint)

if type(originalServerAdminPrint) == "function" then
    function ServerAdminPrint(client, message)
        capture("ServerAdminPrint", message)
        return originalServerAdminPrint(client, message)
    end
    probeNotes.ServerAdminPrint_wrapped = true
else
    probeNotes.ServerAdminPrint_wrapped = false
end

-- Shared is an engine-provided table; assigning into it may or may not be
-- allowed. Same question for the Print and Log globals.
local function tryWrap(name, get, set)
    local ok, err = pcall(function()
        local original = get()
        if type(original) ~= "function" then
            error("not a function: " .. type(original))
        end
        set(function(...)
            capture(name, (select("#", ...) > 0) and select(1, ...) or "")
            return original(...)
        end)
    end)
    probeNotes[name .. "_wrapped"] = ok and true or false
    if not ok then probeNotes[name .. "_error"] = tostring(err) end
end

tryWrap("Shared.Message", function() return Shared.Message end,
        function(f) Shared.Message = f end)
tryWrap("Print", function() return Print end, function(f) Print = f end)
tryWrap("Log", function() return Log end, function(f) Log = f end)

-- Where does each of these actually come from? debug.getinfo answers it if
-- the sandbox kept the debug library.
local function whereIs(fn)
    if type(fn) ~= "function" then return type(fn) end
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return "debug library unavailable"
    end
    local info = debug.getinfo(fn, "S")
    if not info then return "no info" end
    return string.format("%s:%s", tostring(info.short_src),
                         tostring(info.linedefined))
end


local kMaxPerfDatas = 30

-- How often to log performance data in seconds.
local kLogPerfDataRate = 60

-- The last kMaxPerfDatas performance samples (one is taken every kLogPerfDataRate seconds).
local perfDataBuffer = CreateRingBuffer(kMaxPerfDatas)

-- The last time performance data was sampled.
local lastPerfDataTime = 0

-- Stores cached workshop mod results for 60 seconds.
local getmodsCache = { }

Shared.SetWebRoot("web")

--
-- Returns a list of all of the mods installed on the server (not necessarily active)
--
local function GetModList()

    local returnList = { }
    
    for i = 1, Server.GetNumMods() do
        local id   = Server.GetModId(i)
        local name = Server.GetModTitle(i)
        returnList[i] = { id = id, name = name }
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
                isbot = tostring(client:GetIsVirtual()),
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
        cheats  = tostring(Shared.GetCheatsEnabled()),
        devmode = tostring(Shared.GetDevMode()),
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
        game_time = gametime
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

local function OnWebRequest(actions)

    if actions.request == "probe" then

        return "application/json", json.encode({
            notes = probeNotes,
            debug_library = type(debug),
            where = {
                ServerAdminPrint = whereIs(originalServerAdminPrint),
                Shared_Message   = whereIs(Shared.Message),
                Print            = whereIs(Print),
                Log              = whereIs(Log),
            },
            ConsoleCommand = type(Shared.ConsoleCommand),
        })

    elseif actions.request == "runcmd" then

        local started = Shared.GetTime()
        capturing = { }
        Shared.ConsoleCommand(actions.cmd or "")
        local lines = capturing
        capturing = nil

        return "application/json", json.encode({
            cmd = actions.cmd,
            -- Seconds spent inside Shared.ConsoleCommand. If the command runs
            -- synchronously this is tiny and `lines` is already filled; if it
            -- is queued, `lines` comes back empty.
            elapsed = Shared.GetTime() - started,
            line_count = #lines,
            lines = lines,
        })

    end

    if actions.request == "getbanlist" then
        return "application/json", json.encode(GetBannedPlayersList())
    elseif actions.request == "getreservedslots" then
        return "application/json", json.encode(GetReservedSlotData())
    elseif actions.request == "getperfdata" then
        return "application/json", json.encode(perfDataBuffer:ToTable())
    elseif actions.request == "getchatlist" then
        return "application/json", Server.recentChatMessages and json.encode(Server.recentChatMessages:ToTable()) or "{ }"
    elseif actions.request == "getinstalledmodslist" then
        return "application/json", json.encode(GetModList())
    elseif actions.request == "getmaplist" then
        return "application/json", json.encode(GetMapList())
    elseif actions.request == "getmapcycle" then
        local mapcycle = table.copyDict(MapCycle_GetMapCycle())

        -- Json doesn't really have 64 numbers just use the old hex format
        ModsIdsToHex(mapcycle)
        for _, map in ipairs(mapcycle.maps) do
            ModsIdsToHex(map)
        end
        
        return "application/json", json.encode(mapcycle)
    elseif actions.request == "setmapcycle" then
        local mapcycle = json.decode(actions.data)

        if not mapcycle then
            Log("setmapcycle web request passed bad json data")
            return
        end

        ModIdsFromHex(mapcycle)
        for _, map in ipairs(mapcycle.maps) do
            ModIdsFromHex(map)
        end

        MapCycle_SetMapCycle(mapcycle)
        return ""
        
    elseif actions.request == "setreservedslotamount" then
    
        SetReservedSlotAmount(actions.amount)
        return ""
        
    elseif actions.request == "installmod" then
    
        Server.InstallMod(actions.modid)
        return ""
        
    elseif actions.request == "getmods" then

        local searchtext = actions.searchtext
        local page = 1
        local key

        if actions.p then
            page = tonumber(actions.p)
        end

        if type(searchtext) == "string" then
            key = searchtext..page
        else
            key = page
        end

        local timeRequested = Shared.GetTime()

        if getmodsCache[key] then
            local startedLoading = getmodsCache[key].startedLoading
            if startedLoading then
                -- Request times out after 30 seconds
                if timeRequested - startedLoading < 30 then
                    return "application/json", '{"loading": true}'
                end
            else
                -- Cache workshop mods for 60 seconds
                if timeRequested - getmodsCache[key].cached_at < 60 then
                    return "application/json", getmodsCache[key].result
                else
                    getmodsCache[key] = nil
                end
            end
        end

        getmodsCache[key] = { startedLoading = timeRequested }

        if searchtext then
            Server.SearchWorshop(searchtext, page,  function(modResults)
                local result = {}

                if modResults then
                    for _, mod in ipairs(modResults) do
                        mod.id = string.format("%x", mod.id)
                    end
                    result.items = modResults
                end

                result = json.encode(result)

                getmodsCache[key] = {
                    cached_at = Shared.GetTime(),
                    result = result
                }
            end)
        end

        return "application/json", '{"loading": true}'
        
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

    if Shared.GetSystemTime() - lastPerfDataTime >= kLogPerfDataRate then
    
        local playerRecords = Shared.GetEntitiesWithClassname("Player")
        local entCount = Shared.GetEntitiesWithClassname("Entity"):GetSize()
        local newData = { players = playerRecords:GetSize(), tickrate = Server.GetFrameRate(), time = Shared.GetSystemTime(), ent_count = entCount }
        perfDataBuffer:Insert(newData)
        
        lastPerfDataTime = Shared.GetSystemTime()
        
    end
    
end

Event.Hook("UpdateServer", UpdateServerWebInterface)
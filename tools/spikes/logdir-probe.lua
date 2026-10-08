-- ======= Copyright (c) 2012, Unknown Worlds Entertainment, Inc. All rights reserved. ==========
--
-- lua\ServerWebAPI.lua
--
--    Created by:   Brian Cronin (brianc@unknownworlds.com)
--
-- ========= For more information, visit us at http://www.unknownworlds.com =====================

Script.Load("lua/RingBuffer.lua")

-- SPIKE: can the mod read the server log through config://?
--
-- Generated from the vanilla ns2/lua/ServerWebInterface.lua with probe request
-- types added. Answers REQUIREMENTS.md item 7 route 1: point -logdir at the
-- -config_path directory so the log lands where io.open can reach it.
--
-- io.open resolves only against Spark's virtual filesystem, and absolute paths
-- are refused, so the question is whether config:// covers a -logdir that is
-- the same directory -- and, if it does, whether what it reads is *fresh*.
-- A tail that lags behind by a write buffer is not a log tail.
--
--   /?request=logprobe          try every candidate path, report what opened
--   /?request=logtail&bytes=N   last N bytes of the log, as lines
--   /?request=logfresh&cmd=...  tail, run a command, tail again: does the
--                               command's own log line appear immediately?

local kProbePaths = {
    "config://log-Server.txt",
    "config://logs/log-Server.txt",
    "log-Server.txt",
    "logs/log-Server.txt",
    "config://MapCycle.json",           -- control: known to exist, known readable
    "/srv/ns2/config/log-Server.txt",    -- control: absolute
}

local function probeOne(path)
    local result = { path = path }
    local ok, handle, err = pcall(io.open, path, "r")
    if not ok then
        result.opened = false
        result.error = "io.open raised: " .. tostring(handle)
        return result
    end
    if not handle then
        result.opened = false
        result.error = tostring(err)
        return result
    end
    result.opened = true
    local sizeOk, size = pcall(function() return handle:seek("end") end)
    result.size = sizeOk and size or nil
    pcall(function() handle:seek("set", 0) end)
    local readOk, head = pcall(function() return handle:read(120) end)
    result.head = readOk and head or nil
    handle:close()
    return result
end

-- Last `bytes` bytes of a file, split into lines.
local function tailFile(path, bytes)
    local handle = io.open(path, "r")
    if not handle then return nil, "could not open " .. path end
    local size = handle:seek("end")
    local from = math.max(0, size - bytes)
    handle:seek("set", from)
    local text = handle:read("*a") or ""
    handle:close()

    local lines = { }
    for line in string.gmatch(text, "[^\r\n]+") do
        table.insert(lines, line)
    end
    return { size = size, read_from = from, lines = lines }
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

    if actions.request == "logprobe" then

        local results = { }
        for _, path in ipairs(kProbePaths) do
            table.insert(results, probeOne(path))
        end
        return "application/json", json.encode({
            io_open = type(io.open),
            io_lines = type(io.lines),
            results = results,
        })

    elseif actions.request == "logtail" then

        local bytes = tonumber(actions.bytes) or 2048
        local tail, err = tailFile(actions.path or "config://log-Server.txt", bytes)
        if not tail then
            return "application/json", json.encode({ error = err })
        end
        return "application/json", json.encode(tail)

    elseif actions.request == "logfresh" then

        -- The freshness test: what the log holds, then a command, then what it
        -- holds now. If the command's own audit line is not in `after`, the
        -- file is buffered and a tail of it lags reality.
        local path = actions.path or "config://log-Server.txt"
        local before = tailFile(path, 512)
        Shared.ConsoleCommand(actions.cmd or "sv_cheats 0")
        local after = tailFile(path, 512)
        return "application/json", json.encode({
            cmd = actions.cmd,
            size_before = before and before.size or nil,
            size_after = after and after.size or nil,
            grew = (before and after) and (after.size > before.size) or false,
            tail_after = after and after.lines or nil,
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
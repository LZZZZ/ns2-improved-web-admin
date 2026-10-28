-- Off-rig harness for the mod's fixes to the game's bans and reserved slots
-- (lua/ServerWebInterface.lua, top). The game half is a model of
-- ServerAdminCommands.lua in builds 344 and 345: bans keyed by number in a
-- map that only gains entries, each holding its index in the list.
--
-- Usage: luajit tools/spikes/bans-harness.lua --core <core/lua>
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local MOD = REPO .. "lua/ServerWebInterface.lua"
local dkjson = dofile(opts.core .. "dkjson.lua")

local clock = { now = 1790000000 }

local function NewVM(initialBans)
    local hooks = { }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "no files in this harness" end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = {
        Message = function() end, SetWebRoot = function() end,
        GetSystemTime = function() return clock.now end,
        GetTime = function() return 0 end,
        GetEntitiesWithClassname = function() return players end,
        GetSystemTimeReal = function() return clock.now end,
        GetServerPerformanceData = function() return {
            GetTimestamp = function() return 0 end,
            GetDurationMs = function() return 0 end,
        } end,
    }
    env.ientitylist = function(list) return ipairs(list) end
    local saves = { slots = 0, config = 0 }
    env.Server = {
        GetFrameRate = function() return 60 end,
        SaveReservedSlotsConfig = function() saves.slots = saves.slots + 1 end,
        SaveConfigSettings = function() saves.config = saves.config + 1 end,
    }

    -- The game's ServerAdminCommands.lua, which loads before the mod's file.
    local bans, map = initialBans, { }
    local function Regenerate()
        for i, ban in ipairs(bans) do ban.index = i; map[ban.id] = ban end
    end
    Regenerate()
    function env.UnbanUser(userId)
        local ban = map[userId]
        if not ban then return false end
        table.remove(bans, ban.index)
        Regenerate()
        return true
    end
    function env.GetIsUserBanned(userId)
        local ban = map[userId]
        return ban ~= nil and (ban.time == 0 or clock.now < ban.time)
    end
    function env.GetIsUserBannedPermanently(userId)
        local ban = map[userId]
        return ban ~= nil and ban.time == 0
    end
    function env.GetBannedPlayersList()
        local list = { }
        for _, ban in ipairs(bans) do
            table.insert(list, { name = ban.name, id = ban.id, reason = ban.reason, time = ban.time })
        end
        return list
    end
    env.table = setmetatable({ array = function() return { } end }, { __index = table })
    local ring = assert(loadfile(opts.core .. "RingBuffer.lua"))
    setfenv(ring, env)
    ring()

    local function Console_sv_unban(steamId) return env.UnbanUser(steamId) end
    env.Event.Hook("Console_sv_remove_reserved_slot", function() env.Server.SaveConfigSettings() end)

    local chunk = assert(loadfile(MOD))
    dofile(HERE .. "engine-stubs.lua")(env, dkjson)
    setfenv(chunk, env)
    chunk()

    local vm = { env = env, bans = function() return bans end, saves = saves }
    function vm.sv_unban(id) return Console_sv_unban(id) end
    function vm.console(name, ...) for _, fn in ipairs(hooks[name] or { }) do fn(nil, ...) end end
    function vm.tick() for _, fn in ipairs(hooks.UpdateServer) do fn(0.016) end end
    return vm
end

local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end

local function Bans()
    return {
        { id = 101, name = "Alice", reason = "a", time = 0 },
        { id = 102, name = "Bob", reason = "b", time = clock.now + 3600 },
        { id = 103, name = "Carol", reason = "c", time = 0 },
    }
end

local vm = NewVM(Bans())
check(vm.sv_unban("102") == true and #vm.bans() == 2, "sv_unban with the string id the console passes removes the ban")
check(not vm.env.GetIsUserBanned(102), "and the unbanned player may connect again")
check(vm.env.GetIsUserBanned(101) and vm.env.GetIsUserBannedPermanently(101), "the others stay banned, permanently")
check(vm.env.GetIsUserBanned(103), "including the one whose index moved")

check(vm.sv_unban("102") == false and #vm.bans() == 2, "unbanning the same id again removes nothing")
check(vm.bans()[1].id == 101 and vm.bans()[2].id == 103, "and the bans that took its place survive")

check(vm.sv_unban("not a number") == false and vm.sv_unban("999") == false, "an unknown or malformed id matches nothing")

vm = NewVM(Bans())
check(vm.env.GetIsUserBanned(102) and not vm.env.GetIsUserBannedPermanently(102), "a timed ban is in force, not permanent")
clock.now = clock.now + 3601
check(not vm.env.GetIsUserBanned(102), "and lets the player in once it expires")
clock.now = clock.now - 3601

-- Shine's GetBannedPlayersList has string ids and replaces the game's a
-- second after load; the connection check reads Shine's, the unban the game's.
vm = NewVM(Bans())
vm.env.GetBannedPlayersList = function() return { { id = "104", name = "Dan", reason = "d", time = 0 } } end
check(vm.env.GetIsUserBanned(104) and not vm.env.GetIsUserBanned(101), "under Shine, the connection check reads Shine's bans")
check(vm.sv_unban("101") == true and #vm.bans() == 2, "and sv_unban still edits the game's list")

vm = NewVM(Bans())
vm.console("Console_sv_remove_reserved_slot", "101")
check(vm.saves.config == 1 and vm.saves.slots == 0, "sv_remove_reserved_slot: the game saves the wrong file")
vm.tick()
check(vm.saves.slots == 1, "the next tick saves the reserved slots")
vm.tick()
check(vm.saves.slots == 1, "once")

print("all passed")

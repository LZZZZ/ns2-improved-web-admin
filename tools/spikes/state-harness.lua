-- Off-rig harness for the fields the mod adds to the state blob in
-- lua/ServerWebInterface.lua: Shine's `gagged`, the engine's Family Sharing
-- and rejected-move counts, Hive skill, and `ranking_active`.
--
-- Runs the shipped file under LuaJIT with the engine calls GetServerState
-- touches stubbed. Each case is a fresh VM with different answers. It checks
-- the logic -- Shine and ScoringMixin detected, keys left out rather than
-- guessed -- not the engine:
-- what the functions return for a real player is a rig question, and needs a
-- human (headless bots are deleted, docs/TESTING.md).
--
-- Usage: luajit tools/spikes/state-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"
local dkjson = dofile(CORE .. "dkjson.lua")

local function RingBuffer(n)
    local items = { }
    return {
        Insert = function(self, x) table.insert(items, x); if #items > n then table.remove(items, 1) end end,
        GetNumElements = function() return #items end,
        ToTable = function() return items end,
    }
end

-- A player entity and its ServerClient. `methods` replace ServerClient
-- methods.
local function Player(id, name, bot, methods)
    local client = {
        GetUserId = function() return id end,
        GetIsVirtual = function() return bot == true end,
        GetPing = function() return 40 end,
        GetMovesRejectedTimeCredit = function() return 0 end,
        GetMovesRejectedOther = function() return 0 end,
        addr = "192.0.2." .. (id % 200),
    }
    for k, v in pairs(methods or { }) do client[k] = v end
    local p = {
        client = client,
        GetName = function() return name end,
        GetTeamNumber = function() return 1 end,
        GetIsCommander = function() return false end,
        GetResources = function() return 10 end,
    }
    client.GetControllingPlayer = function() return p end
    return p
end

local function NewVM(opts)
    local hooks = { }
    local players = setmetatable(opts.players, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "no files in this harness" end }
    env.json = dkjson
    env.kDefaultPlayerName = "NSPlayer"
    env.Script = { Load = function() end }
    env.CreateRingBuffer = RingBuffer
    env.GetBannedPlayersList = function() return { } end
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = {
        Message = function() end, SetWebRoot = function() end,
        GetSystemTime = function() return 1790000000 end,
        GetTime = function() return 0 end,
        GetCheatsEnabled = function() return false end,
        GetDevMode = function() return false end,
        GetMapName = function() return "ns2_summit" end,
        GetEntitiesWithClassname = function() return players end,
        GetSystemTimeReal = function() return 1790000000 end,
        GetServerPerformanceData = function() return {
            GetTimestamp = function() return 0 end,
            GetDurationMs = function() return 0 end,
        } end,
    }
    env.ientitylist = function(list) return ipairs(list) end
    env.HasMixin = function() return false end
    env.GetEntitiesForTeam = function() return { } end
    env.table = setmetatable({ icount = function(t) return #t end }, { __index = table })
    local team = { GetNumPlayers = function() return 0 end }
    env.GetGamerules = function() return {
        GetGameStarted = function() return false end,
        GetTeam1 = function() return team end,
        GetTeam2 = function() return team end,
    } end
    env.Server = {
        GetFrameRate = function() return 60 end,
        GetOwner = function(p) return p.client end,
        GetClientAddress = function(c) return c.addr end,
        GetName = function() return "harness" end,
        GetMaxPlayers = function() return 16 end,
        GetIsFamilyShared = opts.GetIsFamilyShared,
        GetOwnerUserId = opts.GetOwnerUserId,
        GetIsRankingActive = opts.GetIsRankingActive,
    }
    env.IPAddressToString = function(a) return a end
    env.Shine = opts.Shine
    local chunk = assert(loadfile(MOD))
    dofile(HERE .. "engine-stubs.lua")(env, dkjson)
    setfenv(chunk, env)
    chunk()
    return function()
        local _, body = hooks.WebRequest[1]({ request = "json" })
        return dkjson.decode(body)
    end
end

local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end
local function byName(state, name)
    for _, p in ipairs(state.player_list) do if p.name == name then return p end end
end

-- The engine's defaults: nobody shared, nothing rejected, unranked.
local state = NewVM({ players = { Player(101, "Alice"), Player(0, "[BOT] Max", true) } })()
local a = byName(state, "Alice")
check(a and a.isbot == false and byName(state, "[BOT] Max").isbot == true, "isbot is a real boolean")
check(a.familyshared == false and a.owner_steamid == nil, "not shared: familyshared false, no owner id")
check(a.moves_rejected_time == 0 and a.moves_rejected_other == 0, "rejected moves: both counts, 0")
check(a.gagged == nil and state.shine == nil, "no Shine, no gagged and no shine key")
check(state.map_loaded_at == 1790000000, "map_loaded_at: when the VM, so the map, loaded")
check(state.ranking_active == false, "ranking_active false: the engine says unranked")
check(a.skill == nil and a.skill_offset == nil and a.comm_skill == nil,
      "no ScoringMixin, no skill keys")

-- Hive skill (P1): ScoringMixin's four numbers, as they are.
local alice, bot = Player(101, "Alice"), Player(0, "[BOT] Max", true)
alice.GetPlayerSkill = function() return 2400 end
alice.GetPlayerSkillOffset = function() return -150 end
alice.GetCommanderSkill = function() return 1800 end
alice.GetCommanderSkillOffset = function() return 40 end
bot.GetPlayerSkill = function() return 0 end
bot.GetPlayerSkillOffset = function() error("no hive data") end
state = NewVM({ players = { alice, bot } })()
a = byName(state, "Alice")
check(a.skill == 2400 and a.skill_offset == -150 and a.comm_skill == 1800
      and a.comm_skill_offset == 40, "skill, its offset, commander skill and its offset")
local m = byName(state, "[BOT] Max")
check(m.skill == 0 and m.skill_offset == nil, "an erroring offset leaves only its key out")
check(a.skill_tier == nil and m.skill_tier == nil, "no GetSkillTier, no skill_tier")

-- The skill tier: GetSkillTier()'s answer, without leaving its cache behind.
-- ScoringMixin's own body, with the engine calls it makes stubbed.
local function GetSkillTier(self)
    if self.GetIsVirtual and self:GetIsVirtual() then return -1 end
    if self:GetPlayerSkill() < 0 then return -2 end
    if not self.skillTier then
        self.skillTier = self.tierFor
    end
    return self.skillTier
end
local function Scored(id, name, skill, tierFor, bot)
    local p = Player(id, name, bot)
    p.GetPlayerSkill = function() return skill end
    p.GetSkillTier = GetSkillTier
    p.tierFor = tierFor
    if bot then p.GetIsVirtual = function() return true end end
    return p
end
local fresh, ruled = Scored(101, "Alice", 2400, 4), Scored(102, "Bea", 300, 1)
local nohive, bot2 = Scored(103, "Cid", -1, 3), Scored(0, "[BOT] Max", -1, 3, true)
local broken = Scored(104, "Dan", 900, 2)
broken.GetSkillTier = function() error("no hive data") end
ruled.skillTier = 0   -- the game asked first, before this player levelled up
state = NewVM({ players = { fresh, ruled, nohive, bot2, broken } })()
check(byName(state, "Alice").skill_tier == 4, "skill_tier is GetSkillTier()'s answer")
check(fresh.skillTier == nil, "and the answer is not left cached on the player")
check(byName(state, "Bea").skill_tier == 0 and ruled.skillTier == 0,
      "a tier the game already fixed is the one sent, and stays")
check(byName(state, "Cid").skill_tier == -2, "no skill: -2")
check(byName(state, "[BOT] Max").skill_tier == -1, "a bot: -1")
check(byName(state, "Dan").skill == 900 and byName(state, "Dan").skill_tier == nil,
      "an erroring GetSkillTier leaves only its key out")

-- A shared copy and rejected moves.
local moves = {
    GetMovesRejectedTimeCredit = function(self) return self:GetUserId() == 102 and 37 or 0 end,
    GetMovesRejectedOther = function() return 2 end,
}
state = NewVM({
    players = { Player(101, "Alice", false, moves), Player(102, "Bob", false, moves), Player(0, "[BOT] Max", true, moves) },
    GetIsFamilyShared = function(c) return c:GetUserId() == 102 end,
    GetOwnerUserId = function(c) return c:GetUserId() == 102 and 555 or c:GetUserId() end,
})()
a = byName(state, "Alice")
local b = byName(state, "Bob")
check(a.familyshared == false and a.owner_steamid == nil, "an owner: familyshared false, no owner id")
check(b.familyshared == true and b.owner_steamid == 555, "a shared copy: familyshared true, and whose it is")
check(b.moves_rejected_time == 37 and b.moves_rejected_other == 2, "rejected moves, both counts")
check(byName(state, "[BOT] Max").familyshared == false, "a bot reads as not shared")

-- ranking_active: the engine's answer.
state = NewVM({ players = { Player(101, "Alice") }, GetIsRankingActive = function() return true end })()
check(state.ranking_active == true, "ranking_active true: the engine says ranked")

-- Shine with basecommands: gagged per player, through IsClientGagged.
local gagged = { [102] = true }
local base = { IsClientGagged = function(self, c) return gagged[c:GetUserId()] == true end }
local shine = { IsExtensionEnabled = function(self, name)
    if name == "basecommands" then return true, base end
    return false
end }
state = NewVM({ players = { Player(101, "Alice"), Player(102, "Bob") }, Shine = shine })()
check(state.shine and state.shine.basecommands == true and state.shine.ban == false,
      "the shine key names basecommands")
check(byName(state, "Bob").gagged == true and byName(state, "Alice").gagged == false,
      "gagged follows IsClientGagged")

-- basecommands off: no gagged key at all.
shine = { IsExtensionEnabled = function() return false end }
state = NewVM({ players = { Player(101, "Alice") }, Shine = shine })()
check(state.shine.basecommands == false and byName(state, "Alice").gagged == nil,
      "basecommands off: basecommands false, no gagged")

-- An IsClientGagged that errors leaves the key out rather than guessing.
base = { IsClientGagged = function() error("broken") end }
shine = { IsExtensionEnabled = function(self, name) if name == "basecommands" then return true, base end return false end }
state = NewVM({ players = { Player(101, "Alice") }, Shine = shine })()
check(byName(state, "Alice").gagged == nil, "an erroring IsClientGagged leaves gagged out")

print("all passed")

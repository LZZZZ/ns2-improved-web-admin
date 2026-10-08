-- Off-rig harness for the recent-players store in lua/ServerWebInterface.lua.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed,
-- over a directory standing in for config://. Each "VM" is a fresh environment
-- over the same files, which is what a map change is. It checks the logic --
-- renames, bots, surviving a map change, a torn slot, capacity, the window --
-- not the engine: what the hooks really do at a map change is a rig question
-- (docs/REQUIREMENTS.md item 6).
--
-- Usage: luajit tools/spikes/recent-players-harness.lua --core <core/lua> [dir]
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
--   dir defaults to a fresh temporary directory.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua> [dir]", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"
local DISK = pos[1]
if not DISK then
    DISK = os.tmpname()
    os.remove(DISK)
end
os.execute("mkdir -p '" .. DISK .. "'")

local realOpen = io.open
local dkjson = dofile(CORE .. "dkjson.lua")

local function NewVM(clock, shine)
    local hooks = { }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function(path, mode)
        local rel = path:match("^config://(.*)$")
        if not rel then return nil, "writing to the game directory is not allowed" end
        os.execute("mkdir -p '" .. DISK .. "/" .. (rel:match("^(.*)/") or "") .. "'")
        return realOpen(DISK .. "/" .. rel, mode)
    end }
    env.json = dkjson
    env.Shine = shine
    env.kDefaultPlayerName = "NSPlayer"
    env.Script = { Load = function() end }
    env.CreateRingBuffer = function(n)
        local items = { }
        return {
            Insert = function(self, x) table.insert(items, x); if #items > n then table.remove(items, 1) end end,
            GetNumElements = function() return #items end,
            ToTable = function() return items end,
        }
    end
    env.GetBannedPlayersList = function() return { } end
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = {
        Message = function() end, SetWebRoot = function() end,
        GetSystemTime = function() return clock.now end,
        GetTime = function() return 0 end,
        GetEntitiesWithClassname = function() return players end,
        -- The perf windows' calls, idle here (perf-harness.lua covers them):
        -- a sample that never changes is never accumulated.
        GetSystemTimeReal = function() return clock.now end,
        GetServerPerformanceData = function() return {
            GetTimestamp = function() return 0 end,
            GetDurationMs = function() return 0 end,
        } end,
    }
    env.ientitylist = function(list) return ipairs(list) end
    env.Server = {
        GetFrameRate = function() return 60 end,
        GetOwner = function(p) return p.client end,
        GetClientAddress = function(c) return c.addr end,
    }
    env.IPAddressToString = function(a) return a end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    local vm = { }
    function vm.fire(name, ...) for _, fn in ipairs(hooks[name] or { }) do fn(...) end end
    function vm.connect(id, name, addr, bot)
        local p = { name = name }
        local client = {
            GetIsVirtual = function() return bot == true end,
            GetUserId = function() return id end,
            GetControllingPlayer = function() return p end,
            addr = addr,
        }
        p.client = client
        p.GetName = function(self) return self.name end
        table.insert(players, p)
        vm.fire("ClientConnect", client)
        return p
    end
    function vm.disconnect(p)
        for i, x in ipairs(players) do if x == p then table.remove(players, i) end end
        vm.fire("ClientDisconnect", p.client)
    end
    function vm.tick() vm.fire("UpdateServer") end
    function vm.recent()
        local _, body = hooks.WebRequest[1]({ request = "getrecentplayers" })
        return dkjson.decode(body)
    end
    function vm.console()
        local _, body = hooks.WebRequest[1]({ request = "getconsole", since = "0" })
        local texts = { }
        for _, line in ipairs(dkjson.decode(body).lines) do table.insert(texts, line.text) end
        return table.concat(texts, "\n")
    end
    return vm
end

local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end
local function find(r, id) for _, p in ipairs(r.players) do if p.steamid == id then return p end end end

local clock = { now = 1790000000 }
local vm = NewVM(clock)

check(vm.recent().storage.loaded == "empty", "first boot: no file, status empty")

local a = vm.connect(101, "NSPlayer", "192.0.2.1")
vm.connect(0, "[BOT] Max", "0.0.0.0", true)
vm.tick()
a.name = "Alice"
clock.now = clock.now + 11; vm.tick()
local r = vm.recent()
check(#r.players == 1, "bots are not recorded")
check(find(r, 101).name == "Alice" and #find(r, 101).names == 0, "placeholder name replaced, not kept as former")
check(find(r, 101).connected == true and find(r, 101).ipaddress == "192.0.2.1", "connected, with IP")

a.name = "Alicia"
clock.now = clock.now + 11; vm.tick()
r = vm.recent()
check(find(r, 101).name == "Alicia" and find(r, 101).names[1] == "Alice", "rename keeps the former name")

local b = vm.connect(202, "Bob", "198.51.100.7")
clock.now = clock.now + 100
vm.disconnect(b)
vm.tick()                      -- urgent save on the next tick
r = vm.recent()
check(find(r, 202).connected == false and find(r, 202).played == 100, "disconnect: not connected, played 100 s")
check(r.storage.saved_at == clock.now, "saved on the tick after a disconnect")
check(realOpen(DISK .. "/improved-webadmin/recent-players-a.json"), "slot a written")

-- Map change: fresh VM over the same disk. Alice reconnects; Bob does not.
clock.now = clock.now + 20
vm = NewVM(clock)
local a2 = vm.connect(101, "Alicia", "192.0.2.1")
vm.tick()
r = vm.recent()
check(r.storage.loaded == "ok", "after a map change the file loads")
check(find(r, 202) and find(r, 202).connected == false, "Bob survives the map change")
check(find(r, 101).names[1] == "Alice" and find(r, 101).connected, "Alice survives, reconnected, former names kept")
check(find(r, 101).first_seen == 1790000000, "first_seen kept across the map change")

-- Force a save into slot b, then tear it: the loader must fall back to a.
vm.disconnect(a2); vm.tick()
check(realOpen(DISK .. "/improved-webadmin/recent-players-b.json"), "slot b written by the next save")
local f = realOpen(DISK .. "/improved-webadmin/recent-players-b.json", "r"); local text = f:read("*a"); f:close()
f = realOpen(DISK .. "/improved-webadmin/recent-players-b.json", "w"); f:write(text:sub(1, math.floor(#text / 2))); f:close()
vm = NewVM(clock)
r = vm.recent()
check(r.storage.loaded == "fallback", "torn newest slot: status fallback")
check(find(r, 202) and find(r, 101), "fallback kept both players from the older slot")
vm.tick(); clock.now = clock.now + 61; vm.connect(303, "Carol", "203.0.113.9"); vm.tick()
f = realOpen(DISK .. "/improved-webadmin/recent-players-b.json", "r"); text = f:read("*a"); f:close()
check(dkjson.decode(text) ~= nil, "the next save overwrites the torn slot")

-- Both torn: unreadable, and the list starts empty rather than failing.
for _, s in ipairs({ "a", "b" }) do
    f = realOpen(DISK .. "/improved-webadmin/recent-players-" .. s .. ".json", "w"); f:write("{\"version\":1,"); f:close()
end
vm = NewVM(clock)
r = vm.recent()
check(r.storage.loaded == "unreadable" and #r.players == 0, "both slots torn: unreadable, empty list")

-- Window and capacity.
vm = NewVM(clock)
for i = 1, 130 do
    local p = vm.connect(1000 + i, "P" .. i, "192.0.2.2")
    clock.now = clock.now + 1
    vm.disconnect(p)
end
vm.tick()
r = vm.recent()
check(#r.players == 100 and r.capacity == 100 and r.window == 86400, "capped at 100")
check(find(r, 1130) and not find(r, 1001), "the newest 100 are the ones kept")
clock.now = clock.now + 86400 + 200
r = vm.recent()
check(#r.players == 0, "everyone ages out after 24 h")
local stay = vm.connect(9, "Stayer", "192.0.2.3")
clock.now = clock.now + 90000; vm.tick()
r = vm.recent()
check(find(r, 9) and find(r, 9).connected, "a connected player is never aged out")
-- Shine's ban plugin: an absent player's ban takes the name the list last saw.
local recorded = { }
local function RecordingAddBan(self, id, name)
    table.insert(recorded, { id = id, name = name })
    return true, "stored"
end
local plugin = { AddBan = RecordingAddBan }
local shine = { IsExtensionEnabled = function(_, name)
    if name == "ban" then return true, plugin end
    return false
end }
vm = NewVM(clock, shine)
local rita = vm.connect(555, "Rita", "192.0.2.5")
vm.tick()
vm.disconnect(rita)
vm.tick()
local ok, extra = plugin:AddBan("555", "<unknown>", 3600, "Console", 0, "test")
check(recorded[#recorded].name == "Rita", "an absent player's ban is named from the list")
check(ok == true and extra == "stored", "AddBan's return values pass through")
check(vm.console():find('Named the ban of 555 "Rita", from recent players.', 1, true),
      "and the naming is printed for the console")
plugin:AddBan("777", "<unknown>", 3600, "Console", 0, "test")
check(recorded[#recorded].name == "<unknown>", "an id not in the list stays <unknown>")
plugin:AddBan("555", "Rita Online", 3600, "Console", 0, "test")
check(recorded[#recorded].name == "Rita Online", "a real name is left alone")
plugin.AddBan = RecordingAddBan       -- Shine re-creating the plugin's method
vm.tick()
plugin:AddBan("555", "<unknown>", 3600, "Console", 0, "test")
check(recorded[#recorded].name == "Rita", "a replaced AddBan is wrapped again on the next tick")
local function Namings() local _, n = vm.console():gsub("Named the ban of 555", "") return n end
vm.tick()
local before = Namings()
plugin:AddBan("555", "<unknown>", 3600, "Console", 0, "test")
check(Namings() == before + 1, "and wrapped once: one line per ban, after another tick")
print("all passed")

-- Off-rig harness for getmods and installmod in lua/ServerWebInterface.lua.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed:
-- a clock the harness moves, a Server.SearchWorshop that keeps its callbacks
-- for the harness to answer (or not), and a Server.InstallMod that records its
-- argument. It checks the handler's logic -- time out once, never restart
-- silently, separate cache keys, ignore a late answer, refuse a bad id -- not
-- the engine; the engine side was measured on the rig (REQUIREMENTS item 4).
--
-- Usage: luajit tools/spikes/workshop-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"

local dkjson = dofile(CORE .. "dkjson.lua")

local function NewVM()
    local hooks = { }
    local vm = { now = 0, searches = { }, installs = { },
                 installed = { { "1e62a2ce", "Combat Fix" } } }
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function() return nil, "not allowed" end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.CreateRingBuffer = function() return { Insert = function() end,
        GetNumElements = function() return 0 end, ToTable = function() return { } end } end
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = { Message = function() end, SetWebRoot = function() end,
                   GetSystemTime = function() return vm.now end,
                   GetTime = function() return vm.now end }
    env.Log = function() end
    env.tonumber64 = function(s) return tonumber(s) end
    env.Server = {
        GetNumMods = function() return #vm.installed end,
        GetModId = function(i) return vm.installed[i][1] end,
        GetModTitle = function(i) return vm.installed[i][2] end,
        GetNumActiveMods = function() return 0 end,
        SearchWorshop = function(text, page, callback)
            -- The engine's overload check: string, number, function.
            assert(type(text) == "string" and type(page) == "number"
                   and type(callback) == "function", "SearchWorshop overloads")
            table.insert(vm.searches, { text = text, page = page, callback = callback })
        end,
        InstallMod = function(id) table.insert(vm.installs, id) end,
    }
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    function vm.request(params)
        local ctype, body = hooks.WebRequest[1](params)
        return ctype, body and dkjson.decode(body), body
    end
    return vm
end

-- A page of hits the way the engine hands them over: numeric ids.
local function hits(n, base)
    local t = { }
    for i = 1, n do
        t[i] = { id = (base or 3397710344) + i, title = "Mod " .. i, description = "",
                 authorid = "76561197980112344", filesize = 1000, tags = "",
                 steamresult = 1, childcount = 0, thumbnailurl = "", version = 0 }
    end
    return t
end

local failures = 0
local function check(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

-- 1. A search starts, loads, settles, and is cached.
do
    local vm = NewVM()
    local _, r = vm.request({ request = "getmods", searchtext = "combat", p = "1" })
    check(r.loading == true and r.elapsed == 0, "first call answers loading")
    check(#vm.searches == 1 and vm.searches[1].text == "combat" and vm.searches[1].page == 1,
          "and starts one search")
    vm.now = 2
    _, r = vm.request({ request = "getmods", searchtext = "combat", p = "1" })
    check(r.loading == true and r.elapsed == 2 and #vm.searches == 1,
          "a poll while running reports elapsed and starts nothing")
    vm.searches[1].callback(hits(50))
    _, r = vm.request({ request = "getmods", searchtext = "combat", p = "1" })
    check(r.done == true and r.count == 50 and #r.items == 50 and r.capped == true
          and r.page == 1, "a settled search: done, 50 items, capped")
    check(r.items[1].id == "ca84f209", "ids hex-encoded, above 2^31 too")
    check(r.loading == nil, "no loading key once settled (the 2012 panel stops)")
    vm.now = 61.9   -- settled at 2
    _, r = vm.request({ request = "getmods", searchtext = "combat", p = "1" })
    check(r.done == true and #vm.searches == 1, "cached for 60 s from the answer")
    vm.now = 62
    _, r = vm.request({ request = "getmods", searchtext = "combat", p = "1" })
    check(r.loading == true and #vm.searches == 2, "then searches again")
end

-- 2. An empty result is `items: []`, not an error, and not capped.
do
    local vm = NewVM()
    vm.request({ request = "getmods", searchtext = "nomatch" })
    vm.searches[1].callback({ })
    local _, r, body = vm.request({ request = "getmods", searchtext = "nomatch" })
    check(r.done == true and r.count == 0 and r.error == nil and r.capped == false,
          "empty: done, count 0, no error")
    check(body:find('"items":%[%]') ~= nil, "empty items encodes as []")
    vm.request({ request = "getmods", searchtext = "few" })
    vm.searches[2].callback(hits(6))
    _, r = vm.request({ request = "getmods", searchtext = "few" })
    check(r.count == 6 and r.capped == false, "six hits: not capped")
    vm.request({ request = "getmods", searchtext = "nil" })
    vm.searches[3].callback(nil)
    _, r = vm.request({ request = "getmods", searchtext = "nil" })
    check(r.done == true and r.count == 0, "a nil answer reads as empty")
end

-- 3. A search with no answer times out once, then starts afresh.
do
    local vm = NewVM()
    vm.request({ request = "getmods", searchtext = "slow" })
    vm.now = 29.9
    local _, r = vm.request({ request = "getmods", searchtext = "slow" })
    check(r.loading == true, "still loading at 29.9 s")
    vm.now = 30
    _, r = vm.request({ request = "getmods", searchtext = "slow" })
    check(r.done == true and type(r.error) == "string" and r.error:find("30 s")
          and #r.items == 0 and r.loading == nil, "at 30 s: done, with the error")
    check(#vm.searches == 1, "and the timeout itself starts nothing")
    _, r = vm.request({ request = "getmods", searchtext = "slow" })
    check(r.loading == true and #vm.searches == 2, "the next request starts a fresh search")
    -- The first search answers late: it must not stand in for the second.
    vm.searches[1].callback(hits(3))
    _, r = vm.request({ request = "getmods", searchtext = "slow" })
    check(r.loading == true, "a late answer to the abandoned search is ignored")
    vm.searches[2].callback(hits(5))
    _, r = vm.request({ request = "getmods", searchtext = "slow" })
    check(r.count == 5, "the fresh search's answer is the one used")
end

-- 4. Parameters vanilla mishandled.
do
    local vm = NewVM()
    local _, r = vm.request({ request = "getmods" })
    check(r.loading == true and #vm.searches == 1 and vm.searches[1].text == "",
          "no searchtext searches for everything instead of never starting")
    _, r = vm.request({ request = "getmods", searchtext = "combat", p = "abc" })
    check(r and r.loading == true and vm.searches[2].page == 1, "p=abc reads as page 1")
    for _, p in ipairs({ "0", "-3", "inf", "nan", "1e300" }) do
        vm.request({ request = "getmods", searchtext = "p" .. p, p = p })
        check(vm.searches[#vm.searches].page == 1, "p=" .. p .. " reads as page 1")
    end
    vm.request({ request = "getmods", searchtext = "combat", p = "2.7" })
    check(vm.searches[#vm.searches].page == 2, "p=2.7 reads as page 2")
    vm.request({ request = "getmods", searchtext = "a", p = "11" })
    local n = #vm.searches
    vm.request({ request = "getmods", searchtext = "a1", p = "1" })
    check(#vm.searches == n + 1, "\"a\" page 11 and \"a1\" page 1 are separate searches")
end

-- 5. installmod refuses what the engine would drop or misread.
do
    local vm = NewVM()
    local function install(id)
        local ctype, r = vm.request({ request = "installmod", modid = id })
        return r, ctype
    end
    local r, ctype = install("868595e")
    check(ctype == "application/json" and r.ok == true and r.id == "868595e"
          and r.already_installed == false and vm.installs[1] == "868595e",
          "a new id: ok, sent to InstallMod")
    r = install("1E62A2CE")
    check(r.ok == true and r.id == "1e62a2ce" and r.already_installed == true,
          "an installed id, any case: ok, already installed")
    r = install("000868595e")
    check(r.ok == true and r.id == "868595e", "leading zeros dropped")
    local sent = #vm.installs
    for _, bad in ipairs({ "zz", "-5", "", "0", "000", "12345678901234567", "1e62a2ce;x" }) do
        r = install(bad)
        check(r.ok == false and type(r.error) == "string", "refused: '" .. bad .. "'")
    end
    r = install(nil)
    check(r.ok == false, "refused: no modid")
    check(#vm.installs == sent, "nothing refused reached InstallMod")
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

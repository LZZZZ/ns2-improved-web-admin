-- Off-rig harness for getwhitelist in lua/ServerWebInterface.lua (docs/CONSTRAINTS.md item 17).
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed:
-- a clock the harness moves, a Shared.SendHTTPRequest that keeps its callbacks
-- for the harness to answer (or not) in the shapes the rig measured, an
-- in-memory config:// for the copy, and ModServices.GetHotfixListModId()
-- returning a uint64 cdata, as the engine's FFI binding does. It checks the
-- handler's logic -- parse, cache, branch, give up, wait before retrying,
-- ignore a late answer -- not Steam; the pages were read on the rig
-- (CONSTRAINTS item 17).
--
-- Usage: luajit tools/spikes/whitelist-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"

local ffi = require("ffi")
local dkjson = dofile(CORE .. "dkjson.lua")

local kFile = "config://webadmin-spa/whitelist.json"

-- A Workshop page shaped like Steam's (2026-10-08): the items back to back
-- after the block's opening tag, then more filedetails links outside it.
local function Page(ids)
    local parts = { '<html><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=2909200101">',
                    '<div class="requiredItemsContainer" id="RequiredItems">\n' }
    for _, id in ipairs(ids) do
        table.insert(parts, '\t\t\t<a href="https://steamcommunity.com/workshop/filedetails/?id='
            .. id .. '" target="_blank" data-subscribed="0">\n\t\t\t\t<div class="requiredItem">\n'
            .. '\t\t\t\t\tMod &amp; &#39;' .. id .. '&#39;\t\t\t\t\t\t</div>\n\t\t\t</a>\n')
    end
    table.insert(parts, '\t\t</div>\n\t</div>\n<!-- created by -->\n'
        .. '<a href="https://steamcommunity.com/sharedfiles/filedetails/?id=999">x</a></html>')
    return table.concat(parts)
end

local kWhitelistPage = Page({ "2895891999", "191973881", "3798409220" })
local kHotfixPage = Page({ "2899635443", "3558697165" })

local function NewVM(opts)
    opts = opts or { }
    local hooks = { }
    local vm = { now = 1000, calls = { }, files = opts.files or { }, logs = { } }
    local env = setmetatable({ }, { __index = _G })
    env.io = { open = function(path, mode)
        if not path:find("^config://webadmin%-spa/") then return nil, "not allowed" end
        if mode == "w" then
            if opts.readOnly then return nil, path .. ": Permission denied" end
            local buffer = { }
            return { write = function(_, s) table.insert(buffer, s) end,
                     close = function() vm.files[path] = table.concat(buffer) end }
        end
        local text = vm.files[path]
        if not text then return nil, path .. ": No such file" end
        return { read = function() return text end, close = function() end }
    end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.CreateRingBuffer = function() return { Insert = function() end,
        GetNumElements = function() return 0 end, ToTable = function() return { } end } end
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = { Message = function() end, SetWebRoot = function() end,
                   GetSystemTime = function() return vm.now end,
                   GetTime = function() return vm.now end,
                   SendHTTPRequest = function(url, method, callback)
                       if opts.httpRaises then error("no transport") end
                       assert(method == "GET" and type(callback) == "function", "GET with a callback")
                       table.insert(vm.calls, { url = url, callback = callback })
                   end }
    env.Log = function(fmt, ...) table.insert(vm.logs, string.format(fmt, ...)) end
    env.tonumber64 = function(s) return tonumber(s) end
    env.Server = { GetNumMods = function() return 0 end, GetNumActiveMods = function() return 0 end }
    if opts.hotfixListId ~= false then
        local id = opts.hotfixListId or 2633436686
        env.ModServices = { GetHotfixListModId = function() return ffi.new("uint64_t", id) end }
    end
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    function vm.request()
        local ctype, body = hooks.WebRequest[1]({ request = "getwhitelist" })
        assert(ctype == "application/json", "a JSON reply")
        return dkjson.decode(body), body
    end
    -- Answer the oldest call still waiting, the way the rig measured it.
    function vm.answer(body, message, code, status)
        local call = table.remove(vm.calls, 1)
        call.callback(body, message, code or 0, status or (body ~= "" and 200 or 0))
        return call.url
    end
    return vm
end

local failures = 0
local function check(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local kPage = "https://steamcommunity.com/sharedfiles/filedetails/?id="

-- 1. The first request reads both pages, one after the other, and keeps a copy.
do
    local vm = NewVM()
    local r = vm.request()
    check(r.fetching == true and r.whitelist == nil and r.read_at == nil and r.error == nil,
          "first request: fetching, no list yet")
    check(r.branch == "live" and r.hotfix_list_id == "2633436686"
          and r.whitelist_id == "2909200101" and r.now == 1000,
          "the live branch, from a uint64 hotfix list id")
    check(#vm.calls == 1 and vm.calls[1].url == kPage .. "2909200101",
          "one read, the whitelist's page")
    r = vm.request()
    check(#vm.calls == 1 and r.fetching == true, "a poll while reading starts nothing")
    vm.now = 1001
    vm.answer(kWhitelistPage)
    check(#vm.calls == 1 and vm.calls[1].url == kPage .. "2633436686",
          "then, only then, the hotfix list's page")
    r = vm.request()
    check(r.fetching == true and r.whitelist == nil, "still fetching until both are in")
    vm.now = 1002
    vm.answer(kHotfixPage)
    r = vm.request()
    check(r.fetching == false and r.read_at == 1002 and r.error == nil, "read: read_at, no error")
    check(same(r.whitelist, { "2895891999", "191973881", "3798409220" }),
          "the whitelist's ids, in page order, none from outside the block")
    check(same(r.hotfix, { "2899635443", "3558697165" }), "the hotfix mods")
    local saved = vm.files[kFile] and dkjson.decode(vm.files[kFile])
    check(saved and saved.version == 1 and saved.read_at == 1002
          and saved.hotfix_list_id == "2633436686" and #saved.whitelist == 3,
          "a copy in config://webadmin-spa/whitelist.json")
    vm.now = 1002 + 3599
    r = vm.request()
    check(#vm.calls == 0 and r.fetching == false, "no read again within the hour")
end

-- 2. A map change: a new VM serves the copy, and reads again once it is old.
do
    local first = NewVM()
    first.request(); first.answer(kWhitelistPage); first.answer(kHotfixPage)
    local vm = NewVM({ files = first.files })
    vm.now = 1000 + 1800
    local r = vm.request()
    check(#vm.calls == 0 and r.read_at == 1000 and #r.whitelist == 3 and r.fetching == false,
          "after a map change: the copy, at once, no read")
    vm.now = 1000 + 3600
    r = vm.request()
    check(#vm.calls == 1 and r.fetching == true and r.read_at == 1000 and #r.whitelist == 3,
          "an hour old: read again, the copy served meanwhile")
end

-- 3. Steam unreachable: the reason, then 5 minutes before the next read.
do
    local vm = NewVM()
    vm.request()
    vm.answer("", "Could not resolve host: steamcommunity.com", 6, 0)
    local r = vm.request()
    check(r.fetching == false and r.whitelist == nil
          and r.error == "Steam could not be reached: Could not resolve host: steamcommunity.com",
          "an unknown host: curl's message as the error")
    check(vm.logs[#vm.logs]:find("whitelist not read", 1, true) ~= nil, "and the log says so")
    vm.now = vm.now + 299
    r = vm.request()
    check(#vm.calls == 0 and r.error ~= nil, "no new read within 5 minutes")
    vm.now = vm.now + 1
    r = vm.request()
    check(#vm.calls == 1 and r.fetching == true and r.error ~= nil,
          "then a new read, the last error still shown")
    vm.answer(kWhitelistPage); vm.answer(kHotfixPage)
    r = vm.request()
    check(r.error == nil and #r.whitelist == 3, "a read that works clears the error")
end

-- 4. The other failures: an HTTP status, a page with no list, the hotfix page.
do
    local vm = NewVM()
    vm.request()
    vm.answer("<html>Too Many Requests</html>", nil, 0, 429)
    local r = vm.request()
    check(r.error == "Steam answered HTTP 429 for item 2909200101.", "429: the status")

    vm = NewVM()
    vm.request()
    vm.answer("<html>There was a problem accessing the item.</html>", nil, 0, 200)
    r = vm.request()
    check(r.error == "Steam's page for item 2909200101 lists no required items (52 bytes).",
          "a 200 page with no list: says so, with its size")

    vm = NewVM()
    vm.request()
    vm.answer(Page({ }), nil, 0, 200)
    r = vm.request()
    check(r.error ~= nil and r.error:find("lists no required items") and r.whitelist == nil,
          "an empty list is a failure, not an empty whitelist")

    vm = NewVM()
    vm.request()
    vm.answer(kWhitelistPage)
    vm.answer("", "Failed to connect to steamcommunity.com port 443", 7, 0)
    r = vm.request()
    check(r.error ~= nil and r.error:find("Failed to connect") and r.whitelist == nil
          and vm.files[kFile] == nil, "the hotfix page failing keeps nothing")

    vm = NewVM()
    vm.request()
    vm.answer("", nil, 0, 0)
    r = vm.request()
    check(r.error == "Steam did not answer for item 2909200101.", "an empty answer, no message")

    vm = NewVM({ httpRaises = true })
    r = vm.request()
    check(r.fetching == false and r.error and r.error:find("^SendHTTPRequest failed"),
          "SendHTTPRequest raising is an error, not a crash")
end

-- 5. No answer at all: given up at 30 s, and a late answer is ignored.
do
    local vm = NewVM()
    vm.request()
    vm.now = vm.now + 29
    local r = vm.request()
    check(r.fetching == true and r.error == nil, "still fetching at 29 s")
    vm.now = vm.now + 1
    r = vm.request()
    check(r.fetching == false and r.error == "Steam did not answer within 30 s.",
          "given up at 30 s")
    local late = table.remove(vm.calls, 1)
    late.callback(kWhitelistPage, nil, 0, 200)
    r = vm.request()
    check(#vm.calls == 0 and r.whitelist == nil, "a late answer to it starts nothing, keeps nothing")
end

-- 6. Branches, and a server with none.
do
    local vm = NewVM({ hotfixListId = 2708090797 })
    local r = vm.request()
    check(r.branch == "beta" and r.whitelist_id == "2860343495"
          and vm.calls[1].url == kPage .. "2860343495", "beta: its own whitelist item")
    vm.answer(kWhitelistPage)
    check(vm.calls[1].url == kPage .. "2708090797", "and its own hotfix list")

    vm = NewVM({ hotfixListId = 12345 })
    r = vm.request()
    check(#vm.calls == 0 and r.branch == nil and r.hotfix_list_id == "12345"
          and r.error == "No whitelist is known for hotfix list 12345.", "an unknown hotfix list")

    vm = NewVM({ hotfixListId = 0 })
    r = vm.request()
    check(#vm.calls == 0 and r.hotfix_list_id == nil
          and r.error == "The server has no hotfix list, so no whitelist to read.", "id 0: none")

    vm = NewVM({ hotfixListId = false })
    r = vm.request()
    check(#vm.calls == 0 and r.error ~= nil and r.now == 1000, "no ModServices at all")
end

-- 7. A copy that cannot be used is read again.
do
    local vm = NewVM({ files = { [kFile] = '{"version":1,"read_at":5,"whitel' } })
    local r = vm.request()
    check(#vm.calls == 1 and r.whitelist == nil, "a torn copy: ignored, read again")

    local beta = NewVM({ hotfixListId = 2708090797 })
    beta.request(); beta.answer(kWhitelistPage); beta.answer(kHotfixPage)
    vm = NewVM({ files = beta.files })
    r = vm.request()
    check(#vm.calls == 1 and r.whitelist == nil and r.branch == "live",
          "another branch's copy: not served, read again")

    vm = NewVM({ files = { [kFile] = dkjson.encode({ version = 1, read_at = 900,
        hotfix_list_id = "2633436686", whitelist = { "12x" }, hotfix = { "1" } }) } })
    r = vm.request()
    check(#vm.calls == 1 and r.whitelist == nil, "a copy with a bad id: not served")

    vm = NewVM({ readOnly = true })
    vm.request(); vm.answer(kWhitelistPage); vm.answer(kHotfixPage)
    r = vm.request()
    check(#r.whitelist == 3 and r.error == nil
          and vm.logs[#vm.logs]:find("whitelist not saved", 1, true) ~= nil,
          "a copy that cannot be written: served anyway, the log says so")
end

print(string.format("\n%s", failures == 0 and "all passed" or (failures .. " failed")))
os.exit(failures == 0 and 0 or 1)

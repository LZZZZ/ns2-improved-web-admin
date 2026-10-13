-- SPIKE 2026-10-12: the 10-12 engine's web admin additions.
--
-- Standalone: replaces lua/ServerWebInterface.lua on the rig, with none of
-- the mod's wrappers, so it sees what the engine itself does. Code stays in
-- top-level functions (see TESTING.md, Traps: the preprocessor).
--
--   /?request=probe1012&what=names        new functions present on Server/Shared
--   /?request=probe1012&what=requests     the WebRequest hook's arguments, last 20 calls
--   /?request=probe1012&what=readlog      Shared.ReadLog with assorted arguments
--   /?request=probe1012&what=tickstat     Server.GetTickStat now
--   /?request=probe1012&what=capture&cmd=X  Shared.CaptureConsoleCommand(X)
--   /?request=probe1012&what=json         Shared.JsonEncode against dkjson
--   /?request=probe1012&what=whitelist    Server.GetIsModWhitelisted, and its first-tick answers
--   any other request                     text/plain echo of path and method

local kMaxRequests = 20
local seenRequests = {}
local firstTickWhitelist = nil

-- A JSON-safe description of any value, two levels deep.
local function Describe(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then
        return { type = "string", len = #v, head = v:sub(1, 400) }
    elseif t == "table" then
        if depth >= 3 then return { type = "table", truncated = true } end
        local out = { type = "table", fields = {} }
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n <= 80 then
                out.fields[tostring(k) .. " (" .. type(k) .. ")"] = Describe(val, depth + 1)
            end
        end
        out.count = n
        return out
    elseif t == "number" then
        return { type = "number", value = v, integer = (v == math.floor(v)) }
    else
        return { type = t, value = tostring(v) }
    end
end

-- Every return value of a pcall'd call, described.
local function Try(fn, ...)
    if type(fn) ~= "function" then
        return { missing = true, type = type(fn) }
    end
    local function Pack(...) return select("#", ...), { ... } end
    local n, results = Pack(pcall(fn, ...))
    if not results[1] then
        return { raised = tostring(results[2]) }
    end
    local out = { count = n - 1, values = {} }
    for i = 2, n do
        out.values[i - 1] = Describe(results[i])
    end
    return out
end

local function Names()
    local out = {}
    local pattern = "[Ww]hitelist|Log|Json|Tick|Capture|Ranking|Uninstall|Mod|Http|Web|Build"
    for _, lib in ipairs({ "Server", "Shared" }) do
        local names = {}
        for k, v in pairs(_G[lib] or {}) do
            local name = tostring(k)
            for p in string.gmatch(pattern, "[^|]+") do
                if string.find(name, p) then
                    table.insert(names, name .. ":" .. type(v))
                    break
                end
            end
        end
        table.sort(names)
        out[lib] = names
    end
    return out
end

local function ReadLogCases()
    local cases = {
        { "0, 256", 0, 256 },
        { "0 (no max)", 0, nil },
        { "100, 50", 100, 50 },
        { "-1, 100", -1, 100 },
        { "-200, 200", -200, 200 },
        { "1e9, 100", 1e9, 100 },
        { "0, 16 MB", 0, 16 * 1024 * 1024 },
        { "'abc', 10", "abc", 10 },
        { "nil, nil", nil, nil },
    }
    local out = {}
    for _, c in ipairs(cases) do
        out[#out + 1] = { args = c[1], result = Try(Shared.ReadLog, c[2], c[3]) }
    end
    return out
end

local kJsonCases = {
    { "empty table", function() return {} end },
    { "array", function() return { 1, 2, 3 } end },
    { "object", function() return { a = 1, b = "x" } end },
    { "nested", function() return { list = {}, obj = { k = { 1, { z = true } } } } end },
    { "mixed keys", function() return { 1, 2, x = 3 } end },
    { "sparse array", function() return { [1] = "a", [3] = "c" } end },
    { "numeric keys", function() return { [10] = "a", [20] = "b" } end },
    { "floats", function() return { 0.1, 1/3, 1e20, -0.0, 123456789.125 } end },
    { "steamid64", function() return { 76561197960265728 + 12345 } end },
    { "nan/inf", function() return { 0/0, 1/0, -1/0 } end },
    { "booleans", function() return { t = true, f = false } end },
    { "string escapes", function() return { s = "quote\" back\\ nl\n tab\t ctl\1 del\127 slash/" } end },
    { "utf8", function() return { s = "ação 日本 😀" } end },
    { "invalid utf8", function() return { s = "\255\254 x" } end },
    { "plain string", function() return "hello" end },
    { "plain number", function() return 42 end },
    { "nil", function() return nil end },
    { "function value", function() return { f = print } end },
    { "cyclic", function() local t = {} t.self = t return t end },
    { "deep", function() local t = {} local c = t for i = 1, 200 do c.n = {} c = c.n end return t end },
}

local function JsonCases()
    local out = {}
    for _, c in ipairs(kJsonCases) do
        local value = c[2]()
        local engine = Try(Shared.JsonEncode, value)
        local okd, dk = pcall(json.encode, value)
        out[#out + 1] = { case = c[1], engine = engine, dkjson = okd and dk or ("raised: " .. tostring(dk)) }
    end
    -- Speed on a reply-sized table.
    local big = {}
    for i = 1, 2000 do
        big[i] = { id = i, time = 1760000000 + i, src = "server", text = "line number " .. i .. " with some text" }
    end
    local t0 = Shared.GetSystemTimeReal and Shared.GetSystemTimeReal() or os.clock()
    local ok1 = pcall(Shared.JsonEncode, big)
    local t1 = Shared.GetSystemTimeReal and Shared.GetSystemTimeReal() or os.clock()
    local ok2 = pcall(json.encode, big)
    local t2 = Shared.GetSystemTimeReal and Shared.GetSystemTimeReal() or os.clock()
    out[#out + 1] = { case = "2000 rows timing", engine_ok = ok1, engine_s = t1 - t0, dkjson_ok = ok2, dkjson_s = t2 - t1 }
    return out
end

local kWhitelistCases = {
    { "Shine 117887554 (number)", 117887554 },
    { "Shine hex string 706d242", "706d242" },
    { "Shine decimal string", "117887554" },
    { "Combat Fix 509780686", 509780686 },
    { "UWE Hotfix 3558697165", 3558697165 },
    { "NSL Badges? 2633436686", 2633436686 },
    { "improved-webadmin 3816039702", 3816039702 },
    { "made-up 1", 1 },
    { "zero", 0 },
    { "nil", nil },
    { "garbage string", "zzz" },
}

local function WhitelistCases()
    local out = {}
    for _, c in ipairs(kWhitelistCases) do
        out[#out + 1] = { case = c[1], result = Try(Server.GetIsModWhitelisted, c[2]) }
    end
    return { now = out, first_tick = firstTickWhitelist,
             ranking_active = Try(Server.GetIsRankingActive) }
end

-- Console commands to capture.
local function OnProbePrint()
    Shared.Message("probe-shared-message")
    ServerAdminPrint(nil, "probe-adminprint")
    Print("probe-print %d", 1)
    Log("probe-log %s", "x")
end
Event.Hook("Console_probeprint", OnProbePrint)

local function OnProbeError()
    Shared.Message("probe-before-error")
    error("probe-error")
end
Event.Hook("Console_probeerror", OnProbeError)

local function OnProbeNested()
    Shared.Message("probe-outer-before")
    local inner = Shared.CaptureConsoleCommand("probeprint")
    Shared.Message("probe-outer-after inner=" .. tostring(inner and #tostring(inner)))
end
Event.Hook("Console_probenested", OnProbeNested)

local function Capture(cmd)
    local t0 = Shared.GetTime()
    local r = Try(Shared.CaptureConsoleCommand, cmd)
    r.elapsed = Shared.GetTime() - t0
    r.cmd = cmd
    return r
end

local function RecordRequest(n, actions, request)
    local rec = { argc = n, actions = Describe(actions), request = Describe(request) }
    table.insert(seenRequests, rec)
    if #seenRequests > kMaxRequests then
        table.remove(seenRequests, 1)
    end
end

local function OnWebRequest(...)
    local n = select("#", ...)
    local actions, request = ...
    RecordRequest(n, actions, request)

    if type(actions) == "table" and actions.request == "probe1012" then
        local what = actions.what
        local reply
        if what == "names" then
            reply = Names()
        elseif what == "requests" then
            reply = seenRequests
        elseif what == "readlog" then
            reply = ReadLogCases()
        elseif what == "tickstat" then
            reply = Try(Server.GetTickStat)
        elseif what == "capture" then
            reply = Capture(actions.cmd or "")
        elseif what == "json" then
            reply = JsonCases()
        elseif what == "whitelist" then
            reply = WhitelistCases()
        else
            reply = { error = "unknown what" }
        end
        return "application/json", json.encode(reply)
    end

    -- Routing: everything else echoes what the hook saw.
    local path = type(request) == "table" and request.path or "?"
    local method = type(request) == "table" and request.method or "?"
    return "text/plain", "probe1012 echo path=" .. tostring(path) .. " method=" .. tostring(method)
end
Event.Hook("WebRequest", OnWebRequest)

local function OnUpdateServer()
    if firstTickWhitelist == nil then
        firstTickWhitelist = {
            time = Shared.GetTime(),
            shine = Try(Server.GetIsModWhitelisted, 117887554),
            combatfix = Try(Server.GetIsModWhitelisted, 509780686),
        }
    end
end
Event.Hook("UpdateServer", OnUpdateServer)

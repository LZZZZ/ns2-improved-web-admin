-- Off-rig harness for the console capture in lua/ServerWebInterface.lua:
-- the ServerAdminPrint and Shared.Message wrappers, and how they count lines
-- when Shine copies its own lines to every admin in game.
--
-- Shine's AdminPrint (core/server/logging.lua) prints through Shared.Message
-- and then calls ServerAdminPrint(admin, line) for each admin connected.
-- Measured on the rig with an admin joined, 2026-10-06: the capture recorded
-- each Shine line twice. This checks it now records it once, and that what
-- is not an echo still arrives.
--
-- Usage: luajit tools/spikes/console-harness.lua --core <core/lua>
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

local clock = { now = 1790000000 }
local hooks = { }
local printed = { }       -- what reached the real server console
local delivered = { }     -- what was sent to an admin's game console
local env = setmetatable({ }, { __index = _G })
env.io = { open = function() return nil, "no files in this harness" end }
env.json = dkjson
env.Script = { Load = function() end }
env.CreateRingBuffer = RingBuffer
env.GetBannedPlayersList = function() return { } end
env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
env.Shared = {
    Message = function(m) table.insert(printed, m) end,
    SetWebRoot = function() end,
    GetSystemTime = function() return clock.now end,
    GetTime = function() return 0 end,
    GetEntitiesWithClassname = function() return setmetatable({ }, { __index = { GetSize = function() return 0 end } }) end,
    GetSystemTimeReal = function() return clock.now end,
    GetServerPerformanceData = function() return {
        GetTimestamp = function() return 0 end, GetDurationMs = function() return 0 end,
    } end,
    ConsoleCommand = function() end,
}
env.ientitylist = function(list) return ipairs(list) end
env.Server = { GetFrameRate = function() return 60 end }
-- Vanilla's (core/lua/ServerAdmin.lua:156): to the client if any, then the
-- server console.
env.ServerAdminPrint = function(client, message)
    if client then table.insert(delivered, { client, message }) end
    env.Shared.Message(message)
end
local chunk = assert(loadfile(MOD))
setfenv(chunk, env)
chunk()

local function console()
    local _, body = hooks.WebRequest[1]({ request = "getconsole", since = "0" })
    return dkjson.decode(body).lines
end
local function count(lines, text)
    local n = 0
    for _, l in ipairs(lines) do if l.text == text then n = n + 1 end end
    return n
end
local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end

local admin1, admin2 = { id = 1 }, { id = 2 }

-- Shine replaces ServerAdminPrint on its first tick, without chaining: its
-- version sends to the client only, and our wrapper goes back on top of it.
env.ServerAdminPrint = function(client, message)
    if client then table.insert(delivered, { client, message }) end
end
hooks.UpdateServer[1]()

-- Shine:AdminPrint with two admins in game.
local function ShineAdminPrint(line)
    env.Shared.Message(line)
    for _, a in ipairs({ admin1, admin2 }) do env.ServerAdminPrint(a, line) end
end

ShineAdminPrint("Console[N/A] gagged LZZ[3869225]")
local lines = console()
check(count(lines, "Console[N/A] gagged LZZ[3869225]") == 1, "a Shine line with two admins in game is captured once")
check(#delivered == 2, "and both admins still receive it")
check(lines[#lines].src == "server", "as the server's line")

-- The same text again, later, is a new line, not an echo.
clock.now = clock.now + 5
ShineAdminPrint("Console[N/A] gagged LZZ[3869225]")
check(count(console(), "Console[N/A] gagged LZZ[3869225]") == 2, "the same line again, later, is captured again")

-- An in-game admin's own command output is not an echo of anything.
env.ServerAdminPrint(admin1, "No matching player")
lines = console()
check(count(lines, "No matching player") == 1 and lines[#lines].src == "admin",
      "an in-game admin's command output is captured, as admin")

-- A line for the console (no client) is captured, whatever came before.
env.ServerAdminPrint(nil, "No matching player")
check(count(console(), "No matching player") == 2, "a console print right after it is still captured")

-- An echo needs the same text: a different line to an admin is captured.
env.Shared.Message("one line")
env.ServerAdminPrint(admin1, "another line")
check(count(console(), "another line") == 1, "a different line to an admin is captured")

print("all passed")

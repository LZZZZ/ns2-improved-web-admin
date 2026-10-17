-- Off-rig harness for runcommand in lua/ServerWebInterface.lua: the lines it
-- makes of what Shared.CaptureConsoleCommand returns, and the nil-client
-- branch it puts back over Shine's ServerAdminPrint for that capture only.
--
-- The capture's shape was measured on the rig, 10-12 engine, 2026-10-12: one
-- string, a script's lines prefixed with the log's "[hh:mm:ss]", the engine's
-- bare, each ending in a newline. Shine replaces ServerAdminPrint with a
-- version that prints nothing without a client, so sv_listbans from the web
-- admin came back with its audit line only.
--
-- Usage: luajit tools/spikes/console-harness.lua --core <core/lua>
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts = dofile(HERE .. "harness-args.lua")("--core <core/lua>", { "core" })
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
local printed = { }       -- what reached the server console, and the log
local delivered = { }     -- what was sent to an admin's game console
local commands = { }      -- console commands: name -> function printing its output
local env = setmetatable({ }, { __index = _G })
env.io = { open = function() return nil, "no files in this harness" end }
env.json = dkjson
env.Script = { Load = function() end }
env.CreateRingBuffer = RingBuffer
env.GetBannedPlayersList = function() return { } end
env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
env.Shared = {
    Message = function(m) table.insert(printed, "[12:00:00]" .. m) end,
    SetWebRoot = function() end,
    GetSystemTime = function() return clock.now end,
    GetTime = function() return 0 end,
    GetEntitiesWithClassname = function() return setmetatable({ }, { __index = { GetSize = function() return 0 end } }) end,
    GetSystemTimeReal = function() return clock.now end,
    GetServerPerformanceData = function() return {
        GetTimestamp = function() return 0 end, GetDurationMs = function() return 0 end,
    } end,
    -- What the engine does: run it, return everything printed meanwhile.
    CaptureConsoleCommand = function(line)
        local first = #printed + 1
        local name = line:match("^(%S*)")
        if commands[name] then commands[name]() end
        local out = { }
        for i = first, #printed do out[#out + 1] = printed[i] .. "\n" end
        return table.concat(out)
    end,
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
dofile(HERE .. "engine-stubs.lua")(env, dkjson)
setfenv(chunk, env)
chunk()

local function run(cmd)
    local _, body = hooks.WebRequest[1]({ request = "runcommand", cmd = cmd })
    return dkjson.decode(body)
end
local function check(cond, what) print((cond and "PASS " or "FAIL ") .. what); if not cond then os.exit(1) end end

-- An admin command: its audit line, then its output, through ServerAdminPrint.
commands.sv_listbans = function()
    env.Shared.Message("sv - Admin - 0: : STEAM_0:0:0: sv_listbans")
    env.ServerAdminPrint(nil, "No players are currently banned")
end
-- An engine command prints bare, with no "[hh:mm:ss]".
commands.bwlimit = function()
    table.insert(printed, "bandwidth limit: 51200 bytes/sec per player")
end

local r = run("sv_listbans")
check(r.dispatched == true, "an admin command is dispatched, by its audit line")
check(#r.lines == 2 and r.lines[1].src == "audit" and r.lines[2].src == "server",
      "its audit line, then its output")
check(r.lines[1].text == "sv - Admin - 0: : STEAM_0:0:0: sv_listbans",
      "with the log's [hh:mm:ss] taken off")
check(r.lines[2].id == 2 and r.lines[2].time == clock.now, "lines numbered from 1, at the server's time")

r = run("bwlimit")
check(r.dispatched == false and #r.lines == 1
      and r.lines[1].text == "bandwidth limit: 51200 bytes/sec per player",
      "an engine command's line, as printed")

r = run("nosuchcommand")
check(r.dispatched == false and #r.lines == 0, "no such command: nothing, not dispatched")

-- Shine replaces ServerAdminPrint on its first tick, without chaining: its
-- version sends to the client only.
local shinePrint = function(client, message)
    if client then table.insert(delivered, { client, message }) end
end
env.ServerAdminPrint = shinePrint
hooks.UpdateServer[1]()
r = run("sv_listbans")
check(#r.lines == 2 and r.lines[2].text == "No players are currently banned",
      "under Shine, a console command's ServerAdminPrint still prints")
check(env.ServerAdminPrint == shinePrint, "and Shine's is back after the capture")
local before = #printed
env.ServerAdminPrint(nil, "Shine's own line")
check(#printed == before, "outside a capture, a nil-client line stays silent")

-- An in-game admin still gets Shine's line, and the console no copy of it.
before = #printed
env.ServerAdminPrint({ id = 1 }, "Console[N/A] gagged LZZ[3869225]")
check(#delivered == 1 and #printed == before, "an admin's line goes to the admin only, as Shine sends it")

print("all passed")

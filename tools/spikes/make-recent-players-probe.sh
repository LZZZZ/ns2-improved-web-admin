#!/bin/bash
# Build recent-players-probe.lua: lua/ServerWebInterface.lua with logging for
# the five rig questions in docs/REQUIREMENTS.md item 6. Every probe line goes
# to log-Server.txt prefixed `[recent-probe]`, which survives a map change
# where the console buffer does not.
# Usage: tools/spikes/make-recent-players-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/recent-players-probe.lua"

python3 - "$src" "$out" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(src).read()

top = '''Script.Load("lua/RingBuffer.lua")

-- recent-players probe ------------------------------------------------------
function ProbeLog(fmt, ...)
    Shared.Message("[recent-probe] " .. string.format(fmt, ...))
end
ProbeClock = Shared.GetSystemTimeReal or os.clock
ProbeLog("file load: system time %s, clock %s", tostring(Shared.GetSystemTime()),
         Shared.GetSystemTimeReal and "Shared.GetSystemTimeReal" or "os.clock")
do
    local ok, f = pcall(io.open, "config://webadmin-spa/recent-players-a.json", "r")
    ProbeLog("Q4 read at file load: pcall %s, handle %s", tostring(ok), tostring(f))
    if ok and f then f:close() end
end
do
    local ok, value, pos, err = pcall(function() return json.decode('{"version":1,"seq":') end)
    ProbeLog("Q3 json.decode on truncated input: pcall ok=%s, value=%s, 2nd=%s, 3rd=%s",
             tostring(ok), tostring(value), tostring(pos), tostring(err))
end
-- ---------------------------------------------------------------------------
'''
anchor = 'Script.Load("lua/RingBuffer.lua")\n'
assert s.count(anchor) == 1
s = s.replace(anchor, top, 1)

a = "    local seq = recentSeq + 1\n"
assert s.count(a) == 1
s = s.replace(a, "    local probeStart = ProbeClock()\n" + a)
a = "    lastRecentSave = now\n"
assert s.count(a) == 1
s = s.replace(a, '''    ProbeLog("Q5 save: %d players, ok=%s, %.3f ms, %s", #list, tostring(ok),
             (ProbeClock() - probeStart) * 1000, tostring(err))
''' + a)

s += '''

-- recent-players probe: what the hooks see ----------------------------------
local function Try(f)
    local ok, v = pcall(f)
    return ok and tostring(v) or ("error: " .. tostring(v))
end

local function Describe(event, client)
    ProbeLog("Q1/Q2 %s at %s: virtual=%s id=%s address=%s player=%s players-now=%s",
        event, tostring(Shared.GetSystemTime()),
        Try(function() return client:GetIsVirtual() end),
        Try(function() return client:GetUserId() end),
        Try(function()
            local a = Server.GetClientAddress(client)
            return a and IPAddressToString(a) or "nil"
        end),
        Try(function()
            local p = client:GetControllingPlayer()
            return p and p:GetName() or "nil"
        end),
        Try(function() return Shared.GetEntitiesWithClassname("Player"):GetSize() end))
end

Event.Hook("ClientConnect", function(client) Describe("ClientConnect", client) end)
Event.Hook("ClientDisconnect", function(client) Describe("ClientDisconnect", client) end)

local probeFirstTick = true
Event.Hook("UpdateServer", function()
    if probeFirstTick then
        probeFirstTick = false
        ProbeLog("first tick at %s", tostring(Shared.GetSystemTime()))
    end
end)
'''
open(out, "w").write(s)
PY
luajit -e "assert(loadfile('$out'))"
echo "wrote $out"

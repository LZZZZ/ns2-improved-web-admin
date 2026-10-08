#!/bin/bash
# Build engine0926-probe.lua: lua/ServerWebInterface.lua with the probe branch
# from engine0926-branch.lua at the top of OnWebRequest, and the WebRequest
# hook wrapped so the probe can report every argument the engine passes.
# Usage: tools/spikes/make-engine0926-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/engine0926-probe.lua"

grep -q '^local function OnWebRequest(actions)$' "$src"
grep -q '^Event.Hook("WebRequest", OnWebRequest)$' "$src"

awk -v branch="$here/engine0926-branch.lua" '
  /^local function OnWebRequest\(actions\)$/ {
    print; while ((getline line < branch) > 0) print line; next
  }
  /^Event.Hook\("WebRequest", OnWebRequest\)$/ {
    print "Event.Hook(\"WebRequest\", function(...)"
    print "    local n = select(\"#\", ...)"
    print "    local seen = { count = n, types = {} }"
    print "    for i = 1, n do seen.types[i] = type((select(i, ...))) end"
    print "    webadminSpaProbeArgs = seen"
    print "    return OnWebRequest(...)"
    print "end)"
    next
  }
  { print }
' "$src" > "$out"
echo "wrote $out"

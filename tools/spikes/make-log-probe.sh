#!/bin/bash
# Build log-probe.lua: lua/ServerWebInterface.lua with the probe branch from
# log-branch.lua at the top of OnWebRequest.
# Usage: tools/spikes/make-log-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/log-probe.lua"

grep -q '^local function OnWebRequest(actions)$' "$src"

awk -v branch="$here/log-branch.lua" '
  /^local function OnWebRequest\(actions\)$/ {
    print; while ((getline line < branch) > 0) print line; next
  }
  { print }
' "$src" > "$out"
echo "wrote $out"

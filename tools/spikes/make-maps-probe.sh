#!/bin/bash
# Build maps-probe.lua: lua/ServerWebInterface.lua with the probe branch from
# maps-branch.lua at the top of OnWebRequest.
# Usage: tools/spikes/make-maps-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/maps-probe.lua"

grep -q '^local function OnWebRequest(actions)$' "$src"

awk -v branch="$here/maps-branch.lua" '
  /^local function OnWebRequest\(actions\)$/ {
    print; while ((getline line < branch) > 0) print line; next
  }
  { print }
' "$src" > "$out"
echo "wrote $out"

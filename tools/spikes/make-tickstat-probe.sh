#!/bin/bash
# Build tickstat-probe.lua: lua/ServerWebInterface.lua with the probe branch from
# tickstat-branch.lua at the top of OnWebRequest.
# Usage: tools/spikes/make-tickstat-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/tickstat-probe.lua"

grep -q '^local function OnWebRequest(actions)$' "$src"

awk -v branch="$here/tickstat-branch.lua" '
  /^local function OnWebRequest\(actions\)$/ {
    print; while ((getline line < branch) > 0) print line; next
  }
  { print }
' "$src" > "$out"
echo "wrote $out"

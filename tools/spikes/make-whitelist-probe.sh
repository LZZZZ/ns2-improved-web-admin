#!/bin/bash
# Build whitelist-probe.lua: lua/ServerWebInterface.lua with the probe's
# functions from whitelist-helpers.lua just before OnWebRequest, and the
# branch from whitelist-branch.lua at the top of it.
# Usage: tools/spikes/make-whitelist-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/whitelist-probe.lua"

grep -q '^local function OnWebRequest(actions)$' "$src"

awk -v helpers="$here/whitelist-helpers.lua" -v branch="$here/whitelist-branch.lua" '
  /^local function OnWebRequest\(actions\)$/ {
    while ((getline line < helpers) > 0) print line
    print; while ((getline line < branch) > 0) print line; next
  }
  { print }
' "$src" > "$out"
echo "wrote $out"

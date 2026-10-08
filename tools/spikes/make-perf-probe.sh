#!/bin/bash
# Build perf-probe.lua: lua/ServerWebInterface.lua with the probe branch from
# perf-branch.lua at the top of OnWebRequest and the sampler from
# perf-sampler.lua appended.
# Usage: tools/spikes/make-perf-probe.sh  (writes next to itself)
set -eu
here="$(cd "${0%/*}" && pwd)"
src="$here/../../lua/ServerWebInterface.lua"
out="$here/perf-probe.lua"

grep -q '^local function OnWebRequest(actions)$' "$src"

awk -v branch="$here/perf-branch.lua" '
  /^local function OnWebRequest\(actions\)$/ {
    print; while ((getline line < branch) > 0) print line; next
  }
  { print }
' "$src" > "$out"
cat "$here/perf-sampler.lua" >> "$out"
echo "wrote $out"

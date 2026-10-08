#!/bin/bash
# Convert the game's skill tier badges into the panel's sprite sheet.
#
# The game draws the scoreboard's skill badge from ui/skill_tier_icons.dds:
# 100x320, ten 32 px rows, top to bottom unknown, bot, rookie and tiers 1-7
# (GUIScoreboard.lua: row = tier + 2). The dedicated server does not carry
# it (no UI art), so it ships in the mod, as a PNG with its alpha: the glows
# do not survive a 256-colour palette. PNG and not WebP for the reason
# make-minimaps.sh gives.
#
#   tools/make-skill-tiers.sh <client install>/ns2/ui/skill_tier_icons.dds
#
# Take the game's own copy, not a mod's: a workshop mod can replace the
# sheet (one does, with a joke one).
#
# Writes panel/src/assets/skill-tiers.png, which the build hashes into web/.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:?usage: tools/make-skill-tiers.sh <client install>/ns2/ui/skill_tier_icons.dds}
OUT=panel/src/assets/skill-tiers.png
[ -f "$SRC" ] || { echo "no skill_tier_icons.dds at $SRC" >&2; exit 1; }
command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
size=$(magick identify -format '%wx%h' "$SRC")
[ "$size" = 100x320 ] || { echo "expected 100x320, $SRC is $size" >&2; exit 1; }
magick "$SRC" -strip -define png:compression-level=9 "PNG32:$OUT"
du -h "$OUT"

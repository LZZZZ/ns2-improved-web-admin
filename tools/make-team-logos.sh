#!/bin/bash
# Convert the game's team logos into the Players tab's section icons.
#
# The game's end-of-round stats draw each team under ui/logo_marine.dds and
# ui/logo_alien.dds (GUIGameEndStats.lua): 256x256, with alpha. The dedicated
# server does not carry them (no UI art), so they ship in the mod, scaled to
# 64 px -- shown at 26, which leaves room for a 2x screen -- as PNG
# with their alpha, for the reason make-skill-tiers.sh gives.
#
#   tools/make-team-logos.sh <client install>/ns2/ui
#
# Take the game's own copies, not a mod's: a workshop mod can replace them.
#
# Writes panel/src/assets/logo-marines.png and logo-aliens.png, which the
# build hashes into web/.
set -euo pipefail
cd "$(dirname "$0")/.."
UI=${1:?usage: tools/make-team-logos.sh <client install>/ns2/ui}
command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
for team in marine alien; do
  src=$UI/logo_$team.dds
  out=panel/src/assets/logo-${team}s.png
  [ -f "$src" ] || { echo "no logo_$team.dds at $src" >&2; exit 1; }
  size=$(magick identify -format '%wx%h' "$src")
  [ "$size" = 256x256 ] || { echo "expected 256x256, $src is $size" >&2; exit 1; }
  magick "$src" -strip -filter Lanczos -resize 64x64 -define png:compression-level=9 "PNG32:$out"
  du -h "$out"
done

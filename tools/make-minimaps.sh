#!/bin/bash
# Convert the stock maps' overviews into the panel's minimaps.
#
# The server has them as ns2/maps/overviews/<map>.tga, 1024x1024 with alpha.
# Browsers do not show TGA and the engine serves only the web root, so they
# ship in the mod: trimmed, 320 px, a 64-colour PNG with alpha (about 22 KB
# each). PNG and not WebP because PNG is in every MIME table the engine's
# binaries carry, and the engine's nosniff needs the type right.
#
#   tools/make-minimaps.sh <server>/ns2/maps/overviews
#
# Writes panel/src/minimaps/<map>.png, which the build hashes into web/.
# Re-run after a game update that changes a map; commit what changes.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:?usage: tools/make-minimaps.sh <server>/ns2/maps/overviews}
OUT=panel/src/minimaps
[ -d "$SRC" ] || { echo "no overviews at $SRC" >&2; exit 1; }
command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
mkdir -p "$OUT"
rm -f "$OUT"/*.png
for tga in "$SRC"/*.tga; do
  map=$(basename "$tga" .tga)
  magick "$tga" -trim +repage -resize 320x320 -dither FloydSteinberg -colors 64 \
    -strip "PNG8:$OUT/$map.png"
done
ls "$OUT" | wc -l | xargs printf '%s minimaps, '
du -ch "$OUT"/*.png | tail -1

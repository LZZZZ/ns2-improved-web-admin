#!/bin/bash
# Cut the sliding gorge out of the game's calling cards for the panel's
# background (bottom right, behind the content).
#
# ui/callingcards/callingcards_1.dds is a 4 x 12 sheet of 512 px cards with
# alpha; the gorge is row 6, column 2. Trimmed to the drawing (507 px wide,
# shown at 480) as a 256-colour PNG with alpha from libimagequant: 69 KB,
# where truecolour is 245 KB. Not WebP: the engine serves .webp as text/html,
# with nosniff.
#
#   tools/make-gorge.sh <client install>/ns2/ui
#
# Take the game's own copy, not a mod's: a workshop mod can replace it.
#
# Writes panel/src/assets/gorge.png, which the build hashes into web/.
set -euo pipefail
cd "$(dirname "$0")/.."
UI=${1:?usage: tools/make-gorge.sh <client install>/ns2/ui}
command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
python3 -I -c 'from PIL import features; assert features.check("libimagequant")' 2>/dev/null \
  || { echo "needs Pillow built with libimagequant" >&2; exit 1; }
src=$UI/callingcards/callingcards_1.dds
out=panel/src/assets/gorge.png
[ -f "$src" ] || { echo "no callingcards/callingcards_1.dds at $src" >&2; exit 1; }
size=$(magick identify -format '%wx%h' "$src")
[ "$size" = 2048x6144 ] || { echo "expected 2048x6144, $src is $size" >&2; exit 1; }
magick "$src" -crop 512x512+512+2560 +repage -trim +repage -strip "PNG32:$out"
python3 -I -c '
import sys
from PIL import Image
Image.open(sys.argv[1]).quantize(256, method=Image.Quantize.LIBIMAGEQUANT).save(sys.argv[1], optimize=True)
' "$out"
magick identify -format '%wx%h ' "$out"
du -h "$out"

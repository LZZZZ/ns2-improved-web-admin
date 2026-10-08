#!/bin/bash
# Stage the Workshop item: only what the server mounts, plus the license.
#
#   tools/build-workshop.sh [--visibility 0|1|2|3] [--changenote TEXT] [--allow-dirty]
#
# Writes build/workshop/ (gitignored):
#   content/           web/, lua/ and LICENSE, verbatim: the item's files
#   preview.jpg        workshop/preview.jpg
#   workshopitem.vdf   for `steamcmd +workshop_build_item`
#
# The item id is in workshop/publishedfileid. Without that file steamcmd
# creates a new item and prints its id; save it there and commit it, or the
# next upload creates another item. --visibility (0 public, 1 friends only,
# 2 private, 3 unlisted) is required for a new item; on an update, leaving
# it out keeps what the item has. The title is fixed here, the description
# is workshop/description.bbcode with {version} replaced by kModVersion from
# lua/ServerWebInterface.lua.
#
# The script uploads nothing. It prints the steamcmd command to run, since
# the login is interactive (password, Steam Guard).
set -euo pipefail
cd "$(dirname "$0")/.."

TITLE="NS2 Improved Web Admin"
VISIBILITY=""
CHANGENOTE=""
ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --visibility) VISIBILITY=${2:?}; shift 2 ;;
    --changenote) CHANGENOTE=${2:?}; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    *) echo "usage: tools/build-workshop.sh [--visibility 0|1|2|3] [--changenote TEXT] [--allow-dirty]" >&2; exit 2 ;;
  esac
done

# Only committed files go up, so the item can be traced to a commit.
if [ "$ALLOW_DIRTY" = 0 ] && [ -n "$(git status --porcelain -- web lua LICENSE workshop)" ]; then
  echo "web/, lua/, LICENSE or workshop/ has uncommitted changes; commit them or pass --allow-dirty" >&2
  exit 1
fi

VERSION=$(sed -n 's/^local kModVersion = "\(.*\)"$/\1/p' lua/ServerWebInterface.lua)
[ -n "$VERSION" ] || { echo "kModVersion not found in lua/ServerWebInterface.lua" >&2; exit 1; }
[ -f web/index.html ] || { echo "no web/index.html; build the panel first" >&2; exit 1; }

ID=""
[ -f workshop/publishedfileid ] && ID=$(tr -d '[:space:]' < workshop/publishedfileid)
if [ -n "$ID" ]; then
  [[ "$ID" =~ ^[0-9]+$ ]] || { echo "workshop/publishedfileid is not a number: $ID" >&2; exit 1; }
elif [ -z "$VISIBILITY" ]; then
  echo "a new item needs --visibility (3 = unlisted, to test before going public)" >&2
  exit 1
fi
[ -z "$VISIBILITY" ] || [[ "$VISIBILITY" =~ ^[0-3]$ ]] || { echo "--visibility is 0, 1, 2 or 3" >&2; exit 1; }
[ -n "$CHANGENOTE" ] || CHANGENOTE="Version $VERSION"

DESCRIPTION=$(sed "s/{version}/$VERSION/g" workshop/description.bbcode)
# A VDF string ends at a double quote; refuse rather than guess at escaping.
for v in "$DESCRIPTION" "$CHANGENOTE" "$TITLE"; do
  case "$v" in *'"'*|*'\'*) echo "a double quote or backslash would break the VDF: ${v:0:60}..." >&2; exit 1 ;; esac
done
[ ${#DESCRIPTION} -le 8000 ] || { echo "description is ${#DESCRIPTION} characters; Steam takes 8000" >&2; exit 1; }

OUT=build/workshop
rm -rf "$OUT"
mkdir -p "$OUT/content"
cp -r web lua LICENSE "$OUT/content/"
cp workshop/preview.jpg "$OUT/preview.jpg"
ABS=$(cd "$OUT" && pwd)

{
  echo '"workshopitem"'
  echo '{'
  printf '\t"appid"\t\t"4920"\n'
  [ -z "$ID" ] || printf '\t"publishedfileid"\t\t"%s"\n' "$ID"
  printf '\t"contentfolder"\t\t"%s"\n' "$ABS/content"
  printf '\t"previewfile"\t\t"%s"\n' "$ABS/preview.jpg"
  [ -z "$VISIBILITY" ] || printf '\t"visibility"\t\t"%s"\n' "$VISIBILITY"
  printf '\t"title"\t\t"%s"\n' "$TITLE"
  printf '\t"description"\t\t"%s"\n' "$DESCRIPTION"
  printf '\t"changenote"\t\t"%s"\n' "$CHANGENOTE"
  echo '}'
} > "$OUT/workshopitem.vdf"

echo "staged $TITLE $VERSION in $OUT (item ${ID:-new}, visibility ${VISIBILITY:-unchanged})"
(cd "$OUT/content" && find . -type f | sort | sed 's|^\./|  |')
du -sh "$OUT/content" | cut -f1 | xargs printf 'content: %s\n'
echo
echo "upload with:"
echo "  ${STEAMCMD:-steamcmd} +login <steam account> +workshop_build_item $ABS/workshopitem.vdf +quit"

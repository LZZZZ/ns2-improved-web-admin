#!/bin/bash
# Capture one real response per web-admin request type from a live server
# into fixtures/live/ (gitignored -- responses carry names, SteamIDs, IPs).
#
# Read-only by default. Pass --mutating to also exercise setmapcycle, which
# writes the cycle back as it was read.
#
# Usage: tools/capture-fixtures.sh --env FILE [--mutating]
#   FILE is a shell file that sets WEBUSER, WEBPASS and WEBPORT.
set -u

ENVFILE="" MUTATING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENVFILE="${2:-}"; shift 2 ;;
    --mutating) MUTATING=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ENVFILE" ] || { echo "usage: $0 --env FILE [--mutating]" >&2; exit 2; }
. "$ENVFILE"
BASE="http://127.0.0.1:${WEBPORT}"
OUT="$(cd "${0%/*}/.." && pwd)/fixtures/live"
mkdir -p "$OUT"

get() {   # get <name> <query>
  local name="$1" q="$2"
  curl -s --digest -u "$WEBUSER:$WEBPASS" --max-time 35 \
       -D "$OUT/$name.headers" -o "$OUT/$name.json" -w '%{http_code}' \
       "$BASE/?$q"
}
report() { printf '%-24s %s  %6s B  %s\n' "$1" "$2" "$(stat -c%s "$OUT/$1.json" 2>/dev/null || echo 0)" "$(head -c 60 "$OUT/$1.json" 2>/dev/null | tr -d '\n')"; }

echo "== read-only =="
for spec in \
  "serverstate:" \
  "getbans:request=getbans" \
  "getreservedslots:request=getreservedslots" \
  "getrecentplayers:request=getrecentplayers" \
  "getchatlist:request=getchatlist&since=0" \
  "getperf:request=getperf" \
  "getlog:request=getlog" \
  "getinstalledmodslist:request=getinstalledmodslist" \
  "getmaplist:request=getmaplist" \
  "getmapcycle:request=getmapcycle" \
  "getmapvote:request=getmapvote" \
  "getmods-loading:request=getmods&searchtext=combat" \
; do
  name="${spec%%:*}"; q="${spec#*:}"
  code=$(get "$name" "$q"); report "$name" "$code"
done

# getmods is asynchronous: the first call returns {"loading":true} and the
# result only appears on a later identical call. Poll it.
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  code=$(get "getmods-settled" "request=getmods&searchtext=combat")
  grep -q '"loading"' "$OUT/getmods-settled.json" || break
done
report "getmods-settled" "$code (after ${i} polls)"

code=$(get "runcommand-failed" "request=runcommand&cmd=sv_kick%20NoSuchPlayer"); report "runcommand-failed" "$code"
code=$(get "runcommand-unknown" "request=runcommand&cmd=sv_nonsense_command"); report "runcommand-unknown" "$code"
code=$(get "runcommand-slots" "request=runcommand&cmd=sv_reserved_slots%203"); report "runcommand-slots" "$code"

# The 401 challenge itself -- documents realm, nonce, qop.
curl -s -o /dev/null -D "$OUT/challenge.headers" --max-time 10 "$BASE/"
echo "challenge:              $(grep -i '^www-authenticate' "$OUT/challenge.headers" | tr -d '\r')"

# Cross-site Origin rule.
oc=$(curl -s -o "$OUT/origin-refused.json" -w '%{http_code}' --digest \
     -u "$WEBUSER:$WEBPASS" -H 'Origin: http://localhost:5173' --max-time 10 "$BASE/")
echo "foreign Origin:         HTTP $oc  $(head -c 80 "$OUT/origin-refused.json")"

if [ "$MUTATING" = 1 ]; then
  echo "== mutating =="
  # A POST's query string never reaches Lua: everything goes in the body.
  code=$(curl -s --digest -u "$WEBUSER:$WEBPASS" --max-time 35 -X POST \
         --data "request=setmapcycle" --data-urlencode "data@$OUT/getmapcycle.json" \
         -D "$OUT/setmapcycle.headers" -o "$OUT/setmapcycle.json" -w '%{http_code}' "$BASE/")
  report "setmapcycle" "$code"
fi

echo
echo "written to $OUT"

#!/bin/bash
# Run the browser gates one at a time, each against freshly started mocks.
#
# Several gates drive the same mock and change its state, so they must not
# overlap, and each gets mocks that have just loaded the fixtures. Build the
# panel first (`cd panel && npx vite build`): the mocks serve `web/`.
#
#   tools/browser-checks/run-all.sh --stock-web <server>/ns2/web    every gate
#   tools/browser-checks/run-all.sh spa-chat        only these
#   tools/browser-checks/run-all.sh "spa-players@SPA_EXPECT_MOD=1 MOCK_URL=http://127.0.0.1:8094"
#
# --stock-web is the shipped 2012 panel, a server install's ns2/web, which the
# mock-acceptance gate runs against the mock. Only that gate needs it.
#
# One line per gate; the full output is in $LOG/<gate>.txt, and each mock's
# in $LOG/mock-<port>.log. Exit status 0 only if every gate passed.
set -u
cd "$(dirname "$0")/../.." || exit 1
LOG=${LOG:-${TMPDIR:-/tmp}/webadmin-spa-gates}
mkdir -p "$LOG"

# port|flags|stock-web (the 2012 panel instead of web/, for mock-acceptance)
MOCKS=(
  "8090|--perf-rate 2|stock-web"
  "8091|"
  "8094|--mod --perf-window 2"
  "8095|"
  "8096|--mod --shine"
  "8097|--mod --shine=ban,reservedslots,mapvote"
  "8098|--shine"
  "8099|--mod --shine=ban,reservedslots,mapvote --maps=modded"
  "8100|--mod --log=off"
  "8101|--no-chat-buffer"
  "8102|--mod --beta-players"
  "8103|--mod --whitelist=fail --whitelist-delay 300"
)

pids=()
start() {
  pids=()
  for m in "${MOCKS[@]}"; do
    IFS='|' read -r port args webflag <<<"$m"
    web=(--web web); [ "$webflag" = stock-web ] && web=(--web "$STOCK_WEB")
    # shellcheck disable=SC2086
    node mock/server.js --port "$port" "${web[@]}" $args >"$LOG/mock-$port.log" 2>&1 &
    pids+=($!)
  done
  for m in "${MOCKS[@]}"; do
    port=${m%%|*}
    for _ in $(seq 50); do
      curl -s -o /dev/null "http://127.0.0.1:$port/index.html" && break
      sleep 0.1
    done
  done
}
stop() { [ ${#pids[@]} -gt 0 ] && kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null; pids=(); }
trap stop EXIT

STOCK_WEB=web
GATES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --stock-web) STOCK_WEB="${2:-}"; shift 2 ;;
    *) GATES+=("$1"); shift ;;
  esac
done
if [ ${#GATES[@]} -eq 0 ]; then
  GATES=(mock-acceptance spa-players
         "spa-players@SPA_EXPECT_MOD=1 MOCK_URL=http://127.0.0.1:8094"
         spa-console spa-bans spa-slots spa-recent spa-maps spa-mods
         spa-workshop spa-perf spa-settings spa-log spa-chat)
fi

for g in "${GATES[@]}"; do
  if [ "${g%%@*}" = mock-acceptance ] && [ ! -f "$STOCK_WEB/js/rcon.js" ]; then
    echo "mock-acceptance needs --stock-web <server>/ns2/web (the shipped 2012 panel)" >&2
    exit 2
  fi
done

rc=0
for g in "${GATES[@]}"; do
  name=$g env=""
  if [[ $g == *@* ]]; then name=${g%%@*}; env=${g#*@}; fi
  tag=${g//[^A-Za-z0-9-]/_}
  out="$LOG/${tag:0:40}.txt"
  start
  # shellcheck disable=SC2086
  env $env python3 "tools/browser-checks/$name.py" >"$out" 2>&1
  r=$?
  stop
  printf '%-36s rc=%s  %s\n' "$g" "$r" "$(grep -E '[0-9]+/[0-9]+ checks passed' "$out" | tail -1)"
  [ $r -ne 0 ] && rc=1
done
exit $rc

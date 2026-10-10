# The mock server

A stand-in for an NS2 dedicated server's web admin, replaying the
[fixtures](../fixtures) captured from a real server. No dependencies:

```bash
node mock/server.js --web web
```

It serves the API on `127.0.0.1:8080` and the static files under `--web`:
`web/` for the new panel, or a server install's `ns2/web/` for the 2012
one. `node mock/server.js --help` lists the options. 8080 is the real
server's default, so pass `--port` when the [rig](../docs/TESTING.md) is
also up.

It exists because a dev server on another port is refused by the engine's
Origin rule ([CONSTRAINTS.md](../docs/CONSTRAINTS.md#the-origin-rule)),
and because UI work should not need a 3.5 GB install running.

## What it reproduces

Behaviour, not just bodies, as measured on real servers
([API.md](../docs/API.md)). By default it is a **stock** server, which
the 2012 panel and the faithfulness test need.

| | |
| --- | --- |
| Routing | One endpoint. `/` and any path that is not a file return the server-state blob: no directory index, no `404`. The panel is at `/index.html`. |
| Methods | `GET` and `POST` only; others `405`. Every write also works as a `GET`. A `POST`'s parameters come from its form body only. |
| Origin | Compared with `Host`; a mismatch, `Origin: null` included, is refused `403` and logged. |
| Host | Without `--auth`, a `Host` that is neither `localhost` nor an IP literal is refused `403`, static files included. `--no-host-rule` turns it off. |
| Headers | The 09-03 hardening set on every reply. |
| Writes | `200`, empty body, `Content-Type: text/html`. |
| Body cap | 64 KB; a larger declared `Content-Length` is refused unread. |
| `getmods` | `{"loading": true}`, then results cached 60 s by text and page run together, a search still running after 30 s restarted, at most 50 hits, the page ignored, `{"items":[]}` when empty. Without `searchtext` no search starts; a non-numeric `p` is an empty `200`. The catalogue is the fixture's 50 plus four made-up items (three one term finds, one with markup and BBCode). |
| `installmod` | A catalogue id appears in `getinstalledmodslist` 3 s later under its title; any other never appears; a malformed one is dropped silently. |
| Console commands | Run, change state, and return nothing. A kicked player is still in the reply that kicked them. `sv_reset` ends the round (with `--mod`, printing the rig's three lines); `sv_rrall`, `sv_randomall` and `sv_forceeventeams` move players; `sv_mute` and `sv_resetround` do not exist. |
| Console output | What the game prints, checked against `ServerAdminCommands.lua` or the rig: an unknown command, and a successful `sv_kick`, `sv_slay`, `sv_switchteam` or `sv_unban`, print nothing; `sv_help` prints help but no dispatch receipt; `sv_reserved_slots` reports through `Shared.Message`; `sv_ban` prints `<name> has been banned` or `Player with SteamId N has been banned`. Reserved slot commands take the name as one argument, key slots by name, ignore an amount above `max_players` silently, and print nothing when a removal matches nobody. |
| `getperfdata` | The fixture's readings moved to now, then one more every `--perf-rate` seconds (default 60), 30 kept, emptied by `sv_changemap`. |
| Mod ids | Hex strings both ways, with the `:` escape for non-workshop sources. |
| Digest auth | Optional (`--auth`): 301 s nonce lifetime, single-use `nc`, `stale="true"` refusals. |

### `--mod`: a server running this repo's Lua

On a stock server the mod's request types fall through to the state blob,
which is what a panel pointed at the wrong server sees. `--mod` adds them:

| | |
| --- | --- |
| `mod_version`, `max_players` (16), `map_loaded_at` | In the state blob. `map_loaded_at` is `getperf`'s `loaded_at`. |
| `/` | A request with no parameters gets the page leading to `/index.html` (`fixtures/root-mod.html`). |
| `runcommand` | What a command printed, tagged `audit`, `admin` or `server`; `dispatched` is the audit line. |
| `getconsole` | The same capture as a stream, with `since` and `dropped`. |
| `getchatlist` | With `since`, the mod's ring of 200 with times; without, the game's 20. Both empty at `sv_changemap`, ids from 1. |
| `getbans` | The bans in force, from Shine's table under `--shine`, vanilla's otherwise. |
| `getrecentplayers` | The synthetic `fixtures/getrecentplayers.json` moved to now, plus the humans connected. A kick, ban or map change leaves a player listed, not connected. With `--shine`, an `sh_banid` of an absent listed player is stored under their name. |
| `getmapcycle` | Reads the file. Stock answers from the copy loaded with the map, so a hand edit (`/__mock/cycle-file`) shows only with `--mod` (CONSTRAINTS item 13). |
| `setmapcycle` | Validated with the Lua's wording: `{"ok": false, "error"}` writes nothing, `{"ok": true, "cycle"}` is the file read back. Unknown keys pass through. Stock answers the empty `200`, and a cycle with no `maps` writes nothing. |
| `getmapvote` | `{"enabled": false}`, or with `--shine`'s `mapvote` options from the cycle (read at boot and `sv_changemap` only), round limit 2, and Shine's next map. |
| `getmods`, `installmod` | The mod's replies (CONSTRAINTS item 2). |
| `getinstalledmodslist` | Rows gain `active`, fixed at map load: the two hotfix mods, the cycle's global mods and the map's own. A cycle edit shows after `sv_changemap`. |
| `getperf` | Made-up 10 s windows (`--perf-window <s>` to shorten) in the rig's shape, seeded with half an hour of history, at 60/60/60 with interp 85 (the state blob's `frame_rate` follows, so nothing can assume 30). `sv_changemap` starts over. `engine` is what the Lua's log scan finds: `tickstat N` (off until run; `--tickstat <s>` boots with it on and half an hour behind), `perfmon` (its block, stepping the level) and `bwlimit` (the warning under 2048 B a snapshot) write to the log as the 09-27 engine does, and `runcommand` gets no lines for them. `config.bw_limit` follows `bwlimit`. |
| `getlog` | The Lua's algorithm step for step over a buffer: a header, a boot and 40 rounds of made-up history from `log-seed.txt` (about 75 KB), then every line the console tees, map loads, the engine's `Script tracing` pair every 30 s, and the mod's check line per map load. Offsets are bytes. `--log=off`: the file cannot be opened, with the rig's error. |
| `getwhitelist` | The rig's read (`fixtures/getwhitelist-rig.json`). With no copy, the first request answers `fetching` and the read lands 1.5 s later (`--whitelist-delay <ms>`). `--whitelist=cached` starts with a copy; `--whitelist=fail` fails with curl's unknown-host message, then waits 5 minutes as the mod does. |
| Player `skill` fields | Made up but stable per Steam id; -1 for bots. `skill_tier` through the game's `GetPlayerSkillTier`. |
| `--beta-players` | The 09-26+ engine's per-player fields, made up: the first human plays a Family Shared copy with 37 time-credit and 2 other rejected moves. |
| The stock bugs | Fixed, as with the mod's Lua. |

### `--maps=modded`

Swaps the stock install's cycle, map list and installed mods (17 maps, no
mods) for a modded server's, captured on the rig: 22 global mods, per-map
mods, 40 maps of which 23 come from mods, a Shine per-map option (`"min":
12` on `ns2_veil`) and a map group (`fixtures/getmapcycle-shine-options.json`).

### `--shine`

A simulated Shine with the plugins named (`--shine=ban,reservedslots,mapvote,basecommands`;
bare `--shine` is `ban,mapvote,basecommands`), with or without `--mod`.
Wording as measured on the rig ([CONSTRAINTS.md](../docs/CONSTRAINTS.md#shine)).

| | |
| --- | --- |
| Ban table | Shine's, seeded from the synthetic `fixtures/getbans-shine.json`. `getbanlist` serves it as Shine's `GetBannedPlayersList()` does: string ids, `6e+24` for a permanent ban, a different order on every call. |
| `sh_ban`, `sh_banid`, `sh_unban` | Shine's lines and `ran command ... with arguments:` receipt, no audit line. `sh_ban` targets only connected players; anything else gets `You cannot target yourself with this command.` |
| `sv_ban`, `sv_unban` | Run both Shine's and vanilla's commands, so an `sv_ban` of an absent id lands only in the vanilla list. |
| `sh_setresslots` | With `reservedslots`; `getreservedslots` then carries `shine.slots` (with `--mod`). |
| `sh_gag`, `sh_ungag` | With `basecommands`: Shine's lines and receipt. A gagged player's chat never arrives; a map change clears gags. |
| `sv_say` | With `basecommands`, Shine's `sh_say`: only the receipt, and the message in the chat. |
| `shine` | In the state blob with `--mod`; with `basecommands`, players carry `gagged`. |

Not modelled: Shine swallowing vanilla admin-command output. `--mod`
mocks the fixed Lua.

### The stock bugs

The 2012 panel was written against a server that has these, so a stock
mock has them too. `--fix a,b` switches the named ones off; `--fix-all` and
`--mod` switch off all three.

| Flag | What it reproduces |
| --- | --- |
| `setreservedslotamount` | Answers `200` and changes nothing (CONSTRAINTS item 7). |
| `unban` | `sv_unban` never matches a listed ban (item 8). |
| `banPruning` | Expired bans stay listed (item 9). |
| *(always)* | A bot's `steamid` is `0`, so per-player commands aimed at one do nothing (CURRENT-UI defect 7). |

## Control endpoints

Not part of the real API, never requested by the panel, removed by
`--no-control`:

```
GET /__mock/state          the whole simulated server as JSON
GET /__mock/503?n=3        answer the next 3 requests with 503
GET /__mock/slow?ms=2000   delay every reply by 2000 ms
GET /__mock/reset          reload the fixtures
GET /__mock/recent-load?status=fallback[&error=...]
                           what getrecentplayers reports about its file
GET /__mock/round?started=1|0
                           start or end the round
GET /__mock/chat?text=<t>[&player=<name>][&team=1][&teamOnly=1][&steamid=<id>][&n=3]
                           a player says something (n times, numbered)
GET /__mock/cycle-file?time=45[&append=ns2_x][&mod=<id>]
                           edit MapCycle.json behind the game's back
GET /__mock/workshop?search=hang|offline[&n=2][&install=never][&timeout=<s>]
                           the next n workshop searches hang or fail, the
                           next install never arrives
GET /__mock/perf?score=-20[&interp_fails=3][&worst_tick_ms=80][&emit=1]
                           the next getperf window's values (any numeric
                           field); emit=1 closes it at once; tickrate_config=80
                           and the like change the configured rates
GET /__mock/tickstat?choked_pct=12[&snap_p99_bytes=4000][&emit=1][&rate=down|up]
                           the next TICKSTAT line's values (--mod); emit=1
                           writes it now; rate= logs a player's rate step
GET /__mock/log?append=<text>[&n=3] | partial=<text> | burst=<bytes>
               | truncate=1 | restart=1 | stale=1|0
                           write to log-Server.txt: lines, a line with no
                           newline yet, a burst, a cut to the header, a new
                           file (restart=<n>: with n rounds of history), or
                           a copy the server is not writing
```

- `log` answers with the file's size and id. `partial` then `append` is a
  line finished late; `burst=700000` exceeds one reply; `restart` changes
  the header's time, which is to the second, so wait a second between two.
- `workshop`: `hang` is a search Steam never answers, `offline` one it
  fails (at once, empty). A stock server restarts a search after 30 s, so
  a hang that outlasts the restart needs `n=2`. `install=never` is an id
  Steam does not have. `timeout` shortens the mod's 30 s.
- `recent-load` takes `ok`, `fallback`, `empty` or `unreadable`; `error`
  reports a failing save.
- `cycle-file` appends `mod` as written, so `mod=zzzz` plants a junk id.
- `503` is what a real server sends when a request gives up after 30 s.

## Not reproduced

- **The login lockout** (10 failures per address per minute), so a retry
  loop that would lock you out of a real server runs happily here.
- **The 30 s timeout itself**: `503` can be triggered, not earned.
- **The game.** Teams, resources and scores move only as far as a console
  command moves them.

## Proving it faithful

The *shipped* 2012 panel must run against it unmodified:

```bash
node mock/server.js --port 8090 --perf-rate 2 --web <server>/ns2/web &
python3 tools/browser-checks/mock-acceptance.py
```

22 checks in headless Chrome across all six tabs (kick, ban, reserved
slot, map cycle save, workshop paging, performance chart), including that
the reproduced bugs still misbehave. Exit status 0 only if all pass.

## Files

| File | What it is |
| --- | --- |
| `server.js` | The engine half: routing, the hardening rules, digest auth, static files. |
| `state.js` | The Lua half: server state, the request types, the console commands. |
| `log-seed.txt` | The made-up history `--mod`'s log starts with: a boot, then a round repeated. |

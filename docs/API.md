# Web admin HTTP API

The API as `lua/ServerWebInterface.lua` implements it, the only handler.
It needs the 10-12 beta engine or later: it calls
`Shared.CaptureConsoleCommand`, `Shared.ReadLog`, `Shared.JsonEncode`,
`Server.GetTickStat` and `Server.GetIsModWhitelisted`, and reads
`WebRequest`'s second argument (CONSTRAINTS item 18). Every request type
has a captured response in `fixtures/` ([TESTING.md](TESTING.md)).

This file is the prose. [openapi.yaml](openapi.yaml) is the contract: every
request type, parameter, response schema and refusal, checked against the
fixtures by `tools/check-openapi.py`.

## Shape

```lua
Shared.SetWebRoot("web")            -- the static root
Event.Hook("WebRequest", OnWebRequest)
```

Every call is `GET` or `POST` to `/`, with the action in the `request`
parameter. A handled request returns `200` with a JSON body; an
unrecognised `request` falls through to the server-state blob.

### No 404

A path that is not a file under the web root reaches the handler. A
request with no parameters is answered by its path and `Accept`
(CONSTRAINTS item 6):

| Request | Answer |
| --- | --- |
| `/`, `/?`, `/?foo`, `POST /` with an empty body, from a browser (`Accept` names `text/html`) | `text/html`, the panel |
| The same from a script (`curl`, `fetch()`, an auto-shutdown check) | `application/json`, the state |
| `/missing.png`, `/index.htm`, any other path | `text/html`, the panel |
| `/?request=json`, `/?foo=1`, `/?foo=`, `/?request=` | `application/json`, the state |

A key without `=` never reaches Lua; one with `=` does, even empty. Never
use the status code to detect a missing asset.

### Response headers

Every reply carries:

```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: frame-ancestors 'none'
Referrer-Policy: no-referrer
Cache-Control: no-store
```

Successful replies also send `Content-Length` and `Keep-Alive: timeout=5,
max=100`.

## Request types

14 values plus the fallthrough.

| `request` | Method | Parameters | Returns |
| --- | --- | --- | --- |
| *(anything unmatched, by convention `json`)* | GET | -- | The server state, below |
| `runcommand` | GET or POST | `cmd` | What the command printed (CONSTRAINTS item 1) |
| `getbans` | GET | -- | The bans in force, from whichever table decides them ([CONSTRAINTS.md](CONSTRAINTS.md#shine)) |
| `getrecentplayers` | GET | -- | Everyone seen in the last 24 hours, up to 100 (REQUIREMENTS item 6) |
| `getreservedslots` | GET | -- | `{ amount, ids: [...] }`, and Shine's count under its plugin |
| `getchatlist` | GET | `since` | `{ entries, last_id, dropped, buffer_size }` from a ring of 200, with times (item 3) |
| `getperf` | GET | `since`, `esince` | `perfmon`'s data in 10 s windows, and the engine's own reports ([below](#getperf)) |
| `getlog` | GET | `since`, `before`, `file` | `log-Server.txt` by byte offset ([below](#getlog)) |
| `getinstalledmodslist` | GET | -- | `[{ id, name, active, whitelisted }]` (REQUIREMENTS item 3, CONSTRAINTS item 17) |
| `getmaplist` | GET | -- | `[{ name, modId }]` |
| `getmapcycle` | GET | -- | `MapCycle.json`, mod ids hex-encoded (items 12, 13) |
| `setmapcycle` | GET or POST | `data` = JSON string | `{ ok, cycle }` read back, or `{ ok: false, error }` |
| `getmapvote` | GET | -- | What Shine's mapvote will do with the cycle (item 13) |
| `installmod` | GET or POST | `modid` (hex) | `{ ok, id, already_installed }` or `{ ok: false, error }` (item 2) |
| `getmods` | GET | `searchtext` | Workshop search results, or `{ loading, elapsed }` (item 2) |

- **Method is not enforced.** The handler reads parameters however they
  arrived, so every write also works as a `GET`. Methods other than `GET`
  and `POST` are refused `405` before Lua.
- **A `POST` reads the body only** (09-26). Its query string never reaches
  Lua, so a `POST` carries `request` and every parameter in the form body.
- **Lua sees the request** (measured 2026-10-12): the hook's second
  argument is `{path, method, headers}`, header names in lower case, never
  `authorization` or `cookie`. Lua cannot set a status or a header.

Reserved slots are set with `sv_reserved_slots`, `sv_add_reserved_slot`
and `sv_remove_reserved_slot` through `runcommand`, which say what they
did. What a command line can carry is in
[CONSTRAINTS.md](CONSTRAINTS.md#console-arguments).

## Server state

The default response, built by `GetServerState()`:

```
server_name, map, uptime    -- uptime restarts with each map
cheats, devmode
players_online, marines, aliens
marine_res, alien_res
frame_rate
game_started, game_time
max_players, map_loaded_at, ranking_active
shine                       -- only when Shine is loaded
player_list[]:
    name, steamid, isbot
    team, iscomm
    score, kills, assists, deaths
    resources, ping
    ipaddress               -- full client IP, see Privacy
    familyshared, owner_steamid, moves_rejected_time, moves_rejected_other
    skill, skill_offset, comm_skill, comm_skill_offset, skill_tier
    gagged                  -- under Shine's basecommands
```

Skill is absent when the server holds none; meanings are in openapi.yaml's
`Player` schema.

## Console commands

`runcommand` runs a command with `Shared.CaptureConsoleCommand` and
returns `{ cmd, dispatched, lines }`. `dispatched` is true when the game's
audit line for an admin command appeared; false for a plain console
command or no such command, which the server cannot tell apart. An empty
`lines` with `dispatched` is the ordinary case: a kick that works prints
nothing, only its failure branch does (`ServerAdminCommands.lua:172`).

## Mod ids are hex strings

JSON has no 64-bit integers, so `getmapcycle` writes mod ids with
`string.format("%x", id)` (`ModsIdsToHex`) and reads them back with
`tonumber64("0x"..mod)` (`ModIdsFromHex`); `getmods` does the same. A
client keeps them as strings. `ModIdsFromHex` skips any string containing
`:`, so a cycle entry can name a non-workshop source. On disk the cycle
stores plain numbers. `tonumber64` gives a plain number for
workshop-sized ids, `nil` for junk, and a `ULL` cdata above 2^53.
Example: `1e62a2ce` is workshop item `509780686`.

## `getmods` is asynchronous

The handler cannot block, so it answers `{ loading, elapsed }` at once and
starts `Server.SearchWorshop` (UWE's spelling); the client polls until it
gets something else. A settled result is cached for 60 s by its text; a
search with no answer after 30 s is reported once with `error`. Measured on
09-26 (REQUIREMENTS item 4): at most 50 hits, the page ignored (so only
page 1 is asked for), and a search Steam failed looks the same as an empty
one. `capped` says there may be more than 50.

## Installing a mod is not loading it

- `installmod` hands a hex id to the engine, which downloads the item. The
  mod appears in `getinstalledmodslist` once downloaded and unpacked,
  under its real title, and stays on disk. There is no uninstall
  (REQUIREMENTS item 2).
- **Loading** needs the id in the cycle's `mods` and a map change.
  `mods: ["1e62a2ce"]` then `sv_changemap` logged `Mounting mod 'Combat
  Fix'[509780686]`; removing it and changing map dropped it.
- The cycle is not all that is mounted: the engine also mounts UWE Hotfix
  344 and NSL Badges, and a map entry's own `mods` load only with that map
  (REQUIREMENTS item 3).
- **A mod that is not whitelisted unranks the server** (`Ranking disabled:
  server has non-whitelisted mods mounted`). `getinstalledmodslist` and
  `getmods` mark each mod `whitelisted`, from `Server.GetIsModWhitelisted`,
  the list the engine read at boot; the hotfix mods read true
  (CONSTRAINTS item 17).

## Authentication

HTTP Digest, MD5, handled by the engine (`ComputePasswordDigest` in
`server_linux`), not by Lua. The realm is `-webdomain`, or `localhost`
when unset. The browser handles it; the panel does nothing.

Measured on 09-03, unchanged on 09-26 (`tools/nonce-under-load.py`):

- A nonce is reusable while it lives, as long as the client increments
  `nc` (RFC 7616). "Single-use" in the changelog means each `(nonce, nc)`
  pair is accepted once.
- A replayed `nc` is refused `401` with `stale="true"`.
- A nonce expires on age, at about 300 s, not on idleness. Polled every
  2 s, one nonce served 150 requests and was refused at 301 s, with
  `stale="true"` and a fresh nonce that the next request used with `200`.

In headless Chrome (`tools/browser-checks/fetch-reauth.py`), a `fetch()`
loop at 2 s for 480 s, across a nonce expiry, made 240 requests, all `200`,
with no prompt; DevTools showed no `401`, because the browser retries
internally. A polling panel needs no re-authentication logic.

## `getperf`


| Field | What it is |
| --- | --- |
| `window_s`, `capacity` | 10 s windows, 360 kept (an hour) |
| `loaded_at`, `map` | When this Lua VM loaded. A new value means a map change, and ids restart at 1 |
| `config` | `tickrate`, `moverate`, `sendrate`, `interp_ms`, `max_players`, `bw_limit` (`Server.GetBwLimit()`, bytes a second per player, 09-27+) as the server runs now. Absent before the engine's first sample |
| `windows[]` | Per window: `tickrate` counted from ticks, `worst_tick_ms`, `score`, `idle_pct`, `moves_pct`, `entities_pct`, `entities`, `interp_warns`, `interp_fails` (counts per window), `lua_kb` |
| `last_id` | Poll again with `since=<last_id>` |
| `more` | The reply is one page of at most 60 windows and more are held: ask again at once |
| `engine` | The engine's log lines, below. Poll with `esince=<engine.last_id>`; `engine.more` pages it the same way, 60 records across its three lists |

Pages keep any one reply's encoding cost near 1.4 ms
([SERVER-COST.md](SERVER-COST.md)). A client that ignores `more` still
gets everything, 60 a poll.

The windows come from `Shared.GetServerPerformanceData()`, accumulated as
`perfmon` accumulates. Two values differ from a `perfmon` `Perf` line: the
tickrate is counted, because the engine's interval is whole milliseconds
and reads 62.5 at tickrate 60; and interp warns and fails are counts per
window, where `perfmon` prints a per-second rate with `%d`, so its `iFail
0` means under one a second. `score` is 0, and meaningless, with nobody
on. Measurements: REQUIREMENTS item 10.

`engine` holds the engine's own reports. Tickstat windows come from
`Server.GetTickStat()`, read every second while `tickstat N` is on, each
`time` the moment its window closed. The rest are lines the engine writes
only to `log-Server.txt`, found by scanning the log every `scan_s` (2)
seconds; they carry no timestamp, so each record's `time` is the scan that
found it, and a map load starts scanning from the end of the file. One id
sequence covers the three lists:

| Field | What it is |
| --- | --- |
| `tickstats[]` | One tickstat window each (`tickstat N` must be on): `Server.GetTickStat()` as the engine gives it (`window`, `hz`/`target`, tick spacing `intervalP50`..`intervalMax`, `busyPct`, `snapBytesP99`, `chokedPct`, `rateStepped`, ...), with `time` on the system clock |
| `perfmon[]` | The `perfmon:` block, printed only when `perfmon` is typed and covering the last second |
| `events[]` | `kind: "rate"`, a player's snapshot rate stepped (`client` is a slot number); `kind: "bwlimit_low"`, the engine's warning that `bwlimit` is too low, with the value it `suggested` |
| `tickstat_said` | The last `tickstat: on` or `off` printed |
| `tickstat_last_at` | When the newest tickstat window closed |

Lines are matched anchored at both ends, so a chat line cannot pass for an
engine line.

## `getlog`

`log-Server.txt` by byte offset, through `Shared.ReadLog`, wherever
`-logdir` puts it (CONSTRAINTS item 15). It holds what never passes through
Lua (connects and auth, engine errors, `Script tracing`, the boot, Shine's
chat and command lines), and it survives a map change.

| Ask | Get |
| --- | --- |
| `request=getlog` | The last 64 KB, from the first line that starts in it |
| `&since=<to>&file=<file_id>` | What was written since, at most 64 KB; `more: true` means ask again at once |
| `&before=<off>&file=<file_id>` | The 64 KB before a line, for paging back; `at_start` at byte 0 |

Each line is `{off, text}`: its byte offset, unique within a file, and its
text verbatim with CR dropped. Only whole lines are served; an unfinished
one waits for the next read. An idle poll returns nothing. Invalid UTF-8
passes through raw (a browser shows U+FFFD); control characters are
escaped. Offsets count bytes.

`file_id` is the header's Date and Time (`09/28/2026 03:27:00 AM`). A
restart renames the file to `log-Server.old.txt` and starts another, so a
`file` that no longer matches, or a cursor past the end, gets a fresh tail
with `reset: "new_file"` or `"truncated"`.

## Privacy

`player_list` carries each player's full IP address and SteamID over plain
HTTP. The panel masks both by default and reveals them per row. Live
captures are never committed (`fixtures/live/` is gitignored).

`getrecentplayers` serves the same two values for everyone seen in the
last 24 hours, connected or not, with former names, and writes them to
`config://webadmin/recent-players-{a,b}.json`, where they stay
until they age out; Lua cannot delete the files. The Recent players tab
shows IPs unmasked by design
([DESIGN.md](DESIGN.md#what-the-panel-deliberately-does-not-do));
Steam ids stay masked.

`getlog` serves the log verbatim, and the Console shows it unmasked, also
by design. On a populated server that is chat, names, every Steam id form
(`steam user 7656...`, `name[123] ran command`, `Client Authed. Steam ID:
n`, `STEAM_0:x:y` in dispatch lines) and IP:port on every connect and
disconnect. `redact-fixtures.py` rewrites all of them in committed
fixtures.

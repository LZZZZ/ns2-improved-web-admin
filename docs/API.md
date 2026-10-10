# Web admin HTTP API

The API as implemented by the game's `ns2/lua/ServerWebInterface.lua`
(304 lines, UWE 2012, unchanged in build 344), the only handler, plus what
the mod adds. Line references are to that file. Every request type has a
captured response in `fixtures/`, verified against a running server from
09-03 on ([TESTING.md](TESTING.md)).

This file is the prose. [openapi.yaml](openapi.yaml) is the contract: every
request type, parameter, response schema and refusal, with the mod's
additions under the `mod` tag, checked against the fixtures by
`tools/check-openapi.py`.

## What the mod adds

On a stock server these request types are unknown and fall through to the
state blob, so a client detects the mod by `mod_version` in the state
blob, never by a status code.

| Request type | What it returns | Details |
| --- | --- | --- |
| `runcommand` | What the command it ran printed | CONSTRAINTS item 1 |
| `getconsole` | The same capture as a stream, `since` a cursor | CONSTRAINTS item 1 |
| `getbans` | The bans in force, from whichever table decides them (Shine's under its ban plugin) | [CONSTRAINTS.md](CONSTRAINTS.md#shine) |
| `getrecentplayers` | Everyone seen in the last 24 hours, up to 100 | REQUIREMENTS item 6 |
| `getmapvote` | What Shine's mapvote will do with the cycle | CONSTRAINTS item 13 |
| `getperf` | `perfmon`'s data in 10 s windows, and the engine's log lines | [below](#getperf) |
| `getlog` | The server's `log-Server.txt` by byte offset | [below](#getlog) |
| `getwhitelist` | The ranked-mod whitelist, read from Steam | CONSTRAINTS item 17 |

Changed stock request types: `getchatlist` takes `since` (item 3),
`getmods` reports completion (item 2), `installmod` answers (item 2),
`getmapcycle` reads the file and `setmapcycle` validates and answers
(items 12, 13), `getinstalledmodslist` marks each mod `active` when
mounted now (REQUIREMENTS item 3), and a request with no parameters gets
a page leading to the panel (item 6).

State blob additions: `mod_version`, `max_players`, `map_loaded_at`,
`ranking_active`, `shine` when Shine is loaded, and real booleans
(item 4). Player rows gain Hive `skill` with its offsets and `skill_tier`
(item 16), `gagged` under Shine's basecommands, and on the 09-26+ engine
Family Sharing (`familyshared`, `owner_steamid`) and rejected-move
counts. Each is absent when the server cannot supply it; meanings are in
openapi.yaml's `Player` schema.

## Shape

```lua
Shared.SetWebRoot("web")            -- line 25, the static root
Event.Hook("WebRequest", OnWebRequest)
```

Every call is `GET` or `POST` to `/`, with the action in the `request`
parameter. A handled request returns `200` with a JSON body; an
unrecognised `request` falls through to the server-state blob.
`OnWebRequest` returns `("application/json", <body>)`, or `""` for the
writes, which the engine sends as an empty `200`.

### No 404, and no directory index

Any path that is not a file under the web root falls through to the
handler, which never sees the path. So `/does-not-exist.html` returns
`200 application/json` with the full state blob, names, SteamIDs and IPs
included, and so does `/`:

| Path | Status | Content-Type | Size |
| --- | --- | --- | --- |
| `/` | 200 | `application/json` | 317 B |
| `/index.html` | 200 | `text/html` | 12757 B |
| `/index.htm` | 200 | `application/json` | 317 B |
| `/js/rcon.js` | 200 | `application/x-javascript` | 12917 B |

- Never use the status code to detect a missing asset: a wrong path gives
  a JSON body and a parse error, not a 404.
- The panel is at `/index.html` (`Dedicated_Server_Usage.txt:118`), but the
  boot log prints `Web server running at <host>:<port>` with no path, so
  the obvious URL returns player data.

With the mod, a request with no parameters gets a page whose meta refresh
leads to `/index.html` (CONSTRAINTS item 6):

| Request | With the mod |
| --- | --- |
| `/`, `/missing.png`, `/index.htm`, `/?`, `/?foo`, `POST /` with an empty body | `text/html`, the page |
| `/?request=json`, `/?foo=1`, `/?foo=`, `/?request=` | `application/json`, the state |

A key without `=` never reaches Lua; one with `=` does, even empty.

### Response headers

From 09-03 on, every reply carries:

```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: frame-ancestors 'none'
Referrer-Policy: no-referrer
Cache-Control: no-store
```

Successful replies also send `Content-Length` and `Keep-Alive: timeout=5,
max=100`. Builds before 09-03 send only `Content-Type` and `Connection:
close`.

## Request types

11 values plus the fallthrough.

| `request` | Method | Parameters | Returns |
| --- | --- | --- | --- |
| *(anything unmatched, by convention `json`)* | GET | `command`, `rcon` (optional) | The server state, below |
| `getbanlist` | GET | -- | Array of ban records |
| `getreservedslots` | GET | -- | `{ amount, ids: [...] }` |
| `setreservedslotamount` | GET or POST | `amount` | `""`, and does nothing on stock (CONSTRAINTS item 7) |
| `getchatlist` | GET | `since` (mod) | The last 20 chat entries, each with an increasing `id`; `{ }` when the buffer does not exist. With the mod and `since`: `{ entries, last_id, dropped, buffer_size }` from a ring of 200, with times |
| `getperfdata` | GET | -- | Up to 30 samples, one a minute: `{ players, tickrate, time, ent_count }`, reset at a map change |
| `getinstalledmodslist` | GET | -- | `[{ id, name }]`; the mod adds `active` |
| `getmaplist` | GET | -- | `[{ name, modId }]` |
| `getmapcycle` | GET | -- | The map cycle, mod ids hex-encoded |
| `setmapcycle` | GET or POST | `data` = JSON string | `""`; the mod answers `{ ok, cycle }` or `{ ok: false, error }` |
| `installmod` | GET or POST | `modid` (hex) | `""`; the mod answers `{ ok, id, already_installed }` or `{ ok: false, error }` |
| `getmods` | GET | `searchtext`, `p` (page) | Workshop search results, or `{"loading": true}` |

- **Method is not enforced.** The handler reads parameters however they
  arrived, so every write also works as a `GET`; the 2012 panel sends
  `installmod` as one (`modbrowser.js:25`). Methods other than `GET` and
  `POST` are refused `405` before Lua.
- **A `POST` reads the body only** (09-26). Its query string never reaches
  Lua: `POST /?request=getbanlist` with an empty body falls through to the
  state blob. So a `POST` carries `request` and every parameter in the
  form body, as jQuery already does for the 2012 panel.
- **Lua sees parameters and nothing else** (09-26): the hook gets one
  table, with no headers, path or method.

The panel sets reserved slots through `sv_reserved_slots`,
`sv_add_reserved_slot` and `sv_remove_reserved_slot` on every server:
they work on stock and say what they did. What a command line can carry
is in [CONSTRAINTS.md](CONSTRAINTS.md#console-arguments).

## Server state

The default response, built by `GetServerState()` (lines 78-135):

```
webdomain, webport          -- substituted by the engine from [[webdomain]] / [[webport]]
server_name, map, uptime    -- uptime restarts with each map
cheats, devmode             -- strings on stock, booleans with the mod
players_online, marines, aliens
marine_res, alien_res
frame_rate
game_started, game_time
player_list[]:
    name, steamid, isbot    -- isbot a string on stock
    team, iscomm
    score, kills, assists, deaths
    resources, ping
    ipaddress               -- full client IP, see Privacy
```

A client that talks to both kinds of server reads `true` and `"true"`
alike, as the panel's `wireBool` does.

## Console commands

Lines 278-280:

```lua
if actions.command then
    Shared.ConsoleCommand(actions.rcon)
end
```

- **Both parameters are required.** `command` is only tested for truth
  (the 2012 panel sends `command=Send`); the text is read from `rcon`.
- **Nothing is returned**: the response is the ordinary state blob, with
  no output, success flag or error.

A failed and a successful kick, sent the way the 2012 panel sends them:

| Command | HTTP | Body | What happened |
| --- | --- | --- | --- |
| `sv_kick <bot name>` | 200 | server state | failed: `No matching player` |
| `sv_kick <real steamid>` | 200 | server state | worked |

The two bodies differ only in fields that drift between any two samples,
and the successful kick still reported `players_online: 12`, because the
response is rendered before the disconnect completes. So a client cannot
infer the outcome even by diffing `player_list`; the 2012 panel
(`rcon.js:290`) ignores the response and refreshes 500 ms later. The
reason exists on the server: `ServerAdminCommands.lua:172` calls
`ServerAdminPrint(client, "No matching player")`, which for a web request
reaches only `log-Server.txt`. Fixtures: `rcon-kick.json`,
`rcon-kick-success.json`. The mod's fix is CONSTRAINTS item 1.

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

Lines 217-274. The handler cannot block, so it:

1. answers `{"loading": true}` at once and starts `Server.SearchWorshop`
   (UWE's spelling);
2. caches the result for 60 s, keyed by `searchtext..page`;
3. restarts a search still running after 30 s.

The client polls until it gets something else. Measured on 09-26
(REQUIREMENTS item 4): at most 50 hits, the page ignored, an empty result
is `{"items":[]}`, and a search Steam failed looks the same as an empty
one. Without `searchtext` stock never starts a search; a non-numeric `p`
is a Lua error and an empty `200`. The mod's additions are CONSTRAINTS
item 2.

## Installing a mod is not loading it

- `installmod` downloads the item, returns nothing from the engine, and
  drops a malformed id silently. The mod appears in
  `getinstalledmodslist` once downloaded and unpacked, under its real
  title, and stays on disk. There is no uninstall (REQUIREMENTS item 2).
- **Loading** needs the id in the cycle's `mods` and a map change.
  `mods: ["1e62a2ce"]` then `sv_changemap` logged `Mounting mod 'Combat
  Fix'[509780686]`; removing it and changing map dropped it.
- The cycle is not all that is mounted: the engine also mounts UWE Hotfix
  344 and NSL Badges, and a map entry's own `mods` load only with that map
  (REQUIREMENTS item 3).
- **A mod that is not whitelisted unranks the server** (`Ranking disabled:
  server has non-whitelisted mods mounted`), and nothing in the stock API
  says so. The mod's `getwhitelist` lets the panel mark each mod, installed
  or found on the Workshop tab; the hotfix mods count as whitelisted
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

Stock `getperfdata` returns the same one-a-minute window however often it
is polled. The mod leaves it alone and adds `getperf`:

| Field | What it is |
| --- | --- |
| `window_s`, `capacity` | 10 s windows, 360 kept (an hour) |
| `loaded_at`, `map` | When this Lua VM loaded. A new value means a map change, and ids restart at 1 |
| `config` | `tickrate`, `moverate`, `sendrate`, `interp_ms`, `max_players`, `bw_limit` (`Server.GetBwLimit()`, bytes a second per player, 09-27+) as the server runs now. Absent before the engine's first sample |
| `windows[]` | Per window: `tickrate` counted from ticks, `worst_tick_ms`, `score`, `quality`, `idle_pct`, `moves_pct`, `entities_pct`, `moves_per_s`, `move_ms`, `entities`, `incomplete`, `interp_warns`, `interp_fails` (counts per window), `lua_kb` |
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
0` means under one a second. `score` and `quality` are 0, and meaningless,
with nobody on. Measurements: REQUIREMENTS item 10.

`engine` holds lines the engine writes only to `log-Server.txt`, found by
scanning the log every `scan_s` (2) seconds. The lines carry no timestamp,
so each record's `time` is the scan that found it; a map load starts
scanning from the end of the file. One id sequence covers the three
lists:

| Field | What it is |
| --- | --- |
| `source` | `log`, or `none` with `error` (and `stale`, as for `getlog`) |
| `tickstats[]` | One `TICKSTAT` line each (`tickstat N` must be on): `win_s`, `hz`/`target`, tick spacing `int_p50_ms`..`int_max_ms`, `stretch_pct`, `busy_pct`, `humans`, `bots`, `snaps_per_s_human`, `moves_per_s_human`, `snap_p50_bytes`/`snap_p99_bytes`/`snap_max_bytes`, `choked_pct`, `rate_stepped`, `creations_deferred`, move costs, the rest of the line; `unparsed` counts unknown segments |
| `perfmon[]` | The `perfmon:` block, printed only when `perfmon` is typed and covering the last second |
| `events[]` | `kind: "rate"`, a player's snapshot rate stepped (`client` is a slot number); `kind: "bwlimit_low"`, the engine's warning that `bwlimit` is too low, with the value it `suggested` |
| `tickstat_said` | The last `tickstat: on` or `off` printed |
| `tickstat_last_at` | When the newest `TICKSTAT` line was found |

Lines are matched anchored at both ends, so a chat line cannot pass for an
engine line.

## `getlog`

`log-Server.txt` by byte offset. It holds what never passes through Lua,
so never reaches `getconsole` (connects and auth, engine errors, `Script
tracing`, the boot, Shine's chat and command lines), and it survives a map
change. It needs the log in the config directory (CONSTRAINTS item 15).

| Ask | Get |
| --- | --- |
| `request=getlog` | The last 64 KB (`tail_bytes`), from the first line that starts in it |
| `&since=<to>&file=<file_id>` | What was written since, at most 64 KB (`max_bytes`); `more: true` means ask again at once |
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

When the file cannot be read the reply is `{"source": "none", "path",
"error"}`: `config://log-Server.txt: No such file or directory` when the
log is elsewhere, or `stale: true` for a copy the server is not writing.

## Privacy

`player_list` carries each player's full IP address and SteamID over plain
HTTP. The panel masks both by default and reveals them per row. Live
captures are never committed (`fixtures/live/` is gitignored).

`getrecentplayers` serves the same two values for everyone seen in the
last 24 hours, connected or not, with former names, and writes them to
`config://improved-webadmin/recent-players-{a,b}.json`, where they stay
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

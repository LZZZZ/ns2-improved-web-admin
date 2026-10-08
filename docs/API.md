# Web admin HTTP API

Read from the game's `ns2/lua/ServerWebInterface.lua` (304 lines, UWE
2012, still current in build 344 / 2026-09-03). This is the
complete server-side surface -- there is no second handler.

Nothing here was guessed or crawled. Line references are to that file.

A machine-readable version of everything below is in
[openapi.yaml](openapi.yaml), whose schemas are checked against the
committed fixtures by `tools/check-openapi.py`. This file is the prose;
that file is the contract.

**This documents the stock server.** The mod adds eight request types
of its own -- `runcommand` and `getconsole`, which return what a command
printed, `getbans`, the bans in force from whichever table decides
them (Shine's, under its ban plugin), `getrecentplayers`, everyone
seen in the last 24 hours, `getmapvote`, what Shine's mapvote will
do with the cycle, `getperf`, what `perfmon` logs in 10 s windows
([below](#performance-data-with-the-mod-measured-2026-09-27)), and
`getlog`, the server's own log
([below](#the-server-log-with-the-mod-measured-2026-09-28)), and
`getwhitelist`, the ranked-mod whitelist read from Steam
([below](#installing-a-mod-is-not-loading-a-mod-verified)) -- plus `mod_version`,
`max_players`, `map_loaded_at`, `ranking_active` (the engine's verdict on
whether the server is ranked, 2026-10-08), each player's Hive `skill` with its
offsets (2026-10-07) and `skill_tier` (2026-10-08) and, when Shine is loaded, `shine` in the state blob. It
fixes five bugs, and changes three stock request types: `getmapcycle`
reads the file instead of memory, `setmapcycle` checks the cycle
first and answers with the file read back, and `getinstalledmodslist`
marks each mod `active` when it is mounted now. They are specified in [openapi.yaml](openapi.yaml)
under the `mod` tag and described in [CONSTRAINTS.md](CONSTRAINTS.md). On
a stock server those values are unrecognised and fall through to the
server-state blob like any other unknown `request`, so a client must
detect the mod by `mod_version` and never by a status code.

**Verified against a running server on 2026-09-05** (build 344 /
26-09-03, local test rig -- see [TESTING.md](TESTING.md)). Every request
type below has a captured response in `fixtures/`. Corrections found
during that pass are marked *verified* or *corrected*.

## Shape

The Lua side registers one hook:

```lua
Shared.SetWebRoot("web")            -- line 25, sets the static root
Event.Hook("WebRequest", OnWebRequest)
```

Every call is `GET` or `POST` to **`/`**. The action is chosen by the
`request` query parameter. There are no paths, no REST verbs and no
status-code vocabulary: a handled request returns `200` with a JSON
body, and an unrecognised `request` value silently falls through to the
default server-state response.

`OnWebRequest` returns `("application/json", <body>)`, or `""` for the
write operations, which the engine sends as an empty `200`.

### There is no 404 *(verified)*

Any path that is not a file under the web root also falls through to the
default handler. `/does-not-exist.html`, `/img/nope.png` and
`/js/jquery.jqplot.min.js` all return **`200 application/json`** with the
full server-state blob -- player names, SteamIDs and IP addresses
included.

Two consequences for the replacement panel:

- **Never use the status code to detect a missing asset.** A typo in a
  script or stylesheet path yields a 200 whose body is JSON, so the
  browser reports a parse error rather than a missing file.
- A build that references any file it does not ship will fail in a way
  that looks nothing like a 404. Vendored, hashed asset names matter more
  here than they would on an ordinary server.

### There is no directory index either *(verified)*

`/` is not the panel. The handler receives `OnWebRequest(actions)` --
query parameters only, never the path -- so a bare `/` cannot be told
apart from any other unmatched request and falls through to the default:

| Path | Status | Content-Type | Size |
| --- | --- | --- | --- |
| `/` | 200 | `application/json` | 317 B |
| `/index.html` | 200 | `text/html` | 12757 B |
| `/index.htm` | 200 | `application/json` | 317 B |
| `/js/rcon.js` | 200 | `application/x-javascript` | 12917 B |

The panel is at **`/index.html`**, which is what
`Dedicated_Server_Usage.txt:118` documents. But the server's own boot
line is `Web server running at <host>:<port>` with no path, so the
obvious thing to type returns the server-state blob -- names, SteamIDs
and IP addresses -- to anyone who can authenticate. Choosing by the
`Accept` header would be the right fix, but **headers do not reach Lua**
(measured on 09-26, see [Method is not enforced](#request-types)).

**With the mod** *(2026-10-06)* a request with no parameters at all gets
a small page instead, whose meta refresh leads to `/index.html`
(`fixtures/root-mod.html`). Measured on the rig:

| Request | With the mod |
| --- | --- |
| `/`, `/missing.png`, `/index.htm`, `/?`, `/?foo` | `text/html`, the page |
| `POST /` with an empty body | the page |
| `/?request=json`, `/?foo=1`, `/?foo=`, `/?request=` | `application/json`, the state |

A key with no `=` never reaches Lua; one with `=` does, even empty. A
script that reads state from a bare `/` has to send `request=json`. See
[CONSTRAINTS.md](CONSTRAINTS.md) item 6.

### Response headers *(verified)*

On the 26-09-03 build every reply carries:

```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: frame-ancestors 'none'
Referrer-Policy: no-referrer
Cache-Control: no-store
```

Successful replies also send `Content-Length` and
`Keep-Alive: timeout=5, max=100`. The stock (pre-09-03) build sends none
of these -- only `Content-Type` and `Connection: close`.

## Request types

11 explicit values plus the default fallthrough.

| `request` | Method | Parameters | Returns |
| --- | --- | --- | --- |
| *(anything unmatched, by convention `json`)* | GET | `command`, `rcon` (optional) | Full server state, see below |
| `getbanlist` | GET | -- | Array of ban records |
| `getreservedslots` | GET | -- | `{ amount, ids: [...] }` |
| `setreservedslotamount` | GET or POST | `amount` | `""` -- **but does nothing, see below** |
| `getchatlist` | GET | `since` (mod only) | Array of chat entries, each with an increasing `id`; `{ }` when the buffer does not exist. With the mod and `since`: `{ entries, last_id, dropped, buffer_size }` from a ring of 200, with times |
| `getperfdata` | GET | -- | Up to 30 samples: `{ players, tickrate, time, ent_count }` |
| `getinstalledmodslist` | GET | -- | `[{ id, name }]` |
| `getmaplist` | GET | -- | `[{ name, modId }]` |
| `getmapcycle` | GET | -- | Map cycle, mod ids **hex-encoded** |
| `setmapcycle` | GET or POST | `data` = JSON string | `""` |
| `installmod` | GET or POST | `modid` (hex) | `""`; the mod answers `{ ok, id, already_installed }` or `{ ok: false, error }` |
| `getmods` | GET | `searchtext`, `p` (page) | Workshop search results, or `{"loading": true}` |

**Method is not enforced** *(corrected)*. The handler reads `actions`
without caring how they arrived, so every write also works as a `GET`
with query parameters. The shipped panel relies on this: `modbrowser.js:25`
sends `installmod` through `$.ajax` with no `type`, i.e. as a `GET`.
Only `GET` and `POST` reach the handler at all -- `PUT` and `DELETE` are
refused with `405` by the 26-09-03 web server before Lua sees them
(09-26 also refuses `HEAD` and `OPTIONS` with `405`).

**A `POST` reads the body only** *(measured on 09-26, 2026-09-27)*. The
query string of a `POST` never reaches Lua: `POST /?request=getbanlist`
with an empty body, or with an unrelated form field, falls through to
the state blob, and a probe `POST /?q2=x` with body `f1=y` saw only
`f1`. So a `POST` must carry `request` and every parameter in the
form body. The 2012 panel already does -- jQuery puts `data` in the body
on a `POST` -- so it is unaffected. Whether 09-03 merged the two was
never measured; the spec and mock had assumed it.

**Lua sees parameters and nothing else** *(measured on 09-26)*. The
`WebRequest` hook is called with exactly one argument, a table of the
query parameters (`GET`) or form fields (`POST`). No headers -- a
request carrying `Accept`, `Cookie` and a made-up `X-Probe` showed none
of them -- no path and no method. Probe:
`tools/spikes/engine0926-branch.lua`.

### `setreservedslotamount` has never worked *(new defect)*

`ServerWebInterface.lua:209` calls

```lua
SetReservedSlotAmount(actions.amount)
```

but the function is declared `SetReservedSlotAmount(client, amount)`
(`ServerAdminCommands.lua:614`). The amount arrives as `client`, `amount`
is `nil`, `tonumber(nil)` is `nil`, and the guard on line 618 rejects the
call. The request returns `200` with an empty body and changes nothing.

Verified both ways on a live server: the API call leaves `amount` at `0`
and logs nothing, while `sv_reserved_slots 3` through the console path
sets it to `3` and logs `Reserved slot amount set to 3`.

Fix is one line -- `SetReservedSlotAmount(nil, actions.amount)`, and the
mod carries it. The panel drives reserved slots through
`sv_reserved_slots` and `sv_add_reserved_slot` / `sv_remove_reserved_slot`
anyway, on every server: the commands work on a stock server too, and
they say what they did. What the console path can and cannot carry
(no quotes, no spaces in a slot name, `;` not a separator) is in
[CONSTRAINTS.md](CONSTRAINTS.md#what-console-arguments-can-carry-measured-2026-09-27).

## Server state (the default response)

Built by `GetServerState()`, lines 78-135:

```
webdomain, webport          -- substituted by the engine from [[webdomain]] / [[webport]]
server_name, map, uptime
cheats, devmode             -- strings, not booleans
players_online, marines, aliens
marine_res, alien_res
frame_rate
game_started, game_time
player_list[]:
    name, steamid, isbot    -- isbot is a *string*, "true"/"false"
    team, iscomm
    score, kills, assists, deaths
    resources, ping
    ipaddress               -- full client IP, see Privacy below
```

Types are inconsistent -- `cheats`, `devmode` and `isbot` are stringified
booleans while `iscomm` and `game_started` are real ones. A new client
must not assume. The mod sends all five as real booleans
([CONSTRAINTS.md](CONSTRAINTS.md) item 4), so a client that talks to both
reads `true` and `"true"` alike, as the panel's `wireBool` does.

The mod also adds fields to each `player_list` row: Hive `skill` and its
offsets, `skill_tier`, `gagged` under Shine's basecommands, and on the
09-26+ engine Family Sharing (`familyshared`, `owner_steamid`) and
rejected-move counts. Each is absent when the server cannot supply it.
What each means, and what was measured, is in
[openapi.yaml](openapi.yaml)'s `Player` schema.

## Console commands

Lines 278-280:

```lua
if actions.command then
    Shared.ConsoleCommand(actions.rcon)
end
```

Two things follow, and both matter:

1. **Both parameters are required.** `command` is only tested for
   truthiness -- the shipped UI sends the literal `command=Send` -- while
   the command text is read from `rcon`. Sending `rcon` alone does nothing.
2. **Nothing is returned.** The command runs and the response is the
   ordinary server-state blob. There is no way to read command output,
   no success flag and no error. The existing "console" in the panel is
   the chat list; it has never shown command results.

This is the single largest gap for a modern panel. See
[CONSTRAINTS.md](CONSTRAINTS.md).

### Demonstrated, not argued *(verified)*

Two commands sent the way the panel sends them, against a live server:

| Command | HTTP | Body | What actually happened |
| --- | --- | --- | --- |
| `sv_kick <bot name>` | 200 | server state | **failed** -- `No matching player` |
| `sv_kick <real steamid>` | 200 | server state | worked -- player disconnected |

Same status, same `Content-Type`, same key set. The only fields that
differ between the two bodies are `uptime`, `frame_rate`, `game_time`,
`alien_res` and `player_list`, all of which drift between any two
samples anyway.

The detail that makes it unrecoverable: **the successful kick still
reported `players_online: 12`**. The response is rendered before the
disconnect completes, so a client cannot infer the outcome even by
diffing `player_list` against its previous poll. That is why
`rcon.js:290` fires the request, ignores the response and schedules a
refresh 500 ms later -- nothing else is available to it.

The reason exists on the server. `ServerAdminCommands.lua:172` calls
`ServerAdminPrint(client, "No matching player")`, which for a web request
reaches only `log-Server.txt`. Fixtures: `rcon-kick.json` (failed) and
`rcon-kick-success.json` (worked).

## Mod ids are hex strings

JSON has no 64-bit integers, so `getmapcycle` converts mod ids with
`string.format("%x", id)` on the way out (`ModsIdsToHex`) and
`tonumber64("0x"..mod)` on the way back in (`ModIdsFromHex`). `getmods`
does the same for workshop results. A client must round-trip them as
strings and never parse them as numbers.

`ModIdsFromHex` skips any string containing `:`, which is how a map
cycle entry can carry a non-workshop source.

Measured on 09-26 *(2026-09-27)*: a cycle written with hex mod ids is
stored with plain numbers on disk and read back as the same hex.
`tonumber64` gives a plain number for workshop-sized ids, `nil` for junk,
and an unsigned `ULL` cdata above 2^53.

## `getmods` is asynchronous

Lines 217-274. The Lua handler cannot block, so it:

1. returns `{"loading": true}` immediately and starts `Server.SearchWorshop`
   (spelling is UWE's),
2. caches the completed result for **60 seconds**, keyed by
   `searchtext..page`,
3. treats a search still running after **30 seconds** as timed out and
   restarts it.

A client polls the same URL until it gets something other than
`{"loading": true}`. There is no completion event and no error result --
a failed search is indistinguishable from a slow one, and an empty
result is `{"items":[]}` (measured; this said `{}` until then).

**Measured on 09-26** ([REQUIREMENTS.md](REQUIREMENTS.md) item 4): the
engine hands over **at most 50 hits and ignores the page** -- pages 1, 2,
3 and 500 were the same -- so there is no paging, only a narrower search.
A search Steam failed (the rig offline: `NoConnection`) comes back as an
empty result, so a failure also looks like no matches. Without
`searchtext` vanilla never starts a search; with a `p` that is not a
number it errors and answers an empty `200`.

**The mod** keeps `loading` and `items` and adds `elapsed` while
loading, then `done`, `page`, `count` and `capped` (50 hits: there may
be more). A search with no answer after 30 s is reported once with
`error`, and the next request starts afresh. A missing `searchtext` is
`""`, a bad `p` is 1, and the cache key separates text and page (vanilla
gave `a` page 11 and `a1` page 1 the same key). See
[openapi.yaml](openapi.yaml).

`installmod` returns nothing from the engine and drops a malformed id
without a word; the mod refuses one before the call. Either way a
download shows only in `getinstalledmodslist`, which lists a mod once it
is downloaded and unpacked, under its real title, and never before.

## Authentication *(verified)*

HTTP **Digest**, MD5, handled by the engine and not by Lua
(`ComputePasswordDigest` in `server_linux`). The realm is the
`-webdomain` value, or `localhost` when unset. A browser handles all of
this natively; the panel does nothing.

What the 26-09-03 hardening actually does, measured:

- A nonce is **reusable** for the life of the nonce as long as the client
  increments `nc`, which is ordinary RFC 7616 behaviour.
- Replaying an **already-used `nc`** is refused `401` with `stale="true"`.
- The nonce expires on **age, not idleness**. Polled every 2 s the way the
  panel polls, one nonce took **150 requests and was refused at 301 s**,
  `nc` having reached `00000097`. The refusal carries `stale="true"` and a
  fresh nonce, and the very next request signed with that nonce returns
  `200`.

`stale="true"` is the RFC 7616 signal for "your credentials were fine,
the nonce was old" -- a browser retries silently rather than prompting.
So "single-use" in the changelog means each `(nonce, nc)` pair is
accepted once, **not** one request per login. A one-second poll costs one
request per poll and one silent re-auth every five minutes.

Probe: `tools/nonce-under-load.py`.

**Unchanged on 09-26** *(2026-09-27)*, despite 09-25's "hardened web admin
request handling and login": one nonce accepted at every age up to
300 s, refused at 320 s with `stale="true"`.

### Through a browser *(verified 2026-09-05)*

The protocol measurement above says a long poll should survive nonce
expiry. Confirmed in headless Chrome
(`tools/browser-checks/fetch-reauth.py`): credentials answered once for
the navigation, the handler then torn down, and a `fetch()` loop left
running on Chrome's own credential cache.

| Over 480 s at a 2 s cadence | |
| --- | --- |
| `fetch()` calls made | 240 |
| resolved `200` with parseable JSON | 240 |
| resolved non-200 | none |
| rejected | none |
| credential prompts | none |

The run spans one nonce expiry and change. Chrome absorbs it: DevTools
reports no `401` at all, because the browser restarts the transaction
internally rather than surfacing the challenge. **A polling panel needs
no re-authentication logic of its own** -- no 401 handler, no credential
retry, no re-prompt. This retires the last open question on the login
challenge.

## The map cycle, with the mod *(measured 2026-09-27)*

On a stock server `getmapcycle` answers from the copy loaded with the
map, and `setmapcycle` answers an empty `200` whatever happens -- a
cycle without `maps` errors in Lua and writes nothing, a junk mod id is
logged and written anyway. The copy is also shallow, so reading the
cycle rewrites the live cycle's mod ids to hex. The mod reads
`MapCycle.json`, refuses a cycle the game cannot use, and returns the
file read back. Measured on the rig, with the details in
[CONSTRAINTS.md](CONSTRAINTS.md) items 12 and 13. Keys the game does not
use (Shine's per-map `min`, `max`, `chance`, top-level `groups`) survive
both.

A `POST` carries `request` and `data` in its form body; the panel posts
every write. A modded cycle of 40 maps and 22 global mods is 822 bytes
on disk.

## Performance data, with the mod *(measured 2026-09-27)*

`getperfdata` is one reading a minute: `Server.GetFrameRate()`, players
and entities, the last 30, reset at every map change. Polling it faster
returns the same window. The mod leaves it alone and adds `getperf`:

| Field | What it is |
| --- | --- |
| `window_s`, `capacity` | 10 s windows, 360 of them kept (an hour) |
| `loaded_at`, `map` | When this Lua VM loaded. A new value means a map change: the ids restarted at 1 |
| `config` | `tickrate`, `moverate`, `sendrate`, `interp_ms`, `max_players` as the server runs **now** -- a runtime `tickrate 60` shows at once. Absent before the engine's first sample |
| `windows[]` | Per window: `tickrate` counted from ticks, `worst_tick_ms`, `score`, `quality`, `idle_pct`, `moves_pct`, `entities_pct`, `moves_per_s`, `move_ms`, `entities`, `incomplete`, `interp_warns`, `interp_fails` (counts over the window), `lua_kb` |
| `last_id` | Poll again with `since=<last_id>` |
| `more` | The reply is one page of at most 60 windows: more are held past `last_id`, so ask again at once *(2026-10-08)* |
| `config.bw_limit` | `Server.GetBwLimit()`, bytes a second per player (09-27 engine and later) |
| `engine` | What the engine prints only to `log-Server.txt`, below. Poll with `esince=<engine.last_id>`; `engine.more` pages it the same way, 60 records across its three lists |

**Paged** *(2026-10-08)*. An hour of windows and `tickstat` lines in one
reply was 360 KB, and dkjson took 7.5-8.5 ms to write it: most of a tick
at 80, spent in the tick, each time a panel opened the Performance tab late
in a map. Each reply now holds at most 60 from each cursor, oldest first,
and `last_id` is the last one it holds; `more` is `true` until a cursor has
caught up. A page costs about 1.4 ms, and each is its own request, so its
own tick. A client that ignores `more` still gets everything, 60 a poll.
Measured in [SERVER-COST.md](SERVER-COST.md).

The window data is `Shared.GetServerPerformanceData()`, the object
`perfmon` prints, accumulated the way `perfmon` accumulates its 30 s. Two
things read differently from a `Perf` log line: the tickrate is counted,
because the engine's interval is whole milliseconds and reads 62.5 at
tickrate 60; and warns and fails are counts per window, where `perfmon`
prints them per second with `%d` -- so its `iFail 0` means under one a
second, and hid real fails on the rig. `score` and `quality` are 0 with nobody on the
server and mean nothing then. Measurements in
[REQUIREMENTS.md](REQUIREMENTS.md) item 10.

`engine` holds the engine's own lines, found by scanning the log every
`scan_s` (2) seconds. They carry no timestamp, so each record's `time` is
the scan that found it, and a map load starts from the end of the file.
One id sequence covers all three lists:

| Field | What it is |
| --- | --- |
| `source` | `log`, or `none` with `error` (and `stale` for a copy the server is not writing) |
| `tickstats[]` | One `TICKSTAT` line each (`tickstat N` must be on): `win_s`, `hz`/`target`, tick spacing `int_p50_ms`..`int_max_ms`, `stretch_pct`, `busy_pct`, `humans`, `bots`, per-human `snaps_per_s_human` and `moves_per_s_human`, `snap_p50_bytes`/`snap_p99_bytes`/`snap_max_bytes`, `choked_pct`, `rate_stepped`, `creations_deferred`, move costs, and the rest of the line; `unparsed` counts segments it did not know |
| `perfmon[]` | The `perfmon:` block, printed only when `perfmon` is typed, covering the last second: tick jitter, snapshot write, entities skipped, moves rejected and rewound, `score = idle - delivery - overload` |
| `events[]` | `kind: "rate"`: a player's update rate stepped (`client` is a slot number); `kind: "bwlimit_low"`: the engine's warning that `bwlimit` leaves too few bytes per snapshot, with the value it `suggested` |
| `tickstat_said` | The last `tickstat: on` or `off` the command printed; a bare `tickstat` prints it without toggling |
| `tickstat_last_at` | When the newest `TICKSTAT` line was found |

Lines are matched anchored at both ends, so one that only starts with a
player's name cannot pass for an engine line.

## The server log, with the mod *(measured 2026-09-28)*

`getlog` serves `log-Server.txt`, the engine's own log, by byte offset.
It holds what never passes through Lua and so never reaches `getconsole`:
connects and auth, engine errors, `Script tracing`, the boot, and Shine's
chat and command lines. It also outlives a map change, which the console
buffer does not.

| Ask | Get |
| --- | --- |
| `request=getlog` | The last 64 KB (`tail_bytes`), from the first line that starts in it |
| `&since=<to>&file=<file_id>` | What was written since, at most 64 KB (`max_bytes`; 256 KB before 2026-10-08, which cost a third of a tick at 80 to encode); `more: true` means ask again at once |
| `&before=<off>&file=<file_id>` | The 64 KB before a line, for paging back; `at_start` at byte 0 |

Each line is `{off, text}`: its byte offset, unique within a file, and
its text verbatim, CR dropped. Only whole lines are served; one the
engine has not finished waits for the next read (in 5404 reads under load
on the rig, none ever ended mid-line, but a force-stopped server's log
does). An idle poll reads nothing.

`file_id` is the header's Date and Time (`09/28/2026 03:27:00 AM`). A
restart moves the file to `log-Server.old.txt` and starts another; a
`file` that no longer matches, or a cursor past the end, gets a fresh
tail with `reset: "new_file"` or `"truncated"`. `clearconsole` does
**not** cut the server's log, despite the 09-03 changelog: on the server
it is a client command that does nothing (measured through the web admin
and the FIFO).

When the file cannot be read the reply is `{"source": "none", "path",
"error"}`: `config://log-Server.txt: No such file or directory` when the
engine writes its log elsewhere, or `stale: true` when a file is there
but is not the one being written (the check is in
[CONSTRAINTS.md](CONSTRAINTS.md) item 15).

The engine serves a 16 MB reply without complaint (measured: 64 KB to
16 MB, all `200`), so the cap is the mod's own. Reads cost about 0.2 ms
for 64 KB, 0.7 ms for 256 KB and 3 ms for 1 MB. Invalid UTF-8 in a line
passes through `json.encode` raw, so a browser shows U+FFFD; control
characters are escaped. Offsets count bytes, not characters.

## Map cycle size against the 64 KB cap *(verified)*

A stock 17-map cycle serialises to **263 bytes** -- 249x under the 64 KB
request-body cap. `setmapcycle` round-trips losslessly and writes
`config://MapCycle.json`. The cap is not a design constraint for
realistic cycles.

## Installing a mod is not loading a mod *(verified)*

The two are separate and the panel conflates them.

- `installmod` downloads the workshop item. It appears in
  `getinstalledmodslist` within seconds and stays on disk.
- **Loading** it requires it to be in the map cycle's `mods` array *and*
  a map change. Setting `mods: ["1e62a2ce"]` and running `sv_changemap`
  produced `Mounting mod 'Combat Fix'[509780686]`; removing it and
  changing map again dropped it.
- There is **no uninstall**. Nothing in the API removes a downloaded mod,
  so `getinstalledmodslist` only ever grows.
- **The cycle is not all that is mounted** *(measured on 09-26 with Shine
  and 23 mods, 2026-09-27)*. The engine also mounts UWE Hotfix 344 and
  NSL Badges, which no cycle names, and a map entry's own `mods` only
  while that map is loaded. The mod's `getinstalledmodslist` says which
  are mounted now (`active`); a stock one cannot. Details in
  [REQUIREMENTS.md](REQUIREMENTS.md) item 3.

Mod ids confirm the hex convention end to end: `1e62a2ce` in the API is
workshop item `509780686`.

**Loading a non-whitelisted mod silently unranks the server.** The log
says `Ranking disabled: server has non-whitelisted mods mounted` and
`Requesting server ranking be enabled, request success: false`; removing
the mod restores it. Nothing in the stock API surfaces this, and the 2012
mod browser's subscribe button gives no warning. `Server.GetIsRankingActive()`
exists, but with this mod mounted it can only ever answer `false`, so the
Mods tab states the rule rather than showing a ranked indicator.

**Which mods are whitelisted** *(2026-10-08)*: the list is the "Required
items" of the unlisted Workshop item 2909200101, which the engine reads at
boot and Lua cannot see. The mod's `getwhitelist` reads the item's public
page instead (no API key), at most once an hour, keeps a copy in
`config://webadmin-spa/`, and answers with decimal workshop ids, so the
panel marks each mod, installed or found on the Workshop tab, before it is
installed. The hotfix mods (NSL Badges, UWE Hotfix 344) are never checked
and count as whitelisted. Details, and what the engine logs, in
[CONSTRAINTS.md](CONSTRAINTS.md) item 17.

## Privacy

`player_list` includes each player's **full IP address** and SteamID,
served over plain HTTP. The replacement should mask both by default and
reveal them per-row on request. Captures of live responses must never be
committed; `fixtures/live/` is gitignored for this reason.

With the mod, `getrecentplayers` serves the same two values for everyone
seen in the last 24 hours (up to 100 players), connected or not, with
their former names. It also **writes them to disk**, in
`config://webadmin-spa/recent-players-{a,b}.json` under the server's
config directory, where they stay until they age out. Nothing can delete
those files from Lua. The Recent players tab shows IPs unmasked, by
design (see the README's
[What the panel deliberately does not do](../README.md#what-the-panel-deliberately-does-not-do));
Steam ids stay masked there.

`getlog` serves the server's log **verbatim**, and the Console tab shows
it unmasked, also by design: it is the server's own record. On a populated server that means chat, names, every
Steam id form (`steam user 7656...`, `name[123] ran command`, `Client
Authed. Steam ID: n`, `STEAM_0:x:y` in dispatch lines) and IP:port on
every connect and disconnect -- seen in a populated round's log.
`redact-fixtures.py` rewrites all of them in committed `getlog`
fixtures.

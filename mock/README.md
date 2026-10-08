# The mock server

A stand-in for an NS2 dedicated server's web admin, replaying the
[fixtures](../fixtures) captured from a real server. Zero dependencies,
one command:

```bash
node mock/server.js --web web
```

It serves the API on `127.0.0.1:8080`, and the static files under `--web`:
`web/` for the new panel, or a server install's `ns2/web/` for the shipped
2012 one, which is the test that proves it faithful (below). `node mock/server.js --help` lists
the options.

Port 8080 is the real server's default on purpose, so a client written
against one works against the other with no change. It does mean the mock
and the rig in [TESTING.md](../docs/TESTING.md) cannot both be up: pass
`--port` to whichever comes second.

## Why it exists

Two reasons, both from [CONSTRAINTS.md](../docs/CONSTRAINTS.md):

- **A dev server cannot talk to a real game server.** A request carrying
  an `Origin` that does not match `Host` is refused `403`, so a Vite
  server on `:5173` is locked out of `:8080` by design.
- **UI work should not need a 3.5 GB NS2 install running.** The rig in
  [TESTING.md](../docs/TESTING.md) answers questions only the real engine
  can answer. Everything else belongs here.

## What it reproduces

Behaviour, not just bodies. All of it measured against a live 26-09-03
server and written up in [API.md](../docs/API.md):

| | |
| --- | --- |
| Routing | One endpoint. `/` is the handler, **not** a directory index -- it returns the server-state blob. The panel is at `/index.html`. Any path that is not a file on disk falls through to the handler, so there is no `404`. |
| Methods | `GET` and `POST` only; `PUT`/`DELETE` are refused `405` before the handler sees them. Method is not otherwise enforced, so every write also works as a `GET`. A `GET`'s parameters come from its query string; a `POST`'s from its form body **only** -- its query string is dropped (measured on 09-26). |
| Origin | Compared against `Host`. A mismatch, including `Origin: null`, is refused `403` and logged. |
| Host | Without `--auth` -- a server with no web users -- a `Host` that is neither `localhost` nor an IP literal is refused `403`, static files included, as the 09-25 engine does. A missing `Host` passes. `--no-host-rule` turns it off. |
| Headers | The full hardening set on every reply: `nosniff`, `DENY`, `frame-ancestors 'none'`, `no-referrer`, `no-store`. |
| Writes | Answer `200` with an empty body and `Content-Type: text/html` -- not JSON, because the Lua returns nothing. |
| Body cap | 64 KB. A larger declared `Content-Length` is refused without reading the body. |
| `getmods` | Answers `{"loading": true}`, starts a search, caches the result for 60 s keyed by search text and page (run together, as vanilla does), and restarts a search still running after 30 s. As the engine does (measured on 09-26): at most 50 hits, the page ignored, an empty result `{"items":[]}`. Without `searchtext` no search starts; a `p` that is not a number is an empty `200`. The catalogue is the fixture's 50 plus four made-up items (three that one search term finds, for a small result, and one with markup and BBCode in its title and description). |
| `installmod` | The id appears in `getinstalledmodslist` 3 s later, under its title, if it is in the catalogue; an id Steam would not have never appears, as on the rig. A malformed one is dropped without a word. |
| Console commands | Run, mutate state, and return **nothing**. A kick is still listed in `player_list` in the very reply that performed it, because the response is rendered before the disconnect completes. The round commands are there: `sv_reset` ends the round (and with `--mod` prints the three lines the rig does), `sv_rrall`, `sv_randomall` and `sv_forceeventeams` move players. `sv_mute` and `sv_resetround` do not exist, as on every server. `/__mock/round` starts a round. |
| `/` | With `--mod`, a request with no parameters at all gets the rig's page leading to `/index.html` (`fixtures/root-mod.html`); without it, the blob. |
| `getperfdata` | The fixture's readings with their times moved so the newest is now, then one more every `--perf-rate` seconds (default 60), 30 kept. Emptied by `sv_changemap`. |
| Mod ids | Hex strings both ways, including the `:` escape hatch for non-workshop sources. |
| Digest auth | Optional (`--auth`), with the measured 301 s nonce lifetime, single-use `nc`, and `stale="true"` refusals. |

### `--mod`: the server this repo is building

By default the mock is a **stock** 26-09-03 server, because that is what
the 2012 panel was written against and what the faithfulness proof needs.
`--mod` makes it the server this repo's `lua/` turns it into:

| | |
| --- | --- |
| `mod_version` | Present in the state blob. Its absence is how the panel detects a stock server, so both modes matter. |
| `runcommand` | Runs a command and returns what it printed, tagged `audit`, `admin` or `server`. `dispatched` is the audit line the game emits before every command made with `CreateServerAdminCommand`. |
| `getconsole` | The same capture as a stream, with a `since` cursor and a `dropped` count. |
| `getchatlist` | With `since`: the mod's ring of 200, with times, `last_id` and `dropped`. Without it, the game's 20 in the game's shape, as on stock. Both rings empty at `sv_changemap`, ids from 1. `/__mock/chat` has a player say something. |
| `getbans` | The bans in force, normalized, from Shine's table under `--shine` and vanilla's otherwise. |
| `getrecentplayers` | Players seen in the last 24 hours, up to 100: the synthetic `fixtures/getrecentplayers.json` with its times moved to now, plus the humans connected now. A kick, a ban or a map change leaves a player in the list, no longer connected. With `--shine` too, an `sh_banid` of someone absent but in the list is stored under their name, as the mod's wrapped `AddBan` does. |
| `getmapcycle` | Reads MapCycle.json. Without `--mod` it answers from the copy loaded with the map, which only `sv_changemap` refreshes from the file -- so a hand edit (`/__mock/cycle-file`) shows on the mod and not on stock, as on the rig ([CONSTRAINTS.md](../docs/CONSTRAINTS.md) item 13). |
| `setmapcycle` | Checked first, with the Lua's wording: a refusal is `{"ok": false, "error"}` and writes nothing, a write answers `{"ok": true, "cycle"}` read back. Keys it does not know pass through. Stock answers the empty `200`, and a cycle with no `maps` writes nothing, as the Lua error does. |
| `getmapvote` | `{"enabled": false}`, or with `--shine`'s `mapvote` the view the rig measured: options from the cycle, round limit 2, and Shine's next map. The options are read at boot and at `sv_changemap` only, so an edit reaches them at the next map. |
| `getmods` | The mod's replies: `elapsed` while loading; `done`, `page`, `count`, `capped` once settled; a search with no answer after 30 s answered once with `error`. A missing `searchtext` is `""`, a bad `p` is 1. |
| `installmod` | `{"ok": true, "id", "already_installed"}`, or `{"ok": false, "error"}` for what is not a hex id, with the Lua's wording. |
| `getinstalledmodslist` | Each row gains `active`. What is mounted is fixed when the map loads, as on the rig: the two hotfix mods the engine mounts by itself (UWE Hotfix 344, NSL Badges), the cycle's global mods and the loaded map's own. So a cycle edit shows only after `sv_changemap`. Stock rows carry no `active`. |
| `getperf` | 10 s windows (`--perf-window <s>` to shorten them for a gate) in the shape the rig returned (`fixtures/getperf-rig.json`), made up and seeded with half an hour of history. Its `config` runs 60/60/60 with interp 85, and the state blob's `frame_rate` follows it, so nothing can assume 30. `sv_changemap` starts over: a new `loaded_at`, ids from 1. `/__mock/perf` forces the next window's values. `engine` is what the Lua's log scan finds: the engine's `tickstat N` (off until run; `--tickstat <s>` boots with it on and half an hour behind), `perfmon` (its block, and the Lua's `monitoringActive` line stepping the level) and `bwlimit` (the engine's warning when it leaves under 2048 B an update) all write to the log as the 09-27 engine does, and `runcommand` gets no lines for them, as on the rig. `/__mock/tickstat` forces the next line's values or a rate step. `config.bw_limit` follows `bwlimit`. |
| `getlog` | `log-Server.txt` by byte offset, the Lua's algorithm step for step (tail, `since`, `before`, whole lines, the 64 KB cap, `reset`). The file is a buffer: a header, a boot and 40 rounds of made-up history from `log-seed.txt` (fake names, `0.0.0.0`, about 75 KB, so there is a page to load back), then every line the console tees, a map change's loading lines, the engine's `Script tracing` pair every 30 s, and the mod's check line once per map load. Offsets are bytes (a name in the seed has accents). `sv_changemap` leaves the file alone; `clearconsole` does nothing, as on the rig. `--log=off`: the file cannot be opened, with the rig's error text. `/__mock/log` writes behind the server's back. |
| `getwhitelist` | The ranked-mod whitelist as the mod serves it, the rig's read from Steam (`fixtures/getwhitelist-rig.json`). With no copy, the first request answers `fetching` and the read lands 1.5 s later (`--whitelist-delay <ms>`). `--whitelist=cached` starts with a copy, as after a map change. `--whitelist=fail` makes the read fail with curl's unknown-host message; the mod then waits 5 minutes before reading again, and so does the mock. A copy older than an hour is read again. |
| `max_players` | In the state blob; 16, like the rig. |
| `map_loaded_at` | In the state blob: `getperf`'s `loaded_at`, which `sv_changemap` moves. |
| `skill` | Each player's `skill`, `skill_offset`, `comm_skill` and `comm_skill_offset`, made up but stable (from the Steam id); -1 in all four for bots, as the rig reports them. `skill_tier` from the made-up skill, a made-up adagrad sum and rookie flag, through the game's `GetPlayerSkillTier`; -1 for bots. |
| `--beta-players` | The 09-26+ engine's per-player fields, made up: the first human plays a Family Shared copy (`familyshared`, `owner_steamid`) with 37 time-credit and 2 other rejected moves; bots read as not shared, with none. Without the flag they are absent, as on an older engine. |
| The bug flags | All off, since the mod fixes them. |

Reproducing it faithfully meant correcting the mock's own output, all of
it checked against `ServerAdminCommands.lua` or measured on the rig: an
unknown command prints **nothing** (not `Unknown command: x`), a
successful `sv_kick`, `sv_slay`, `sv_switchteam` and `sv_unban` print
nothing either, `sv_help` prints help lines but emits no dispatch
receipt, and `sv_reserved_slots` reports through `Shared.Message` rather
than `ServerAdminPrint`. `sv_ban` *does* report: `<name> has been banned`,
or `Player with SteamId N has been banned` for an id that is not
connected. The reserved slot commands take the name as one argument
(quotes are not parsed), key slots by name, ignore an amount above
`max_players` without a word, and print nothing when a removal matches
nobody -- all measured on the rig, 2026-09-27. Those strings still appear in the mock's own
log; they are kept out of the console buffer, so the mock is never more
informative than the server it imitates.

Without `--mod` these two request types are unrecognised and fall through
to the state blob, exactly as they would on a stock server -- which is
what a panel pointed at the wrong server actually sees.

### `--maps=modded`: a modded server's cycle

The default map cycle, map list and installed mods are a stock install's:
17 maps, no mods. `--maps=modded` swaps in a modded server's, captured on
the rig 2026-09-27: 22 global mods, per-map mods, 40 maps of which 23 come
from mods, plus a Shine per-map option (`"min": 12` on
`ns2_veil`) and a map group, both written through the mod's
`setmapcycle` on the rig so the round trip is exercised
(`fixtures/getmapcycle-shine-options.json`).

### `--shine`: the common case

`--shine` loads a simulated Shine with the plugins named on
(`--shine=ban,reservedslots,mapvote,basecommands`; bare `--shine` means
`ban,mapvote,basecommands`). It combines with `--mod` or without it. All
wording was measured on the rig with a Shine config, 2026-09-27; see
[CONSTRAINTS.md](../docs/CONSTRAINTS.md#shine-2026-09-27).

| | |
| --- | --- |
| Ban table | Shine's own, seeded from the synthetic `fixtures/getbans-shine.json` with its times moved to now. `getbanlist` serves it the way Shine's replacement `GetBannedPlayersList()` does: string ids, `6e+24` for one permanent ban, and a **different order on every call**. |
| `sh_ban`, `sh_banid`, `sh_unban` | Shine's lines, `Console[N/A] banned <name>[<id>] for 1 day.` and friends, each followed by Shine's `ran command ... with arguments:` receipt. No audit line. `sh_ban` targets only a connected player; anything else gets Shine's misleading `You cannot target yourself with this command.` |
| `sv_ban`, `sv_unban` | Run **both** Shine's command and vanilla's, in the measured order. So an `sv_ban` of an id that is not connected fails in Shine, succeeds in vanilla, prints `has been banned` -- and lands only in the vanilla list, which nothing enforces. |
| `sh_setresslots` | Exists only with `reservedslots` on. With `--mod`, `getreservedslots` then carries `shine.slots`. |
| `sh_gag`, `sh_ungag` | With `basecommands`: Shine's lines and receipt (`Console[N/A] gagged <name>[<id>]`), `No player matching '<id>' was found.` for nobody, and only the receipt for an ungag of someone not gagged -- all measured with a human joined. A gagged player's chat (`/__mock/chat`) never reaches the chat. A map change clears every gag. |
| `sv_say` | With `basecommands`, Shine's `sh_say`: only Shine's receipt, no audit line, and the message in the chat. |
| `shine` | In the state blob with `--mod`: which of the four plugins are on. With `basecommands`, each player carries `gagged`. |

Not modelled: Shine eating vanilla admin-command output. The mock's
`--mod` is the fixed Lua, whose wrapper re-installs itself; the rig is
where that fix was proved.

### The bugs it reproduces on purpose

The shipped panel was written against a server that has these, so the
mock has to have them too or the panel would behave differently against
the mock than against a real server. Each can be switched off with
`--fix`, as the mod's Lua fixes them.

| Flag | What it reproduces |
| --- | --- |
| `setreservedslotamount` | The request answers `200` and changes nothing ([CONSTRAINTS.md](../docs/CONSTRAINTS.md) item 7). |
| `unban` | `sv_unban` never matches a ban that is plainly in the list (item 8). |
| `banPruning` | Expired bans keep being listed (item 9). |
| *(always)* | A bot's `steamid` is `0`, so every per-player command aimed at one silently does nothing ([CURRENT-UI.md](../docs/CURRENT-UI.md) defect 7). |

`--fix-all` turns all three off, and so does `--mod` -- a server running this repo's `lua/` has the fixes by definition, so reproducing the bugs alongside the mod's request types would mock a server that does not exist.

## Control endpoints

Not part of the real API, never requested by the panel, and removable
with `--no-control`:

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

`log` answers with the file's size and id. `partial` then `append` is a
line the engine finished late; `burst=700000` is more than one reply;
`restart` changes the header's time, which is to the second, so wait a
second after a previous one.

`workshop`: `hang` is a search Steam never answers, `offline` one it
fails, which comes back at once and empty, as on the rig with no network.
A stock server restarts a search after 30 s, so a hang that outlasts the
restart needs `n=2`. `install=never` is an id Steam does not have.
`timeout` shortens the mod's 30 s, so a gate need not wait it out.

`recent-load` takes `ok`, `fallback`, `empty` or `unreadable`, and an
`error` makes it report a failing save. The file itself is the Lua's
business; this is how a gate reaches the panel's notes about it.

`cycle-file` changes the file only, the way an operator with a shell
would: `mod` is appended as written, so `mod=zzzz` plants a junk id for
the refusal path.

`503` is the shape a real server takes when a request gives up after
30 s. It has to be retried, not surfaced as an error.

## What it does not reproduce

- **Rate limiting.** 10 failed logins per address per minute earns a
  one-minute lockout on a real server. Not modelled, so a retry loop that
  would lock you out of a real server runs happily here.
- **The `503` timeout itself.** It can be triggered, not earned; nothing
  here actually takes 30 s.
- **Anything about the game.** Teams, resources and scores move only as
  far as a console command moves them.

## Proving it is faithful

The test is that the *shipped* 2012 panel runs against it unmodified:

```bash
node mock/server.js --port 8090 --perf-rate 2 --web <server>/ns2/web &
python3 tools/browser-checks/mock-acceptance.py
```

22 checks in headless Chrome across all six tabs -- kick a player, add a
ban, add a reserved slot, save the map cycle, page the workshop browser,
draw the performance chart -- including the checks that assert the
reproduced bugs still misbehave. Exit status is 0 only if every one
passes.

## Files

| File | What it is |
| --- | --- |
| `server.js` | The engine half: routing, the hardening rules, digest auth, static files. |
| `state.js` | The Lua half: server state, the request types, and the console commands. |
| `log-seed.txt` | The made-up history `--mod`'s log starts with: a boot, then a round repeated. Synthetic, in the line shapes of real servers' logs. |

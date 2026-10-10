# Requirements

What the replacement has to do, from using the shipped panel, with a
feasibility verdict for each item measured against a real server, and
what was built. Code and other docs cite the items by number.

"The rig" is the local test server ([TESTING.md](TESTING.md)); each
measurement names the engine drop it ran on.

| # | Item | Status |
| --- | --- | --- |
| 1 | Survive a long server name | Built (front end) |
| 2 | Delete / uninstall mods | **Needs an engine change**; not possible from a mod |
| 3 | Installed mods: loaded first, with the id | Built and verified on the rig (Lua `active` flag, Mods tab) |
| 4 | Mod browser: details before install | Built and verified on the rig (Workshop tab). No paging: the engine returns 50 hits |
| 5 | Console commands return their output | Built (Lua wrappers, `runcommand`) |
| 6 | Ban from a list of recent players | Built and verified on the rig (`getrecentplayers`, a two-slot file) |
| 7 | Tail the server log | Built and verified on the rig (`getlog`, Console tab) |
| 8 | Light, fast, dark, full width | Built (front end) |
| 9 | Per-admin settings in the browser | Built (Settings tab) |
| 10 | Performance: what `perfmon` measures, drawn | Built and verified on the rig (`getperf`, Performance tab) |

## 1. Long server names

The 2012 navbar wraps on a long `server_name` and overlaps the player
table. The rule generalises: every string from the API is operator- or
player-controlled and can be long, empty or contain markup (`server_name`,
player names, ban reasons, chat, map names, mod titles).

## 2. Delete / uninstall mods

**Not possible from a mod.** On a live server:

```
Server.InstallMod    function
Server.UninstallMod  nil
Server.RemoveMod     nil
os.remove            nil
os.rename            nil
os.execute           nil
io.popen             nil
```

There is no uninstall binding, and the Lua sandbox cannot delete a file or
shell out, so `getinstalledmodslist` only grows. The panel shows what is
installed, distinguishes installed from loaded, lets an operator stop
loading a mod, says that installed mods accumulate, and offers no delete
button. It is the only feature that needs an engine change
(`Server.UninstallMod`); it comes after parity and blocks nothing.

## 3. Installed mods: loaded first, with the id

The engine exposes the mounted mods directly:

```
Server.GetNumMods()        3
Server.GetNumActiveMods()  3
Server.GetActiveModId(i)   "1e62a2ce"   -- a hex string, not a number
Server.GetModId(i)         "1e62a2ce"
```

The ids are strings, so `string.format("%x", ...)` on them raises an
error. Stock `GetModList()` returns only `{ id, name }`; the mod adds
`active`, so the panel does not infer it from the cycle.

Measured on the rig (09-26 hotfix, a Shine config with 23 mods; probe
`tools/spikes/mods-branch.lua`):

| Question | Answer |
| --- | --- |
| Do `GetActiveModId` values match `GetModId`? | Yes: lower-case hex, no padding (`706d242`), strings both. A set lookup is enough. |
| What is mounted that the cycle does not name? | UWE Hotfix 344 and NSL Badges, which the engine downloads and mounts first by itself. Nothing else. |
| A map's own mods? | Mounted only with that map, listed last, dropped at the next map. |
| A global mod removed from the cycle? | Unloaded at the next map change. A cycle edit is not a load. |
| A mod titled with its decimal id (`1423731186`)? | A download that never completed; the engine falls back to the id as the title. |
| `Server`'s mod functions | `GetNumMods`, `GetModId`, `GetModTitle`, `GetNumActiveMods`, `GetActiveModId`, `GetMapModId`, `InstallMod`, `SearchWorshop`, `SetModBackupServers`, `EnableServerRanking`, `GetIsRankingActive`. No uninstall. |

**Built.** The Mods tab lists mods in mount order, as the engine logs
`ModMounter::Mount`: the engine's two hotfix mods, then the cycle's global
mods, numbered, then the rest, loaded first. A map's own mods mount after
the globals with their map and are not numbered. A cycle id that is not
installed sits in its place, removable. Each row shows the hex id
(selectable) and the decimal workshop id as a link. Load with every map
appends to the cycle's global `mods`; Stop loading removes it in place;
each says it takes effect at the next map change. Changing the order
stays a file edit, by decision. Each mod is marked whitelisted or not
(CONSTRAINTS item 17).

`GetIsRankingActive()` is always `false` while this mod is mounted, since
it is not whitelisted, so the tab states the ranking rule instead of
showing a ranked indicator.

Driven through the panel on the rig: Load with every map on `Mouse Wheel
Jump` read "loads at the next map change"; after `sv_changemap` the log
showed `Mounting mod 'Mouse Wheel Jump'` and the row read "loaded now";
Stop loading reversed it at the next change. Fixture:
`getinstalledmodslist-active.json` (49 installed, 24 active).

## 4. Mod browser: details before install

`getmods` returns per result `id`, `title`, `description`, `authorid`,
`filesize`, `tags`, `version`, `childcount`, `steamresult` and
`thumbnailurl`, enough for a detail view. Two limits from the no-CDN rule
([CONSTRAINTS.md](CONSTRAINTS.md#no-cdn)):

- `authorid` is a number. A name needs the Steam Web API, so the panel
  shows the id and links to the profile.
- `thumbnailurl` is on Steam's CDN. Thumbnails are on by default and are
  the one thing the panel fetches from a third party; Settings turns them
  off. The 2012 panel searches on every page load and fetched 4.55 MB of
  thumbnails for a tab nobody opened (CURRENT-UI defect 13); the
  replacement searches only once the tab is shown.

Measured on the rig (09-26 hotfix, stock config; probe
`tools/spikes/workshop-branch.lua`; for the failure case the rig ran
without a network under `unshare -rn`):

| Question | Answer |
| --- | --- |
| What does the `SearchWorshop` callback get? | One table of up to 50 items, ids as numbers (`%x` formats those above 2^31 correctly). No total: the engine logs `numMatching = 2874` but does not pass it on. |
| Paging? | None. Pages 0, 1, 2, 3 and 500 returned the same 50 items (CURRENT-UI defect 15). Results are ordered by relevance. |
| An empty result? | `{"items":[]}`: dkjson writes an empty table as `[]`. |
| A failed search? | Indistinguishable from an empty one. Offline, Steam logged `Failed Steam error NoConnection` and the callback got an empty table in the same frame. Nothing in `Server` or `Shared` reports Steam connectivity. |
| How long does a search take? | 0.3-0.9 s online. |
| Missing `searchtext`, `p=abc`? | Stock: no search ever starts (`loading` forever), and a Lua error with an empty 200. `SearchWorshop(string, number, function)` is strict. |
| A 3000-character query? | `401`: Digest fails on a URI that long. The tab caps input at 200. |
| What does `InstallMod` return? | Nothing, whatever the id. `-5` became mod 18446744073709551611, which Steam reported as not found. |
| When is a download visible? | Once downloaded and unpacked, under its real title: 1.7 s for 710 bytes, 3.8 s for 26 MB. An id Steam does not have never appears. Nothing about a download reaches `Shared.Message`. |
| Installing while a map runs? | Works. Re-installing a current mod downloads nothing; for a mounted mod the engine logs `Canceling mod ... download attempt because game is active`. |
| Finding a mod by id? | Searching by decimal id finds nothing, and by hex id returns 50 unrelated mods. The title works. |

The mod's changes to `getmods` and `installmod`: CONSTRAINTS item 2
(harness `workshop-harness.lua`).

**Built: a Workshop tab**, separate from Mods, since downloading a mod is
not loading it. It searches only once opened, lists results with size and
date, and opens a row into its details: the description as text with
BBCode stripped, hex and decimal ids, the author's SteamID64 linked to the
profile, tags, required items, Steam's problem flag, and whether it is
whitelisted. Install asks first, saying it only downloads, cannot be
undone, and that loading a mod that is not whitelisted turns ranking off.
A download reads "Downloading" until the installed list has the id, then
"installed", with Open in Mods. With 50 hits at most, the tab points to
the Steam Workshop to find a mod's title.

Driven through the panel on the rig: `crosshair` found Green Crosshair
(High Visibility); Install read "Downloading", then "installed" two seconds
later; Load with every map and `sv_changemap` mounted it. Nothing was
requested from anywhere but the server.

## 5. Console commands return their output

Stock commands return nothing, so a failed and a successful kick look the
same ([API.md](API.md#console-commands)).

`ServerAdminPrint` is defined in `core/lua/ServerAdmin.lua:156` (the core
tree, not `ns2/lua/`). It is a plain global inside `if Server then`, and no
caller keeps a local alias, so a wrapper installed from our
`ServerWebInterface.lua` reaches all 36 call sites. For a web request
`client` is nil, so it falls through to `Shared.Message`, into
`log-Server.txt`, where HTTP cannot reach it.

Probe `tools/spikes/console-output-probe.lua` on the rig (09-03):

| Question | Answer |
| --- | --- |
| Is `ServerAdminPrint` wrappable? | Yes |
| Are `Shared.Message`, `Print`, `Log` writable? | Yes |
| Is the `debug` library available? | Yes |
| Is `Shared.ConsoleCommand` synchronous? | Yes: the output is captured when it returns |

| Command | What came back |
| --- | --- |
| `sv_kick NoSuchPlayerHere` | `No matching player` |
| `sv_unban 123456789` | `No matching Steam Id in ban list: 123456789` |
| `sv_reserved_slots 3` | `Reserved slot amount set to 3`, through `Shared.Message` only |
| `sv_cheats 1` | Only the audit line; it worked |
| `sv_help` | 37 commands, 8.6 KB |
| `sv_nonsense_command` | Nothing, not even in the log |
| `killall` (not an admin command) | Nothing |

Consequences for the design:

1. **Wrap both `ServerAdminPrint` and `Shared.Message`, and dedupe.** Some
   commands report through `Shared.Message` alone, but `ServerAdminPrint`
   calls `Shared.Message`, so each admin line arrives twice unless the
   nested call is suppressed.
2. **The audit line is a dispatch receipt.** Every command made with
   `CreateServerAdminCommand` prints `sv - <name> - <id>: : <steamid>:
   <command>` before running (`core/lua/ServerAdmin.lua:113`). Without it,
   the command was either an `Event.Hook` command (`sv_help`, `killall`) or
   nothing.
3. **Web requests bypass the permission check**: `not client`
   short-circuits `GetClientCanRunCommand`. Authentication is the Digest
   layer's job.
4. **Silence is ambiguous.** `sv_cheats 1` succeeded silently and
   `sv_nonsense_command` failed silently. "No output" is shown as such,
   never as success.
5. **Capture covers the synchronous call only.** Anything printed later
   needs a buffer, which `getconsole` provides.

## 6. Ban from a list of recent players

`Event.Hook("ClientDisconnect", fn)`, `ClientDisconnected`,
`Server.GetOwner` and `Server.GetClientById` all exist. Requirements, by
decision:

- The list is bounded and says by what.
- Searchable by partial name and by SteamID.
- **It survives a map change; it need not survive a restart.** Shared time
  and the Lua state restart with each map (`uptime` read 11 s after a map
  change), so an in-memory list is wiped by exactly the event it must
  survive. It has to live in a file under `config://`. It then also
  survives a restart, which is acceptable; telling the two apart would need
  a boot marker the engine does not offer.

What a file under `config://` allows (09-26; probe
`tools/spikes/engine0926-branch.lua`):

| Operation | Result |
| --- | --- |
| `io.open("config://x.txt", "w")`, write, read back | Works; the file lands in the `-config_path` directory |
| A 100 KB write | Works |
| `config://improved-webadmin/probe.txt`, directory absent | Works: the directory is created |
| Any path without `config://` | `writing to the game directory is not allowed` |
| Mode `"a"` | Truncates, like `"w"` |
| `os.rename`, `os.remove` | Absent |

So a save rewrites the whole file, there is no write-then-rename, a crash
can leave the file torn, and nothing can delete it.

**Built: 24 hours, at most 100 players**, both stated by the server and
shown in the tab. A connected player is never aged out.

- **Two slots replace write-then-rename.** Saves alternate between
  `config://improved-webadmin/recent-players-a.json` and `-b.json`, each
  with an increasing `seq`. The loader decodes both under `pcall` and takes
  the newest that parses, reporting `ok`, `fallback` (newest torn),
  `empty` (no file yet) or `unreadable` (both torn: start empty). A failing
  save is reported with its error. The tab shows each.
- **Per player:** Steam id, name, up to 5 former names (searched too), IP,
  first and last seen, time played. Bots are skipped. Times are
  `Shared.GetSystemTime()`, since `Shared.GetTime()` restarts with the map.
- **Writes:** on the tick after any disconnect (a mass disconnect costs
  one write), otherwise at most once a minute while anything changed. A
  10 s sweep updates names, IPs, time played and `last_seen`, so a map
  change loses at most a minute of those.
- **`connected` is read off the live player list** at request time, so a
  map change never reads as everyone leaving.
- **IPs are shown unmasked** in this tab, by design: spotting a returning
  player under another account is what they are kept for. Steam ids stay
  masked. See [API.md](API.md#privacy).

Harness `tools/spikes/recent-players-harness.lua` covers rename history,
bots, a map change (a fresh VM over the same files), torn slots, capacity
and the window.

Measured on the rig (09-26 hotfix, one human; probe
`make-recent-players-probe.sh`):

| Question | Answer |
| --- | --- |
| At a map change, does `ClientDisconnect` fire? | No. `ClientConnect` fired again 18 s after the load, logged as `Client connected` with no `Client connecting`. |
| Inside `ClientConnect`, what is usable? | `GetUserId`, `Server.GetClientAddress`, `GetControllingPlayer`. The name is still the `NSPlayer` placeholder; the real one appears by the next sweep, and the placeholder is ignored. |
| `json.decode` on truncated input | Returns `nil`, a position and an error; it does not throw. |
| `config://` readable at file load? | Yes. |
| What does a save cost? | 0.08-0.42 ms for a one-player file. |

End to end: a rename kept the old name; a disconnect was saved on the next
tick; a rejoin kept `first_seen`, and time away was not counted; with the
newest slot cut in half, the boot reported `fallback` and served the older
slot intact (`fixtures/getrecentplayers-rig.json`). The synthetic
`getrecentplayers.json` seeds the mock, since a gate needs more players.

**Names on bans of absent players (Shine only).** Shine's `sh_banid`
stores an absent player as `<unknown>`, vanilla's `sv_ban` as `Unknown`.
Shine's `BanID` passes `"<unknown>"` to `Plugin:AddBan`, a public method
that every consumer of the ban reads from, so the mod wraps `AddBan`
(re-applied each tick, since Shine loads later) and substitutes the name
this list last saw, logging `Named the ban of <id> "<name>", from recent
players.` An id not in the list is left alone. Verified on the rig: the
seeded name reached Shine's `Bans.json`, the synced `BannedPlayers.json`
and `getbans`. Vanilla keeps `Unknown`, by decision: its ban table is
file-local and reachable only through `debug.getupvalue`, too tied to the
game's internals.

## 7. Tail the server log

`io.open` refuses absolute paths and paths outside a mounted root, so
`/srv/ns2/config/log-Server.txt`, `log-Server.txt` and
`config://logs/log-Server.txt` all return `nil`. Two routes:

- **Route 1, the file.** With `-logdir` equal to `-config_path`, or
  neither flag (the default layout, where both are
  `$XDG_CONFIG_HOME/Natural Selection 2/`, else `~/.config/Natural
  Selection 2/`), `config://log-Server.txt` opens. It is the engine's whole
  log, and it is fresh: a `sv_say` run inside a web request appeared in a
  read later in the same request. The cost is the layout rule, and the
  engine also writes `dumps/` there.
- **Route 2, the mod's own buffer**, fed by the item 5 wrappers. It works
  on any server but sees only what passes through Lua (`ServerAdminPrint`,
  `Shared.Message`, `Print`, `Log`), not what the engine writes directly
  (`Script tracing`, map load errors, the boot).

Both ship: route 1 is `getlog`, route 2 is `getconsole`, and the command
line works whatever the log.

Measured on the rig (09-26 hotfix; probe `log-branch.lua`, built by
`make-log-probe.sh`; `logdir-probe.lua` for route 1):

| Question | Answer |
| --- | --- |
| Can a read seek to any offset? | Yes. `seek("end")`, `seek("set", n)`, `read("*a")`, `seek("cur", -16)` behave as in standard Lua; `read(0)` returns `""` mid-file and `nil` at the end. |
| Polling cost when idle? | Nothing: the file does not grow. |
| The largest reply the engine serves | No limit met: 64 KB to 16 MB all `200` (16 MB in 0.24 s). The 64 KB cap is the mod's ([SERVER-COST.md](SERVER-COST.md)). |
| Invalid UTF-8, control bytes | Kept as written. dkjson escapes control characters and passes invalid UTF-8 through. |
| A restart | The old file becomes `log-Server.old.txt`; the new one has a new `Date:`/`Time:` header. A map change does nothing to the file. |
| `clearconsole` | Leaves the server's log alone, through the web admin and through the console FIFO. The changelog's `log.txt` is the client's. |
| Can a read end mid-line? | Not seen in 5404 reads under load, but a force-stopped server's log does, so only whole lines are served. |
| What a read costs | 0.2-0.3 ms for 64 KB, 0.7 ms for 256 KB, 3 ms for 1 MB; 0.005 ms to open and find the size. |
| A boot with `-logdir` elsewhere | `config://log-Server.txt` still opened: the frozen file an earlier run left. Hence the stale check (CONSTRAINTS item 15). |
| A handle opened before a write | Does not see it: a handle sees the file as it was when opened. |

The log is not sanitised: chat, Steam ids, names and IP:port appear
verbatim, and the Console shows them as written, by design
([API.md](API.md#privacy)).

`getlog` is specified in [API.md](API.md#getlog); its harness,
`tools/spikes/log-harness.lua`, writes the file the way the engine does
and covers partial lines, the cap, paging back, CRLF, odd bytes, a 300 KB
line, a cut, a new header and a stale copy.

**Built: the Console tab**, the log with the command line under it. It
reads the tail when opened, Load earlier pages back to the start of the
file, and a poll follows the byte cursor (its own refresh setting, 2 s by
default, only while the tab is open). Filters by kind with counts (chat,
connections, admin commands, errors and warnings, engine, other; Engine
and Other off at first, kept in the browser), search, and following the
end only when the reader is there. A banner reports a restart, a cut file,
or more than 1 MB written while the tab was away (it skips to the end).
Each kind has a colour at 4.5:1 or better in both themes; chat is in the
speaker's team colour, looked up in the player list since the server
writes no team into chat lines. Save writes every line read, hidden kinds
too. When the log cannot be read the tab says why; on a stock server it
explains itself and never asks.

On the rig the tail and a full page-back matched the file byte for byte;
a map change kept the cursor; a restart answered `new_file`; `-logdir`
elsewhere answered `No such file or directory`, or `stale` with a copy
left behind. The default layout also worked, `tickstat` lines included.
Fixtures: `getlog-rig-tail.json`, `-since`, `-reset`, `-stale`,
`getlog-none.json`. Not yet seen: a populated round's log through the
tab.

## 8. Light, fast, dark, full width

On top of the [design decisions](DESIGN.md#design-decisions):

- **Dark by default**, light available.
- **Full width.** The 2012 panel is a fixed, centred Bootstrap 2 container
  around a wide table.
- **Small on the wire.** Plain HTTP, `no-store` replies and polling make
  payload size per poll matter as much as render time.
- **No layout shift while polling.** The 2012 panel rebuilds its tables
  and loses scroll position and sort order.

## 9. Per-admin settings in the browser

Front end only: `localStorage`. Settings belong to the browser and the
address, not to an admin (the panel has no user model beyond Digest), and
the tab says so.

**Built: a Settings tab**, which renders without server data, so refresh
can be turned off while the server is unreachable. The tabs' own toggles
and the footer's refresh and theme are shortcuts to the same values.

| Setting | What it is |
| --- | --- |
| Mask Steam ids and IPs | On by default. A reveal is per row, until the tab is left. Recent players shows IPs regardless (item 6). |
| Refresh | Three knobs, each 1, 2, 5, 10 s or off: server state (header, Players), Chat, and the Console's log. The rest are fixed: lists 10 s, maps and mods 60 s, Performance per server window, a Workshop search 0.5 s. A knob turned off says so on its tab and offers Read now. |
| Theme | Dark (default), light, or the system's, followed live. |
| Times | As the browser writes them (default), 24-hour, or UTC: the footer, dates, the console (always 24-hour) and the performance axis. |
| Workshop thumbnails | On by default; turning them off leaves the panel talking only to the game server. |
| Remembered | The last tab (on by default), Players' Hide bots, the Console's filters. |
| tickstat | The server's `tickstat`, on or off (item 10). |

- Stored values are checked field by field; a bad one falls back to its
  default and the rest are kept.
- A browser that refuses storage (private window, blocked site data, a
  throwing `localStorage`) still applies changes for the session, and the
  tab says they will be forgotten.
- Two open tabs stay in step through the `storage` event.

Gate: `tools/browser-checks/spa-settings.py`.

## 10. Performance: what `perfmon` measures, drawn

The 2012 tab charts stock `getperfdata`: one reading a minute of frame
rate, players and entities, 30 kept, lost at every map change, and
re-appended whole on every poll (CURRENT-UI defect 2). `perfmon` is Lua
(`lua/ServerPerformanceData.lua`) over one engine object,
`Shared.GetServerPerformanceData()`, which mod Lua can read too.

Measured on the rig (09-26 hotfix, empty, 30 then 60 tick;
`tools/spikes/perf-probe.lua`):

| Question | Answer |
| --- | --- |
| How often is there a new sample? | Every 1.00 s. `UpdateServer` runs once per tick. |
| Do `ServerPerformanceData()`, `Accumulate`, `Copy`, `Clear` work from mod Lua? | Yes. `GetIncompleteCount` exists; `GetTimeOverdraft` does not. |
| Is any of it dangerous? | `Accumulate()` of an empty sample kills the server (CONSTRAINTS item 14). Found by crashing the rig three times. |
| Getters on an empty sample? | All return 0. |
| Is the engine's tickrate usable? | Not at 60 and up: `GetUpdateIntervalMs()` is whole milliseconds, 16 at 60, which reads 62.5. That is the `tick 62.5` in a 60-tick server's `Perf` lines. Counting `UpdateServer` calls gives 60.0. |
| Which clock times a tick? | `Shared.GetTime()` and `Shared.GetSystemTimeReal()` agree to 0.1 ms; the mod uses the real one. |
| Do the configured rates follow a runtime change? | Yes, on the next sample, so they are read per request. |
| Score and quality with nobody on? | Both 0; `DetailText` refuses to describe the sample. The panel shows "no players". |
| `collectgarbage("count")`? | About 20 MB on an empty rig. |
| `/proc/self/status`? | Not readable. Process CPU and RSS are out of reach. |

With one human and 11 bots, `perfmon` detailed alongside, the windows
matched the `Perf` lines (idle 85.2 against 85.1 %, entities 14.2 against
14.3 %, score 80-86 against 80 at 30 tick). At 60/60/60 the counted
tickrate was 59.99-60.01 where every `Perf` line printed `tick 62.5`. A
map change with the tab open kept all 43 windows of the first map.
Fixture: `getperf-rig-populated.json`. Harness:
`tools/spikes/perf-harness.lua`.

**`perfmon` hides interp fails.** `DetailText` prints warns and fails per
second with `%d`, so under one a second prints as 0: four windows counted
fails (joins and a rate change) while every `Perf` line read `iFail 0`.
`getperf` reports counts, and the tab flags any fail as "past interp",
not as a verdict.

### The engine's log lines (09-27 engine)

`tickstat` lines and the `perfmon:` block are printed by the engine to
the log, not through Lua, so the mod reads them from the log (item 7).
Measured on the rig (`Build: 344 (5dc97682bc beta)`), empty at 30/20, then
at 80/40/40, interp 85, bwlimit 131072, with one human and 11 bots
(`tools/spikes/tickstat-branch.lua`, a console FIFO). The real lines are
in `tools/spikes/tickstat-rig-20260928.txt`.

| Question | Answer |
| --- | --- |
| A `tickstat` line in `log-Server.txt` | One bare line, no prefix or timestamp: `TICKSTAT\| win 10.0 s hz 80.00 target 80 \| int p50 12.55 p99 14.40 p999 14.55 max 14.55 ms \| … \| snap bytes p50 192 p99 384 max 2737 choked 0.00% \| … \| creations deferred 0`, 16 segments, the format string in `server_linux`. |
| How often? | `tickstat 10` prints every 10.0 s, even with nobody on, and replies `tickstat: on`. |
| Can the mod tell whether it is on? | Yes: a bare `tickstat` prints `tickstat: on` or `off` without toggling. `runcommand tickstat 10` returns no lines, since the engine prints only to the log. |
| Across a map change? | It stays on; the window across the load reads `hz 27.99`, `max 664.90 ms`. A restart turns it off. |
| A rate step | `client 1: snapshot rate 40.0 -> 26.7/s (29% choked, 24.9 ms to clear each, bwlimit 10000)`, and back up within 10 s of restoring `bwlimit`. `client N` is a slot number. |
| A starved `bwlimit` | At the command: `bwlimit 10000 bytes/sec at sendrate 40 leaves 250 bytes per snapshot, below the 2048 a full game needs: snapshots will choke and arrive late. bwlimit 81920 or more avoids it.` Raising `sendrate` past what bwlimit allows logs the same. Under it: `choked` 0.38-15.75 %, `rate stepped 1 slowest 26.7/s`, `creations deferred` up to 31. |
| Healthy at 80/40/40 with 12 players | `hz 79.99-80.00`, int p99 14.3-14.4 ms, busy 26-30 %, snapshot p99 384-992 B (budget 3276 B), `choked 0.00%`. |
| `Server.GetBwLimit()`? | Exists, and follows a runtime `bwlimit` at once. |
| Is the `perfmon:` block printed on a timer? | No, only when `perfmon` is typed. It covers the last second (`n=80` ticks at 80). |
| Does `perfmon <n>` set a level? | No: the argument is ignored, and each call steps off → basic → detailed → spam → off. |
| What does a scan cost? | 0.53 ms for the whole 80 KB log. |

The `perfmon:` block with players on (80/40/40):

```
perfmon: tick jitter avg 1.25ms max 2.05ms (n=80)
perfmon: snapshot write avg 0.031ms max 0.064ms (n=40)
perfmon: entities skipped 6438 / 13198 (48.8%)
perfmon: moves rejected: time credit 0, other 0
perfmon: moves rewound with missing snapshots 0 (since map load)
perfmon: score 63 = idle 63.0% - delivery 0.0% - overload 0.0% (updates 40, warn 0, fail 0)
```

**Built.** The mod scans the log every 2 s and `getperf` serves the lines
under `engine` ([API.md](API.md#getperf)); the Performance tab draws them.
`tickstat` is switched in Settings and the switch controls the server, not
the browser: on sends `tickstat 10`, off sends `tickstat 0`, which stops
it for every admin, so it asks first. It defaults to off, shows the
server's real state as read from the log, and needs the mod and a
readable log. On the rig every value served matched the raw line (819
compared); the starved-bwlimit run is `getperf-rig-tickstat.json`.
Harness: `tools/spikes/tickstat-harness.lua`.

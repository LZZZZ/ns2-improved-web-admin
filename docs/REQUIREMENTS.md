# Requirements

What the replacement has to do, from using the shipped panel on the test
rig (2026-09-05). Objectives, not a build order. Each item ends with what
was built.

Each item carries a feasibility verdict, established against a live
26-09-03 server rather than assumed. Where something is **not** possible
that is recorded too, with what it would take.

## Feasibility summary

| # | Item | Verdict |
| --- | --- | --- |
| 1 | Navbar overlaps the player table on a long server name | Front end only |
| 2 | Delete / uninstall mods | **Needs an engine change.** Not possible from a mod; sequenced last |
| 3 | Installed mods: active first, show the mod id | Our Lua (an `active` flag) and the panel, **built and verified on the rig** |
| 4 | Mod browser: open a mod, read details, then install | Our Lua and the panel, **built and verified on the rig**: its own Workshop tab. No paging: the engine returns 50 hits and ignores the page |
| 5 | RCON returns nothing | Our Lua, mechanism **settled** -- wrap two globals |
| 6 | Ban from a list of recent players | Our Lua, **built and verified on the rig**: a two-slot file under `config://` |
| 7 | Tail the server log | Our Lua and the panel, **built and verified on the rig**: the Console tab over `getlog`, with the command line under it |
| 8 | Light, fast, dark, full width | Front end only |
| 9 | Per-admin settings saved in the browser | Front end only, **built**: a Settings tab |
| 10 | Performance: what perfmon logs, drawn | Our Lua (`getperf`) and the panel, **built and verified on the rig**. One engine call kills the server if misused |

## 1. Long server names break the layout

With a long `server_name` the navbar wraps and `navbar-inner` overlaps
the player table. Being rebuilt anyway, so it is not a fix so much as a
thing not to reproduce: the header must tolerate an arbitrarily long
name, and the name is operator-controlled with no length limit.

Treat as a general rule. Every string from the API is
operator-controlled or player-controlled and can be long, empty, or
contain markup: `server_name`, player names, ban reasons, chat messages,
map names, mod titles.

## 2. Delete / uninstall mods -- not possible

**Verdict: needs an engine change. Out of reach for the mod.**

Probed on a live server:

```
Server.InstallMod    function
Server.UninstallMod  nil
Server.RemoveMod     nil
os.remove            nil
os.rename            nil
os.execute           nil
io.popen             nil
```

There is no uninstall binding, and the Lua sandbox has no way to delete a
file or shell out. `io.open` and `io.lines` exist, but they cannot remove
anything.

So `getinstalledmodslist` only ever grows, and nothing short of a new
engine binding (`Server.UninstallMod`) or an operator deleting the
directory by hand changes that.

What the panel *can* do: show what is installed, make clear that
installed is not the same as loaded, and let an operator remove a mod
from the cycle so it stops being mounted. It should not offer a delete
button it cannot honour.

Worth raising separately as an engine request. It is the only item on
this list that needs one. Engine additions that would simplify what is
already built are a separate list: [CONSTRAINTS.md](CONSTRAINTS.md) item 18.

**Sequenced last** *(decided 2026-09-05)*: a feature addition after the
panel is otherwise done, not part of parity. Nothing else waits on it,
the engine request can be made whenever, and until it is answered the
panel says plainly that installed mods accumulate.

## 3. Installed mods: active first, and show the id

**Verdict: front end only. The API already has everything.**

The engine exposes active mods directly -- no need to infer from the map
cycle:

```
Server.GetNumMods()        3
Server.GetNumActiveMods()  3
Server.GetActiveModId(i)   "1e62a2ce"   -- hex string, not a number
Server.GetModId(i)         "1e62a2ce"
```

Note the ids come back as **hex strings**. `string.format("%x", ...)` on
them raises `bad argument #2 to 'format' (number expected, got string)`
-- found the hard way.

Vanilla `GetModList()` returns only `{ id, name }`. Adding an `active`
flag is a two-line change in our copy, and worth doing so the front end
does not have to cross-reference the map cycle.

Show the id on the row. Hover is fine as the primary affordance but it
must also be selectable -- an operator wanting the id usually wants to
paste it somewhere.

### Built *(2026-09-27)*

`getinstalledmodslist` now carries `active` per mod, and the Mods tab
shows loaded mods first, the hex id (selectable whole) and the decimal
workshop id as a link out. It edits the cycle's global `mods`: adding
appends, removing keeps the rest in place. The order is the mount order,
and changing it stays a file edit, by decision.

The table lists mods **in mount order**, read off the rig's log
(`ModMounter::Mount`) *(2026-10-07)*: the engine's two hotfix mods first,
then the cycle's global mods as listed, numbered; then the rest, loaded
first. A map's own mods mount after the globals, with their map, and are
not numbered. A cycle id the server has not installed sits in its place,
removable.

**Measured on the rig first** *(09-26 hotfix, a Shine config with 23
mods; probe `tools/spikes/mods-branch.lua`)*:

| Question | Answer |
| --- | --- |
| 1. Do `GetActiveModId` values match `GetModId`? | **Yes, exactly**: lower-case hex, no padding (`706d242`), strings both. A set lookup is enough. |
| 2. What is active that the cycle does not name? | **UWE Hotfix 344 and NSL Badges**, the two mods the engine downloads itself. They are mounted first, before the cycle's own, with no cycle entry. Nothing else. The tab says the server mounts them anyway and offers no toggle. |
| 3. A map's own mods? | **Active only with that map.** `ns2_jambi`'s `7b986f5` became active on `ns2_jambi`, listed last, and dropped out again at the next map. |
| 4. A global mod removed from the cycle? | **Unloaded at the next map change**: `Mouse Wheel Jump` out of the file, then `sv_changemap`, and it was gone from the active list. So a cycle edit is not a load, and the tab says "loads at the next map change" / "unloads at the next map change". |
| 5. The mod titled `1423731186`? | **A download that never completed.** The mod storage holds only a stray `.bin` for it and an empty cache directory. The engine falls back to the decimal workshop id as the title. |
| Also: `Server`'s mod functions | `GetNumMods`, `GetModId`, `GetModTitle`, `GetNumActiveMods`, `GetActiveModId`, `GetMapModId`, `InstallMod`, `SearchWorshop`, `SetModBackupServers`, and `EnableServerRanking` / `GetIsRankingActive`. Still no uninstall (item 2). |

`GetIsRankingActive()` read `false`, as expected with non-whitelisted
mods mounted. **This mod is one of those non-whitelisted mods**, so
while the panel is mounted the answer is always `false`, and a
ranked/unranked indicator would never say anything else. The tab states
the ranking cost as a general rule instead, and marks each mod
whitelisted or not (CONSTRAINTS item 17). The state blob carries the
answer as `ranking_active` since 2026-10-08.

Then **driven through the panel on the rig**: Load with every map on
`Mouse Wheel Jump` wrote it last in `MapCycle.json`, and the row read
"Not loaded yet: loads at the next map change". After `sv_changemap` the
log showed `Mounting mod 'Mouse Wheel Jump'` and the row read "loaded
now". Stop loading gave "unloads at the next map change", and after the
next change it was neither mounted nor active. No workshop request,
nothing from a third party. Rig restored byte for byte.

`fixtures/getinstalledmodslist-active.json` is that rig's reply with the
shipped Lua, taken on `ns2_jambi` with `Mouse Wheel Jump` out of the
cycle: 49 installed, 24 active, `ns2_Jambi` among them and `Mouse Wheel
Jump` not.

## 4. Mod browser: details before install

**Verdict: front end. `getmods` already returns enough.**

Per result: `id`, `title`, `description`, `authorid`, `filesize`,
`tags`, `version`, `childcount`, `steamresult`, `thumbnailurl`.

So a detail view showing id, size, description and tags needs no new
data. Two caveats:

- **`authorid` is a number, not a name.** Resolving it to a display name
  means a Steam Web API call, which is an external request the panel is
  not allowed to make (see [CONSTRAINTS.md](CONSTRAINTS.md#no-cdn)).
  Show the raw author id, or link out to the profile and let the browser
  do it.
- **`thumbnailurl` points at Steam's CDN.** Same rule. Either do not show
  thumbnails, or make it an explicit opt-in in settings (item 9) that is
  off by default, so an isolated server never reaches out on its own.
  Measured on the shipped panel: 49 thumbnails, 4.55 MB, on a page load
  where the Mods tab was never opened -- `modbrowser.js:149` searches
  from `$(document).ready`. **The replacement must not search until the
  Mods tab is actually shown.** See
  [CURRENT-UI.md](CURRENT-UI.md#two-more-neither-of-them-visible-by-reading-the-files)
  defect 13.

The click-through flow is the right shape regardless: the current browser
shows a wall of similarly-named results with a subscribe toggle and no
way to tell them apart.

### Built *(2026-09-27)*

A **Workshop** tab of its own, next to Mods: finding and downloading a mod
is separate from loading one, which is a cycle edit and stays on the Mods
tab with its rules (by decision). The tab searches only once it is
opened, lists the results with size and date, opens a row into its
details (the description as text, BBCode stripped; hex and decimal ids;
the author's raw SteamID64 linked to the profile; tags; required items;
Steam's per-item problem flag), and installs after a confirmation that
says it only downloads, cannot be undone, and that loading a mod that is
not whitelisted turns ranking off (since 2026-10-08, whether this one is:
each result is marked whitelisted or not, CONSTRAINTS item 17). A download
shows as such until the installed list has the id, then as installed,
with **Open in Mods**, which opens that tab filtered to it. Thumbnails are
behind `modThumbnails`, off by default, switched in Settings.

The engine returns only the first 50 hits, so the tab says to find the
mod on the Steam Workshop and search for its title, with a link there.
The title is what works *(measured 2026-10-07)*: searching by the decimal
workshop id (3558697165) finds nothing, and the hex id (d41d68cd) returns
50 unrelated mods.

**Measured on the rig first** *(09-26 hotfix, stock config; probe
`tools/spikes/workshop-branch.lua`, and the rig booted without a network
in a user namespace, `unshare -rn`, for the failure case)*:

| Question | Answer |
| --- | --- |
| What does the `SearchWorshop` callback get? | **One table** of up to 50 items, ids as numbers (`%x` formats those above 2^31 correctly). No total: the engine logs `numMatching = 2874` for an empty search but does not hand it to Lua. |
| Paging? | **None.** Pages 1, 2, 3 and 500 of one search, and 0, were the same 50 items. The 2012 panel's Next and Previous re-show the same page (CURRENT-UI defect 15). A narrower search is the only way to reach the rest. Results are ordered by relevance: `combat fix` puts Combat Fix first. |
| An empty result? | An empty table, which vanilla encodes as **`{"items":[]}`**. The spec had said `{}`, read from the source; dkjson writes an empty table as `[]`. |
| A failed search? | **Indistinguishable from an empty one.** Offline, Steam logged `Failed Steam error NoConnection` and the callback got an empty table, in the same frame. Nothing in `Server` or `Shared` reports Steam connectivity (probe `do=functions`). So an empty result is reported as "no matches, or the server could not reach Steam". |
| How long does a search take? | 0.3-0.9 s online. |
| Missing `searchtext`, `p=abc`? | Vanilla: no search is ever started (`loading` forever), and a Lua error (`attempt to concatenate local 'page'`), an empty 200. The overload is strict: `SearchWorshop(string, number, function)`. |
| A 3000-character query? | `401`: the Digest exchange fails on a URI that long. The tab caps the box at 200. |
| What does `InstallMod` return? | **Nothing**, whatever the id. `zz`, `0` and an empty id leave no trace; `-5` became mod 18446744073709551611, which Steam reported as not found. |
| When is a download visible? | **Once downloaded and unpacked, under its real title, never before**: 1.7 s for a 710-byte mod, 3.8 s for 26 MB, polled every 0.25 s. An id Steam does not have never appears. Nothing about a download reaches `Shared.Message`, so `getconsole` shows none of it. |
| Installing while a map is running? | Works. Re-installing an installed mod checks it and downloads nothing when current; for a mounted mod the engine logs `Canceling mod ... download attempt because game is active`. |

What the mod's Lua does with that (CONSTRAINTS item 2): `getmods` keeps
`loading` and `items` for the 2012 panel and adds `elapsed`, `done`,
`page`, `count`, `capped` and, for a search that had no answer after
30 s, `error` -- once, instead of restarting silently. A missing
`searchtext` searches for everything, `p` is read safely, and the cache
key keeps `a` page 11 apart from `a1` page 1. `installmod` refuses what is
not a hex id before the engine sees it and answers `{ok, id,
already_installed}`. Harness `tools/spikes/workshop-harness.lua`, 39 of
39.

Then **driven through the panel on the rig**: the tab searched only when
opened, `crosshair` found Green Crosshair (High Visibility), its details
opened, Install asked first, the row read "Downloading" and then
"installed" two seconds later. Open in Mods showed that one row; Load with
every map wrote it to `MapCycle.json`, and after `sv_changemap` the log
showed `Mounting mod 'Green Crosshair (High Visibility)'` and the row read
"loaded now". Nothing was requested from anywhere but the server. Rig
restored afterwards, the four test downloads removed along with their
entries in `appworkshop_4920.acf`.

## 5. RCON returns nothing

**Verdict: our Lua, and the mechanism is now settled.** The evidence for
the defect is in [API.md](API.md#demonstrated-not-argued-verified) -- a failed kick
and a successful kick are byte-identical over HTTP.

### Mechanism, answered *(spike 2026-09-05)*

`ServerAdminPrint` is defined at **`core/lua/ServerAdmin.lua:156`**. The
earlier search missed it because it only covered `ns2/lua/`; the
definition is in the *core* tree. Confirmed on a live server with
`debug.getinfo`, which reports `lua/ServerAdmin.lua:156`.

It is a plain Lua global inside `if Server then`, and **no caller takes a
local alias of it**, so a wrapper installed from our
`ServerWebInterface.lua` is seen by all 36 call sites. For a web request
`client` is nil, so the network-message branch is skipped and the
function falls through to `Shared.Message` -- into `log-Server.txt`,
where HTTP cannot reach it. That is the whole defect.

Probe: `tools/spikes/console-output-probe.lua`, mounted as a mod on the
local rig.

| Question | Answer |
| --- | --- |
| Is `ServerAdminPrint` wrappable? | Yes -- a plain global, wrapped successfully |
| Are `Shared.Message`, `Print`, `Log` writable? | Yes, all three |
| Is the `debug` library available? | Yes |
| Is `Shared.ConsoleCommand` synchronous? | **Yes.** The output is already captured when it returns |

Captured, running commands the way the panel runs them:

| Command | What came back |
| --- | --- |
| `sv_kick NoSuchPlayerHere` | `No matching player` -- the string the panel has never seen |
| `sv_unban 123456789` | `No matching Steam Id in ban list: 123456789` |
| `sv_reserved_slots 3` | `Reserved slot amount set to 3`, through `Shared.Message` **only** |
| `sv_cheats 1` | Nothing but the audit line. It worked |
| `sv_help` | 37 commands, 8.6 KB of JSON |
| `sv_nonsense_command` | Nothing at all, not even in the log |
| `killall` (not an admin command) | Nothing |

Five consequences for the design:

1. **Wrap both `ServerAdminPrint` and `Shared.Message`, and dedupe.**
   `sv_reserved_slots` reports success through `Shared.Message` alone, so
   wrapping `ServerAdminPrint` by itself misses it. But
   `ServerAdminPrint` *calls* `Shared.Message`, so every admin message
   arrives twice -- `sv_help` produced 74 lines for 37 commands. Suppress
   the nested call with a flag.
2. **The audit line is a dispatch receipt.** Every command created by
   `CreateServerAdminCommand` emits
   `sv - <name> - <id>: : <steamid>: <command>` *before* running
   (`core/lua/ServerAdmin.lua:113`, read from the source rather than
   inferred from samples). Its presence proves the command existed and
   ran; its absence means either an `Event.Hook`-style command such as
   `sv_help` or `killall`, or nothing at all.
3. **Web requests bypass the permission check.** `not client`
   short-circuits `GetClientCanRunCommand`, so every admin command is
   allowed. Authentication is the digest layer's job and stays there.
4. **Silence is ambiguous, and must be shown as such.** `sv_cheats 1`
   succeeded silently, `sv_nonsense_command` failed silently, and neither
   wrote anything anywhere. "No output" is not success. A known-command
   list can be built by parsing `sv_help` once, since
   `allServerAdminCommands` is a local and not reachable directly.
5. **Capture covers the synchronous call only.** Anything printed after
   `Shared.ConsoleCommand` returns -- an async effect, another admin, an
   engine-side message -- needs a ring buffer, which is also item 7's log
   tail. One buffer serves both.

The panel must never again show a refresh that implies success it did not
verify.

## 6. Ban from a list of recent players

**Verdict: our Lua, straightforward.**

`Event.Hook("ClientDisconnect", fn)` and `ClientDisconnected` both exist,
as do `Server.GetOwner` and `Server.GetClientById`. A ring buffer of
recent players -- name, SteamID, last seen, time played -- maintained in
our `ServerWebInterface.lua` and exposed as a new request type is
ordinary work.

Design notes:

- It holds names, SteamIDs and probably IPs, so it inherits the masking
  rules in item 9 and the privacy note in [API.md](API.md#privacy).
- Size it deliberately and say so in the UI. "Recent" should mean a
  stated number of players or a stated window, not an unbounded list that
  grows until the map changes.
- Searchable by name and by SteamID. Partial name match is the common
  case -- an admin remembers roughly who it was.
- **It must survive a map change, and need not survive a restart**
  *(decided 2026-09-05)*. That decision has teeth, because a map change
  is not the cheap case: `uptime` is `math.floor(Shared.GetTime())` and
  it reads **11 seconds** in `fixtures/serverstate-after-mapchange.json`
  against a server that had been up far longer. Shared time restarts with
  the map, so the Lua state is rebuilt per map and **an in-memory ring
  buffer is wiped by precisely the event the buffer is meant to survive**.

  So the buffer has to be written to `config://` and read back on load,
  with a `last seen` timestamp per entry and a window that ages entries
  out. It will then also survive a restart, which is more than was asked
  for and acceptable -- persistence across restarts was declared
  unnecessary, not unwanted. Distinguishing a restart from a map change
  would need a boot marker the engine does not offer, and buying that
  distinction is not worth a heuristic on the gap between writes.

  **Answered: mod Lua can write under `config://`** *(measured on 09-26,
  2026-09-27; probe `tools/spikes/engine0926-branch.lua`)*. What the file
  format has to live with:

  | Operation | Result |
  | --- | --- |
  | `io.open("config://x.txt", "w")`, write, close, read back | Works; the file lands in the `-config_path` directory |
  | `.json` extension | Works |
  | A 100 KB write | Works, reads back 102,400 bytes |
  | `config://improved-webadmin/probe.txt`, directory absent | **Works -- the directory is created** |
  | Any path without `config://` | Raises `writing to the game directory is not allowed` |
  | Mode `"a"` (append) | **Truncates, like `"w"`.** Write `line1`, append `line2`, read back: only `line2` |
  | `os.rename`, `os.remove` | **Absent** (`nil`) |

  So the file is **rewritten whole** on every save, never appended to,
  and there is no write-then-rename: a crash mid-write can leave it torn,
  and nothing can delete it. The loader must treat an unparsable file as
  empty rather than fail. A subdirectory, `config://improved-webadmin/`,
  keeps the mod's files together.

### Built *(2026-09-27)*

**Sized at 24 hours and at most 100 players**, by decision. The
server reports both numbers and the tab states them. A connected player
is never aged out.

- **Two slots stand in for write-then-rename.** Saves alternate between
  `config://improved-webadmin/recent-players-a.json` and `-b.json`, each
  stamped with an increasing `seq`. The loader reads both, decodes each
  under `pcall`, and takes the newest that parses. A torn write costs one
  save, not the list, and the next save overwrites the torn slot. The load
  reports `ok`, `fallback` (newest torn, older used), `empty` (no file
  yet) or `unreadable` (both torn: start empty, do not fail). A failing
  save is reported with its error. The tab shows each of these rather than
  going quietly empty.
- **What is kept per player:** Steam id, name, up to 5 former names
  (partial-name search covers them), IP, first and last seen, and time
  played. Bots are skipped. All times are `Shared.GetSystemTime()`,
  because `Shared.GetTime()` restarts with the map.
- **When it is written:** on the tick after any disconnect, so a mass
  disconnect costs one write, and otherwise at most once a minute while
  anything changed. A 10 s sweep over the players picks up names, IPs,
  time played and `last_seen`. So a map change loses at most a minute of
  `last_seen` and of time played for players who were connected, and
  nothing else. Measured: played read 173 s before a map change and
  172 s after it, because the last save had been the disconnect 51 s
  earlier. The load itself is not counted as play.
- **It does not depend on `ClientDisconnect` firing at a map change.** A
  disconnect only stamps a time, and `connected` is read off the live
  player list at request time, so a map change never reads as everyone
  leaving.
- **IPs are kept, and shown unmasked** in the Recent players tab, by
  design: spotting a returning player under a second account is what
  they are for. Steam ids stay masked. The file on disk holds the
  IPs too; see [API.md](API.md#privacy).

Exercised in a LuaJIT harness that stubs the engine calls and runs the
shipped file (`tools/spikes/recent-players-harness.lua`): 21
checks covering rename history, bots, a map change (a fresh VM over the
same files), a torn newest slot, both slots torn, capacity, and the
window.

**Measured on the rig** *(09-26 hotfix, 2026-09-27, one human
connected; probe `tools/spikes/make-recent-players-probe.sh`)*:

| Question | Answer |
| --- | --- |
| 1. At a map change, does `ClientDisconnect` fire, and `ClientConnect` again after? | **No disconnect at all.** The new map's file loaded with no `ClientDisconnect` before it. `ClientConnect` fired again 18 s after the load, logged as `Client connected` with no `Client connecting`. Deriving `connected` live was the right call: a map change never passes through "left". |
| 2. Inside `ClientConnect`, what is usable? | `GetUserId`, `Server.GetClientAddress` and `GetControllingPlayer` all are. **The name is still the `NSPlayer` placeholder**, on a first join and on every rejoin; the real one appeared by the next sweep. The code ignores the placeholder, as designed. |
| 3. `json.decode` on truncated input | **Returns `nil`**, then a position and `unterminated object at line 1, column 1`. It does not throw; the `pcall` stays as a guard. |
| 4. `config://` readable at file load? | **Yes**: a handle on the second map's load, `nil` on the very first boot only because no file existed yet. `io.open(..., "w")` created `config://improved-webadmin/` itself. |
| 5. What does a save cost? | **0.08 to 0.42 ms** for a one-player file of 191 bytes, timed with `Shared.GetSystemTimeReal`. A full 100-player file (~17 KB) was not measured; nothing suggests it is more than a few times that. |

Also seen end to end: a rename recorded the old name as a former one; a
disconnect was saved on the next tick; a rejoin kept `first_seen` and
the former name, and time played left out the 22 s spent away; saves
alternated `a`, `b`, `a`. For the torn case the server was stopped, the
newest slot (`a`, seq 5) cut in half, and the server booted: the load
reported `fallback` and served slot `b` (seq 4) intact. That response is
committed, redacted, as `fixtures/getrecentplayers-rig.json`. The
synthetic `getrecentplayers.json` stays as the mock's seed, since the
gate needs more than one player.

### Real names on offline bans *(built 2026-09-27, Shine only)*

A ban of a player who is not connected used to be stored with no name:
`<unknown>` under Shine's `sh_banid`, `Unknown` under vanilla `sv_ban`.
**Under Shine's ban plugin the mod now records the name this list last
saw.** Shine's `BanID` hands `"<unknown>"` to `Plugin:AddBan`, a public
method, and every consumer of the ban takes its name from there: Shine's
table, the vanilla file it syncs, its net data and the `OnPlayerBanned`
hook. The mod wraps `AddBan` (re-applied each tick, since Shine loads
later and can re-create a plugin) and substitutes the name. Shine's own
line still prints `<unknown>`, because it prints a local, so the mod adds
one saying what it stored: `Named the ban of <id> "<name>", from recent
players.` An id not in the list is left as it was.

**Vanilla keeps `Unknown`, by decision.** Its ban table and
`SaveBannedPlayers` are file-local in `ServerAdminCommands.lua`, so the
only way in is `debug.getupvalue` on the original `UnbanUser`, by
variable name. That is possible but was declined as too tied to the
game's internals.

**Verified on the rig** with a Shine config: the recent list
seeded by hand with one fake player (no human needed), then
`sh_banid` of that id and of one not in the list. The first was stored
as the seeded name in Shine's `Bans.json`, in the synced
`BannedPlayers.json` and in `getbans`; the second stayed `<unknown>`
with no line from the mod. Both were unbanned and the config restored
byte for byte.

## 7. Tail the server log

**Verdict: both routes work, and the mod should carry both.** Route 1 is
now tested and gives a real tail of the engine's own log; route 2 needs
no configuration and is the fallback when route 1 is not available.

Reading the log directly still fails the way it did:

```
io.open("/srv/ns2/config/log-Server.txt")        -> nil   (absolute, refused)
io.open("log-Server.txt")                        -> nil   (not a mounted root)
io.open("config://logs/log-Server.txt")          -> nil   (not that path)
```

### Route 1 works, with a layout constraint *(spike 2026-09-05)*

Start the server with **`-logdir` set to the same directory as
`-config_path`** and the log lands inside a mounted root:

```
io.open("config://log-Server.txt")   -> handle, 6690 bytes
io.open("config://MapCycle.json")    -> handle           (control)
```

Probe: `tools/spikes/logdir-probe.lua`.

| Question | Answer |
| --- | --- |
| Does `config://log-Server.txt` open? | Yes, once `-logdir` is the config path |
| Can it seek to an arbitrary offset? | Yes -- read from byte 7453 returned the 3 lines after it |
| Is what it reads **fresh**? | **Yes.** `sv_say logdir_spike_marker_A` run inside one web request appeared in the tail read later in that same request |
| What does polling cost when nothing happens? | Nothing -- the file did not grow at all over 20 s idle |

Freshness is the finding that matters. A tail that lags behind a write
buffer would be a log viewer, not a log tail; this one is neither
buffered nor delayed, so `since=<byte offset>` is the right shape for the
request type and a poll on an idle server transfers zero bytes.

**What route 1 costs:**

- It dictates how an operator lays out their server. Anyone mounting the
  mod without that flag gets nothing from it, so the panel must detect
  the absence and say so rather than showing an empty log.
- The engine also puts `dumps/` in whatever directory `-logdir` names, so
  the config directory gains a subdirectory it did not have.
- **The log is not sanitised.** Chat lines are recorded verbatim
  (`Chat All - Admin: logdir_spike_marker_A`) and admin commands carry
  the SteamID of whoever ran them. Serving it through the panel
  republishes all of that over plain HTTP. **Shown unmasked, by design**
  *(2026-09-28)*: the log is the server's own record, not a view built
  for display; see [API.md](API.md#privacy). On a Shine server on a quiet
  morning *(2026-09-27)*, the lines carrying personal data were `Client
  connecting (<IP>)`, `Client connected (<IP>)` and `Client disconnected
  (<IP>) Quit` -- IP and port, with no name or SteamID. No SteamID
  appeared anywhere; every long number was a mod id. No chat lines
  either, in either file (Shine keeps its own logs). **A populated round
  carries far more**: chat, `steam user <SteamID64>`, `name[<account id>]
  ran command ...`, `Client Authed. Steam ID: <account id>`, names on
  connect, rename and kill lines, and IP:port.
- Rotation exists: `log-Server.old.txt` sits beside the live file, so a
  client's byte offset can go backwards. Treat a shrinking file as a
  rotation and restart the cursor. ~~The `clearconsole` command (09-03
  and later) also cuts the log back to its header.~~ **Not on the server**
  *(measured 2026-09-28)*: through the web admin and through the FIFO it
  leaves `log-Server.txt` alone, and the FIFO echoes it the way it echoes
  an unknown command. The changelog's `log.txt` is the client's.
- **Re-checked on 09-26** *(2026-09-27)*, since 09-25 changed file
  reading for mods: `seek("end")`, `seek("set", n)`, `read("*a")` and
  `seek("cur", -16)` then `read(16)` all behave as in standard Lua.
  `read(0)` returns `""` mid-file and `nil` at the end.

### Route 2 stays, as the fallback

Our own buffer, fed by the wrappers from item 5, needs no configuration
and works on anyone's server. It sees everything that passes through
`ServerAdminPrint`, `Shared.Message`, `Print` and `Log` -- which is most
admin output, but not what the engine writes directly (`Script tracing`,
map load errors, the boot banner).

So the two are complementary rather than alternatives: route 1 is the
truth and route 2 is what is always available. Ship both, prefer route 1
when `config://log-Server.txt` opens, and name which one is in use.

### Built *(2026-09-28)*

**Measured first**, on the rig (09-26 hotfix, `-logdir` equal to
`-config_path`; probe `tools/spikes/log-branch.lua`, built by
`make-log-probe.sh`):

| Question | Answer |
| --- | --- |
| The largest reply the engine serves | No limit met: 64 KB, 256 KB, 1 MB, 4 MB and 16 MB all `200` and parsed (16 MB in 0.24 s). The cap is the mod's: **64 KB** for a tail or a page back, and for one read forward since 2026-10-08 (it was 256 KB, which cost 4.4 ms to encode; SERVER-COST.md). |
| Invalid UTF-8 and control bytes | The log keeps the bytes as written. `json.encode` (dkjson 2.5) escapes control characters and passes invalid UTF-8 through raw; a browser decodes it to U+FFFD. |
| What a restart does | The old file becomes `log-Server.old.txt` and the new one has a new `Date:`/`Time:` header (to the second). A map change does nothing to the file. |
| What `clearconsole` does | Nothing to the server's log (above). |
| Can a read end mid-line? | Not seen: 5404 reads over 30 s while `sv_help` ran back to back, every one ending in `\n`. Whole lines only anyway, since a force-stopped server's log ends mid-line. |
| What a read costs | 0.2-0.3 ms for 64 KB, 0.7 ms for 256 KB, 3 ms for 1 MB, lines counted; 0.005 ms to open and find the size. |

Two more turned up while building, both on the rig:

- **A stale copy passes for the live log.** Booted with `-logdir`
  elsewhere, `config://log-Server.txt` still opened: the file an earlier
  `-logdir config` run had left, frozen. So the first `getlog` of each map
  load prints a line and looks for it in the file (CONSTRAINTS item 15),
  and answers `stale` when it is not there.
- **A handle sees the file as it was when it was opened.** The check's
  own line, printed after `getlog` had opened its handle, was not in that
  read. The check now prints before the open, and the harness's fake
  `io.open` serves a snapshot, so it fails on the wrong order.

`getlog` ([API.md](API.md#the-server-log-with-the-mod-measured-2026-09-28)):
the tail, `since` a byte offset, `before` one to page back, each line with
its offset, whole lines only, and `reset` when a restart or a cut leaves
the cursor pointing at the wrong file. Its harness,
`tools/spikes/log-harness.lua` (43 checks), writes the file the way the
engine does and covers the partial line, the cap, paging back, CRLF, odd
bytes, a 300 KB line, a cut, a new header, the live check and a stale
copy.

The log tab, since 2026-10-08 the **Console** tab with the command line
under it: the tail when opened, Load earlier back to the start of
the file, a poll with the byte cursor (its own refresh in Settings,
default 2 s, only while the tab is open), filters by kind with counts
(chat, connections, admin commands, errors and warnings, engine, other),
search, following the end only when the reader is there, and a banner for
a restart, a cut file, or a tab that was away while more than 1 MB was
written (it skips to the end instead of replaying it). Lines verbatim, no
invented timestamps. When the log cannot be read it says why (layout, or
a stale copy), and the command line still works, since `runcommand`
returns a command's output whatever the log. On a stock server it
explains itself and never asks.

Since 2026-10-07 each kind has its colour (errors red, warnings orange,
chat magenta, admin commands yellow, connections teal, with times and the
thread in theirs), each with a dark and a light value at 4.5:1 or better.
Chat is in the speaker's team colour. The server writes no team into its
chat lines (`Chat All - name:`, `Chat Team - name:`), so the speaker is
looked up in the player list when the line is first shown. Shine's
improvedchat logs team chat as `Chat Team - name:` with no number, which
counts as chat. Engine and Other lines are hidden at first, and the
filters are kept in the browser. Save writes every line read, hidden kinds
too, to `log-Server-<time>.txt`; fetching the whole file was not done,
since it can be megabytes read in 64 KB replies.

**On the rig** with the built mod: the tail and a full page-back equal
the file on disk byte for byte; an idle poll read nothing; an `sv_say`
arrived as its dispatch line then its chat line; a map change kept the
cursor (no reset, the new map's loading lines next); a restart answered
`new_file` with the new file's tail; `-logdir` elsewhere answered `No
such file or directory`, or `stale` while a copy was left in the config
directory. In Chrome, the tab showed the file from its first line and a
command's line within a poll, with no exceptions. Fixtures:
`getlog-rig-tail.json`, `-since`, `-reset`, `-stale`, `getlog-none.json`.

**The default layout qualifies** *(2026-10-08, the Workshop item on the
09-27 engine)*: with neither `-config_path` nor `-logdir`, the engine
writes the config files and `log-Server.txt` to the same directory
(`$XDG_CONFIG_HOME/Natural Selection 2/`, else
`~/.config/Natural Selection 2/`). `getlog` served the whole file
(`source: file`, 185 lines, the marker found, not `stale`), a `sv_say`
arrived on the next read, and `getperf` read `tickstat` lines from it.

Not yet seen: a populated round's log through the tab.

## 8. Light, fast, dark, full width

Design constraints, and they are already partly in the README's
[Design decisions](../README.md#design-decisions) -- small, vendored, no
CDN. Adding:

- **Dark by default.** Light stays available, but the panel is an
  operator tool most often opened at night next to a game.
- **Full width.** The current panel is a fixed centred Bootstrap 2
  container that wastes most of a wide screen on a page whose main
  content is a wide table.
- **Fast means fast on the wire too.** The server is plain HTTP on a
  possibly distant box, replies are `Cache-Control: no-store`, and the
  panel polls. Payload size per poll matters as much as render time.
- No layout shift while polling. The current panel rebuilds tables in
  place and loses scroll position and sort order.

## 9. Per-admin settings, saved in the browser

**Verdict: front end only.** `localStorage`, no server round trip, no new
request type.

At least:

- **Masking on or off** for IPs and SteamIDs, and whether a reveal is
  per-row or sticky. Default on -- see [API.md](API.md#privacy).
- **Auto-refresh interval**, including off. Different tabs want different
  rates; the player list and the performance graph are not the same job.
- **Theme**, if it is not purely following the system.
- **Thumbnails in the mod browser**, default off, because turning them on
  means the browser talks to Steam's CDN (item 4).

Settings are per-browser, not per-account -- the panel has no user model
beyond HTTP Digest. Say so in the UI rather than implying they follow the
admin around.

### Built *(2026-09-28)*

A **Settings** tab, the last one, which renders without server data so
refresh can be turned off while the server cannot be reached. The tabs'
own toggles (the mask checkbox) and the footer's refresh and theme stay
as shortcuts to the same values; Workshop thumbnails are switched here
only. What it holds:

| Setting | What it is |
| --- | --- |
| Mask Steam ids and IPs | One switch, on by default. A reveal stays per row, until the tab is left; no sticky option. Recent players shows IPs regardless (item 6). |
| Refresh | Three knobs, each 1/2/5/10 s or off: server state (the header, Players), Chat, and the Console's log. The fixed rates -- lists 10 s, maps and mods 60 s, Performance per server window, a Workshop search 0.5 s -- are stated from the stores' own constants. A knob turned off says so on its tab and offers Read now. |
| Theme | Dark (default), light, or as the system is -- following the OS live. |
| Times | As the browser writes them (default), 24-hour, or UTC. Applies to the footer, dates, the console (always 24-hour) and the perf time axis, which had been uPlot's 12-hour am/pm in every locale. |
| Workshop thumbnails | Off by default, with what turning them on costs. |
| Remembered | The last tab (reopened, on by default), Players' Hide bots, the Console's filters. |
| tickstat | The server's `tickstat`, on or off (item 10). |

Along the way:

- **"System" had never worked.** The page was told `data-theme=""`, and
  the stylesheet has no `prefers-color-scheme` rule, so it was dark
  whatever the OS said. The store now resolves the theme and sets the
  page's to `dark` or `light`, before the first render and on every
  change of the setting or of the OS.
- **Stored values are checked field by field.** A wrong type or an
  unknown value falls back to its default and the rest are kept; junk
  gives the defaults. Settings saved by an older build keep their console
  rate, which used to be the one refresh.
- **A browser that refuses storage** (a private window, blocked site
  data, or a `localStorage` that throws) still applies every change for
  the session, and the tab says they will be forgotten.
- **Two open tabs agree**: a change in one reaches the other through the
  `storage` event.
- Storage is per origin, so the tab says settings belong to this browser
  **and this address**: two servers keep separate ones.

Gate: `tools/browser-checks/spa-settings.py`, 54 of 54.

## 10. Performance: what perfmon logs, drawn *(measured 2026-09-27)*

The 2012 tab charts vanilla `getperfdata`: one reading a minute of
`Server.GetFrameRate()`, the player count and the entity count, the last
30 of them, lost at every map change -- and the tab re-appended the whole
window on every poll (CURRENT-UI defect 2). An operator who wants to know
how the server is really doing reads `perfmon` off the server console
instead.

**Verdict: our Lua and the panel.** `perfmon` is Lua
(`lua/ServerPerformanceData.lua`) over one engine object,
`Shared.GetServerPerformanceData()`, which mod Lua can read too. Measured
on the rig (09-26 hotfix, empty server, 30 and then 60 tick) with
`tools/spikes/perf-probe.lua`:

| Question | Answer |
| --- | --- |
| How often is there a new sample? | Every **1.00 s**; `GetDurationMs()` 1000-1005. 30 `UpdateServer` calls apart at tickrate 30, 60 at 60: **`UpdateServer` runs once per tick.** |
| Do `ServerPerformanceData()`, `Accumulate`, `Copy`, `Clear` work from mod Lua? | Yes. `GetIncompleteCount` exists; `GetTimeOverdraft`, in the docs block, does **not**. |
| **Is any of it dangerous?** | **Yes. `Accumulate()` of a sample whose `GetDurationMs()` is 0 kills the server with SIGFPE** -- `pcall` does not catch it; the process is gone. The engine's first sample after every map load is empty. Vanilla only accumulates when the duration is above 0; so must we. Found by crashing the rig three times, bisected by logging each call. |
| Getters on an empty sample? | All return 0, safely. |
| Is the engine's tickrate usable? | Not at 60 and up: `GetUpdateIntervalMs()` is whole milliseconds, 16 at tickrate 60, which reads **62.5** -- the `tick 62.5` in a 60-tick server's `Perf` lines is this rounding, not a real overshoot. Counting `UpdateServer` calls per window gives 60.0. |
| Which clock times a tick? | `Shared.GetTime()` and `Shared.GetSystemTimeReal()` agree to 0.1 ms per tick. The mod uses the real one. |
| Do the configured rates follow a runtime change? | **Yes, at once.** `tickrate 60`, `sendrate 40`, `moverate 40`, `interp 0.085` through `runcommand` showed in `GetTickrate()` etc. on the next sample. So the rates are read per request, and moverate is visible without `perfmon`. |
| Score and quality with nobody on? | Both **0**, and `DetailText` refuses to describe such a sample. The panel shows "no players", not a score. |
| `collectgarbage("count")`? | Works: about 20 MB on an empty rig. |
| `/proc/self/status`? | `io.open` returns nil, no error: not readable. Process CPU and RSS stay out of reach. |

**Built** *(2026-09-27)*: `getperf`, 10 s windows of the engine's data
plus the counted tickrate and the slowest tick, an hour kept since the
map load, read with a `since` cursor. Its harness is
`tools/spikes/perf-harness.lua` (31 checks, with a fake engine whose
`Accumulate` fails where the real one crashes). On the rig: 30.0 then
60.0 counted, the window across the change 56.1, a map change moving
`loaded_at` and restarting the ids, and the tab drawing all of it.
**With people playing** *(2026-09-28: one human and 11 bots, `perfmon`
detailed alongside)*. Three 10 s windows against the matching 30 s
`Perf` line, at 30 tick: idle 85.2 against 85.1 %, entities 14.2 against
14.3 %, 26 moves a second at 0.10 ms either way, score 80-86 against 80.
At 60/60/60, interp 85: counted tickrate 59.99-60.01 in every window,
where every `Perf` line printed `tick 62.5`; slowest tick about 20 ms,
down from 38 at 30 tick. Across a map change with the tab open, the page
kept all 43 windows of the first map, marked the change and took the new
map's from id 1 as the player reconnected. Fixture:
`getperf-rig-populated.json`.

**`perfmon` hides interp fails.** `DetailText` prints warns and fails per
second with `%d`, so anything under one a second prints as 0. Four
windows counted fails (2, 1, 1, 1: the joins and a rate change) while
every `Perf` line over them read `iFail 0`. `getperf` reports the counts,
and the tab flags any fail -- as "past interp", not as a verdict, since
one-offs at a join or a map load are normal. So a server's "`iFail 0`
throughout" means under one a second, not none.

Not reachable from Lua: the engine's own `perfmon:` block and the 09-27
`tickstat` lines are printed by the engine to the log, not through Lua.
The log tail (item 7) reaches them; drawing them is the next part.

### The engine's log lines *(measured 2026-09-28, 09-27 engine)*

Measured on the rig (`Build: 344 (5dc97682bc beta)`), empty at 30/20 and
then at 80/40/40, interp 85, bwlimit 131072, with one human and
11 bots, with `tools/spikes/tickstat-branch.lua`
(`make-tickstat-probe.sh`) and a console FIFO. The real lines, in order,
are in `tools/spikes/tickstat-rig-20260928.txt`.

| Question | Answer |
| --- | --- |
| What does a `tickstat` line look like in `log-Server.txt`? | **One bare line, with no prefix and no timestamp**: `TICKSTAT| win 10.0 s hz 80.00 target 80 \| int p50 12.55 p99 14.40 p999 14.55 max 14.55 ms \| … \| snap bytes p50 192 p99 384 max 2737 choked 0.00% \| … \| creations deferred 0`, 16 ` \| `-separated segments, exactly the format string in `server_linux`. The mod stamps a line with the time it reads it. |
| How often, and when? | `tickstat 10` prints every 10.0 s, **even with nobody on**. It replies `tickstat: on`. |
| Can the mod tell whether it is on? | **Yes**: a bare `tickstat` prints `tickstat: on` and does not toggle it. |
| Does it survive a map change? | **Yes.** The window across the load reads `hz 27.99`, `max 664.90 ms`, `late max 632.12 ms`. A restart turns it off. |
| What is a rate step? | `client 1: snapshot rate 40.0 -> 26.7/s (29% choked, 24.9 ms to clear each, bwlimit 10000)`, and back up `26.7 -> 40.0/s (0% choked, …)` within 10 s of restoring `bwlimit`. `client N` is a slot number, not an identity. |
| What does a starved `bwlimit` print? | At the command: `bwlimit 10000 bytes/sec at sendrate 40 leaves 250 bytes per snapshot, below the 2048 a full game needs: snapshots will choke and arrive late. bwlimit 81920 or more avoids it.` Under it: `choked` 0.38–15.75 %, `rate stepped 1 slowest 26.7/s`, `creations deferred` up to 31. |
| Healthy numbers at 80/40/40 with 12 players | `hz 79.99–80.00`, int p99 14.3–14.4 ms, busy 26–30 %, snapshot p99 384–992 B (budget at 131072 / 40: 3276 B), `choked 0.00%`, 40 snapshots and 40 moves a second per human. |
| `Server.GetBwLimit()`? | **Exists** and returns the configured limit (51200 at boot on the rig), and follows a runtime `bwlimit` at once (131072, then 10000). No other new `Server` getter. |
| Is the `perfmon:` block printed on a timer? | **No**: only when `perfmon` is typed, as on 09-07, even with perfmon detailed. It covers **the last second**: `n=80` ticks and `updates 40` at 80/40. |
| Does `perfmon <n>` set a level? | **No: the argument is ignored.** `perfmon 0`, `perfmon 1`, `perfmon 3` and `perfmon off` each step the same cycle as a bare `perfmon` (off → basic → detailed → spam → off), and each prints a block. The handler in `ServerPerformanceData.lua` takes no argument, and its state is file-local. |
| What does a scan cost? | The whole 80 KB log, read and matched line by line, in 0.53 ms. Ten seconds of new log is a few KB. |

The `perfmon:` block with players on (80/40/40):

```
perfmon: tick jitter avg 1.25ms max 2.05ms (n=80)
perfmon: snapshot write avg 0.031ms max 0.064ms (n=40)
perfmon: entities skipped 6438 / 13198 (48.8%)
perfmon: moves rejected: time credit 0, other 0
perfmon: moves rewound with missing snapshots 0 (since map load)
perfmon: score 63 = idle 63.0% - delivery 0.0% - overload 0.0% (updates 40, warn 0, fail 0)
```

This corrects the earlier "one per `perfmon` interval".

**Built** *(2026-09-28)*: the mod scans the log every 2 s and `getperf`
serves the lines under `engine`; the Performance tab draws them.
`tickstat` is switched in Settings *(since 2026-10-07)*, and the switch
controls the server, not this browser: on sends `tickstat 10`, off sends
`tickstat 0`, which stops it for every admin, so it asks first. It
defaults to off, so the panel never turns tickstat on by itself, and it
shows the server's real state, read from the log, since another admin may
already have turned it on. It needs the mod and a readable log, and says
so when either is missing. Found while building it:
`runcommand tickstat 10` returns **no lines** (the engine prints to the log
only), so the tab waits for the scan to find `tickstat: on|off` before it
says either; a bare `tickstat` prints `tickstat: off` when off; and raising
`sendrate` past what bwlimit allows also logs the bwlimit warning. On the
rig with a human and 11 bots, every value served matched the raw line
(819 compared), and the starved-bwlimit run is the fixture
`getperf-rig-tickstat.json`. Harness `tools/spikes/tickstat-harness.lua`,
40 checks.

## Open questions

- ~~Can mod Lua **write** a file under `config://` with `io.open`?~~
  **Yes** (measured on 09-26), with no append, rename or delete. See item 6.

# Constraints, fixes and engine asks

What the engine enforces, what shipping as a mod costs, what the mod's Lua
changes in the stock handler and why, and which engine additions would
simplify it. Code and other docs cite the numbered items (1-18) by number,
so keep the numbers.

Measurements name the engine drop they ran on (09-03, 09-26 hotfix, 09-27,
09-28). "The rig" is the local test server ([TESTING.md](TESTING.md)).

## Engine rules

The 09-03 drop replaced the web server, a 2010 library, and brought these
rules (`CHANGELOG.md` in `ns2-linux-ship-344-26-09-03.zip`):

| Rule | Consequence for the panel |
| --- | --- |
| GET and POST only | `PUT` and `DELETE` are refused `405`, and since 09-26 `HEAD` and `OPTIONS` too. The API uses none of them. |
| A foreign `Origin` is refused `403` | A dev server on another port is locked out; development runs against the mock. See [The Origin rule](#the-origin-rule). |
| Request bodies capped at 64 KB; a malformed `Content-Length` is refused | Only `setmapcycle` posts a body. A 40-map modded cycle is 822 bytes. |
| The login challenge is single-use and expires in 5 minutes | Not a problem: the browser re-authenticates silently ([API.md](API.md#authentication)). |
| 10 failed logins per address per minute lock that address out for a minute | Back off on `401`. Behind a proxy every admin shares the proxy's address. |
| Requests give up after 30 s with `503` | Treat `503` as busy and retry. |
| Replies send no-cache, `nosniff` and no-framing headers | No cache-busting needed. The panel cannot be framed. |
| Refusals return a complete response | Errors are readable instead of hanging. |
| Still plain HTTP | Nothing that needs a secure context (no service worker). Securing a server: [SECURITY.md](SECURITY.md). |

The web admin refuses to start unless it is bound to localhost or has a
login (`-webuser`/`-webpassword` or `-webusers`), `-webreqip` or
`-webtoken`.

### The Origin rule

`Origin` is compared with the request's `Host` header, not with
`-webdomain`, and only the host part is compared. Measured on 09-03 and
again on 09-26:

| Request | Result |
| --- | --- |
| No `Origin` header | `200` |
| `Origin` matching the host | `200` |
| `Origin` matching the host, other scheme (`https://127.0.0.1:8080`) | `200` |
| `Origin: http://localhost:5173` | `403` |
| `Origin: https://evil.example` | `403` |
| `Origin: null` | `403` |
| `PUT` / `DELETE` / `HEAD` / `OPTIONS` | `405` |

Refusals are logged as `WebAdmin - rejected request from <address> (origin
does not match host)`, but repeated refusals are collapsed (on 09-26, four
refusals gave two lines), which matters for fail2ban.

A request with no `Origin` passes, so a proxy that sends none works.
`Origin: null` is refused, so the panel cannot run in a sandboxed iframe or
from a `file://` page.

### The Host rule without a login

With no `-webuser`/`-webpassword`/`-webusers`, the 09-25 drop and later
refuse any `Host` that is neither `localhost` nor an IP literal, for
static files as well as the API. With a login configured, `Host` is not
checked. Measured on 09-26, bound to `127.0.0.1:8080`:

| `Host` | Result |
| --- | --- |
| `127.0.0.1:8080`, `localhost`, `localhost:8080`, `LOCALHOST:8080`, `[::1]:8080` | `200` |
| `10.1.2.3` (any IP literal, not only loopback) | `200` |
| none | `200` |
| `adm.example`, `localhost.example`, with or without a matching `Origin`, for `/` and `/index.html` | `403` |
| `127.0.0.1:8080` with `Origin: http://127.0.0.1:8080` | `200` |
| `127.0.0.1:8080` with `Origin: https://adm.example` | `403` |

Logged as `... (no users configured and Host is not localhost or an IP
address)`. The mock applies this rule whenever it runs without `--auth`.

## No CDN

The panel is served over plain HTTP, possibly on an isolated network.
Every dependency is vendored into the build, and nothing is fetched from
another host at runtime.

## Shipping as a mod

`Shared.SetWebRoot()` is called from Lua (`ServerWebInterface.lua:25`)
and resolves through the mod filesystem, as does
`lua/ServerWebInterface.lua` itself. Proved on 09-03 with a throwaway mod
mounted from a local directory and named in the cycle's `mods`:

| The mod supplies | Result |
| --- | --- |
| `web/index.html` and `web/marker.txt` | Both served, shadowing `ns2/web/` |
| `lua/ServerWebInterface.lua` with a new request type | `/?request=modmarker` returned `{"from":"mod"}` |
| The same file with item 7's fix | `setreservedslotamount=5` set the amount |

UWE Hotfix 344 ships `lua/NS2Gamerules.lua` the same way, so this is the
supported mechanism.

### What it costs

- **The server loses ranked status** while a mod that is not whitelisted
  is mounted, this one included (item 18 lists the engine's check).
  Accepted until the mod can be whitelisted.
- **Every joining client downloads the mod**: the whole item, 775,191
  bytes (Steam shows 775 KB), of which the minimaps are 367 KB. It is
  fetched once during the connect, then cached. A 09-28 client
  downloaded it in about a second, mounted it and joined without error.
  None of it runs on the client, but nothing marks a mod server-only.
- **The web root merges rather than replaces.** The stock files
  (`/js/rcon.js`, `/css/bootstrap.css`, 860 KB) stay reachable at their
  old paths; nothing links to them.
- No consistency risk: `ServerWebInterface.lua` is loaded only from
  `Server.lua:35`, on the server.

### Mounted from the Workshop

The published item (3816039702, unlisted) mounted as an operator would
mount it: `e3742516` in `MapCycle.json`'s `mods`, on the rig with the 09-27
engine.

| Tested | Result |
| --- | --- |
| A dedicated server fetching an unlisted item | Works: `Queuing download of NS2 Improved Web Admin[3816039702]`, then `Mounting mod ... from <modstorage>/content/4920/3816039702/` |
| What it downloaded | Byte-identical to `build/workshop/content/`: `web/`, `lua/`, `LICENSE` |
| `lua/ServerWebInterface.lua` | Shadows the game's: `mod_version: "0.1.0"`, and `runcommand` returns `No matching player` for a kick that matched nobody |
| `web/` | `index.html` and the other 22 files `200`, byte-identical |
| The mod's data folder | `config://improved-webadmin/whitelist.json` written (116 ids) |
| `getinstalledmodslist` | The item listed `active`, as `e3742516` |
| Ranking | `Mod NS2 Improved Web Admin[3816039702] is not whitelisted`, `Ranking disabled`, `ranking_active: false` |

- A new item stays hidden, whatever its visibility, until the uploading
  account accepts the Steam Workshop legal agreement. Steam's anonymous
  `GetPublishedFileDetails` answers `result 9` for the unlisted item even
  after that.
- The engine serves `THIRD-PARTY-LICENSES.txt` as `text/html`, so the
  panel does not link it.

## Changes to the stock handler (items 1-6)

The mod replaces `ServerWebInterface.lua` wholesale. The policy is the
*Lua changes* [design decision](DESIGN.md#design-decisions):
change the Lua wherever it improves the result, and keep the HTTP API
backward compatible where that is cheap.

1. **Return console command output.** Stock `Shared.ConsoleCommand`
   returns nothing ([API.md](API.md#console-commands)). The mod captures
   what a command prints during the call (mechanism: REQUIREMENTS item 5)
   and adds `runcommand`, which returns it, and `getconsole?since=`, the
   same capture as a stream. The legacy `command`/`rcon` path is
   unchanged, and its commands appear in the stream.
2. **Completion and errors for `getmods`.** Steam's failure reaches Lua as
   an empty result, so only a search with no answer at all can be called
   a failure. The mod adds `done`, `count`, `capped` and, after 30 s with
   no answer, `error` (once, instead of a silent restart). It also starts
   a search without `searchtext`, reads a bad `p` as 1, keys its cache so
   `a` page 11 and `a1` page 1 differ, and makes `installmod` validate the
   id and answer. The 2012 panel reads only `loading` and `items`, both
   kept. Measurements: REQUIREMENTS item 4.
3. **A cursor for `getchatlist`.** `getchatlist&since=<id>` answers from
   the mod's ring of 200, with times, `last_id` and `dropped`. The ring
   wraps `Server.AddChatToHistory` after it is defined (this file loads at
   `Server.lua:35`, the function at `:82`) and re-wraps it when replaced,
   since two workshop mods ship their own `Server.lua`. Without `since`
   the reply is stock's. On 09-27, `sv_say` and `sv_tsay 1` arrived as
   `Admin` with times, and a map change restarted the ids.
4. **Consistent types.** Stock sends `cheats`, `devmode` and `isbot` as
   strings and `iscomm` and `game_started` as booleans. The mod sends all
   five as booleans; the panel reads both forms.
5. **A version field.** `mod_version` in the state blob, absent on a
   stock server, is how a client detects the mod.
6. **Answer a browser with the panel, not the state blob.** On a stock
   server `/` returns the state blob, IPs included
   ([API.md](API.md#no-404-and-no-directory-index)). The mod answers a
   request with no parameters at all with a page, holding no server data,
   whose meta refresh leads to `/index.html` (`fixtures/root-mod.html`).
   It cannot tell `/` from a missing file, nor a browser from a script,
   so a script reading state must send `request=json`, as both panels do.

   The right test is the `Accept` header (`text/html` for a browser
   navigation, `*/*` from `curl` and `fetch()`), but the `WebRequest` hook
   gets only the parameter table: no headers, path or method (09-26). Lua
   also cannot set a status or a header, so no redirect and no `Vary`
   (harmless, since every reply is no-cache). Proposed engine change:

   > The web admin's `WebRequest` hook gets one argument, the parameter
   > table: no path, no method, no headers (measured on 09-26). Could the
   > engine pass a second table with the request's `path`, `method` and
   > `headers` (names lowercased)? Handlers that take one argument ignore
   > it, so nothing breaks. It would let `ServerWebInterface.lua` answer a
   > browser at `/` with the panel (by `Accept: text/html`) while scripts
   > keep getting JSON, and stop guessing from an empty parameter table,
   > which cannot tell `/` from a missing file. Being able to set a
   > response status or header (a `Location`, a `404`) from Lua would be a
   > bonus, not a need.

## Stock bugs the mod fixes (items 7-13)

Each is a case where the server or the 2012 panel reports something that
did not happen. 7-10 were fixed and verified on 09-03, 11-13 on 09-26.

7. **`setreservedslotamount` does nothing.** `ServerWebInterface.lua:209`
   calls `SetReservedSlotAmount(actions.amount)` against a function
   declared `SetReservedSlotAmount(client, amount)`
   (`ServerAdminCommands.lua:614`). The amount lands in `client`, the
   guard rejects `nil`, and the request answers `200`, so the 2012
   Reserved Slots tab never worked. Fix: `SetReservedSlotAmount(nil,
   actions.amount)`. The console command `sv_reserved_slots N` was never
   affected, so the panel sets the amount through it on every server.
8. **`sv_unban` never removes a ban.** `Ban` stores the id as a number
   (`ServerAdminCommands.lua:446`) and keys `bannedPlayersMap` by it, but
   `UnBan` passes the console argument, a string, to `UnbanUser`
   (`:485`), so it answers `No matching Steam Id in ban list` about a ban
   plainly listed. Fixed by wrapping the global `UnbanUser` to call
   `tonumber`. `ServerAdminCommands.lua` loads at `Server.lua:34`, before
   our file at `:35`, and nobody keeps a local alias, so the wrapper also
   fixes the game console's `sv_unban`, with no copy of that file shipped.
9. **Expired bans stay in `getbanlist`.** `GetIsUserBanned` checks
   `ban.time`, so they no longer block anyone, but the list showed them.
   The mod filters them out; the raw list still has them.

   | | Before | After |
   | --- | --- | --- |
   | `setreservedslotamount=5` | amount stayed `0` | amount reads `5` |
   | `sv_unban <id>` | `No matching Steam Id in ban list` | no output, ban gone |
   | A ban that expired an hour ago | listed | not listed |

10. **A working unban does not let the player back in.**
    `GenerateBannedPlayersMap` (`ServerAdminCommands.lua:304`) only adds
    to `bannedPlayersMap`, and `UnbanUser` never clears it, so
    `GetIsUserBanned` and `GetIsUserBannedPermanently`, which
    `OnCheckConnectionAllowed` (line 376) calls, still refuse the player.
    On the rig, after an unban `getbanlist` returned `[]` and
    `GetIsUserBanned` still answered `true`. Stock never hits this
    because item 8 makes unbans fail first; fixing 8 alone would have
    turned a visible failure into an invisible one. The mod replaces both
    globals with versions that scan the live ban list (a busy server's
    list held 119 bans; the scan runs only on connect). Shine's ban
    plugin keys that list by string ids, so the comparison is
    `tonumber(ban.id) == id`.
11. **A removed reserved slot comes back after a restart.**
    `RemoveReservedSlot` (`ServerAdminCommands.lua:657`) saves with
    `Server.SaveConfigSettings()` instead of
    `Server.SaveReservedSlotsConfig()`, so the removal never reaches
    `ReservedSlotsConfig.json` until some other change saves it. The
    function is a local, so the mod adds a second hook on
    `Console_sv_remove_reserved_slot` that saves the file on the next
    tick.
12. **Reading the map cycle rewrites it.** `getmapcycle` hex-encodes a
    `table.copyDict` of the live cycle, and that copy is shallow
    (`ns2/lua/Table.lua:441` stores `v`, not `vCopy`). So every read
    turned the live cycle's mod ids, global and per map, from numbers
    into hex strings. Harmless in practice (rotation re-reads the file,
    and Shine's mapvote keeps its own table), but anything reading mod ids
    from `MapCycle_GetMapCycle()` got strings. Fixed with a deep copy.
13. **`getmapcycle` shows memory, `setmapcycle` overwrites the file.**
    `getmapcycle` answers from the table loaded with the map, while
    rotation and `sv_changemap` read `MapCycle.json`. A hand edit of the
    file was invisible to the panel, and the next `setmapcycle` wrote the
    old value back over it. The mod reads the file (with `io.open`, since
    `LoadConfigFile` prints a line into the console capture), falling back
    to memory only when it is missing or does not parse.

    Stock `setmapcycle` also answers an empty `200` whatever happens:

    | Sent | Stock result |
    | --- | --- |
    | No `maps` | Lua error, nothing written |
    | Mod id `zzzz` | Logged `Failed to convert mod id string zzzz`, then written to the file as `"zzzz"` |
    | Mod id `workshop:1` | Passed through, as `ModIdsFromHex` intends |
    | Shine's per-map `min`, `mods: []`, top-level `groups` | Kept: dkjson keeps unknown keys, `[]` stays `[]`, `30.5` stays a float |

    The mod validates first and refuses without writing, and on success
    returns the file read back (`{ok, cycle}` or `{ok: false, error}`).

    Under Shine's mapvote (`GetMapsFromMapCycle: true`, `RoundLimit: 2`)
    the vote's options are read from the cycle once, at plugin start: a
    17th map added by `setmapcycle` was offered only after the next map
    change. `VoteOnEnd` is set, so `mode` plays no part and the round
    limit, not `time`, ends a map. The mod reports this in `getmapvote`.

## Additions (items 14-17)

14. **Performance data.** Stock `getperfdata` keeps one reading a minute
    of three numbers. The mod adds `getperf`: 10 s windows of
    `ServerPerformanceData` (what `perfmon` prints), the tickrate counted
    per tick, the slowest tick, and the engine's own `tickstat` and
    `perfmon:` lines read from the log ([API.md](API.md#getperf);
    measurements in REQUIREMENTS item 10).

    **Trap:** `ServerPerformanceData:Accumulate()` of a sample whose
    `GetDurationMs()` is 0 divides by zero in the engine. The server dies
    with SIGFPE, which `pcall` does not catch, and the first sample after
    every map load is empty. The mod skips empty samples, and
    `perf-harness.lua` fails if that guard is lost.
15. **The server's log.** `getlog` serves `log-Server.txt` by byte offset
    ([API.md](API.md#getlog); REQUIREMENTS item 7). Lua reaches the file
    only through `config://`, so only when the engine writes its log into
    the config directory: `-logdir` equal to `-config_path`, or neither
    flag.

    **Trap:** `config://log-Server.txt` opens just as well when it is a
    frozen copy an earlier run left there. So the first `getlog` of each
    map load prints `improved-webadmin: checking that
    config://log-Server.txt is this server's log (<n>)` and looks for it
    in the file; if it is missing the reply is `stale`. A file handle sees
    the file as it was when opened, so the check prints before it opens,
    and `getlog` opens the file per request. A line reaches the file
    before `Shared.Message` returns (09-26).
16. **Hive skill and the map's load time in the state blob.** Each player
    row gains `skill`, `skill_offset`, `comm_skill` and
    `comm_skill_offset` from ScoringMixin (`GetPlayerSkill()` and its
    neighbours, each under `pcall`). Marines play at `skill +
    skill_offset`, aliens at `skill - skill_offset`, and the commander's
    pair likewise. On the rig a human's values matched Steam User Stats,
    sign included; bots report -1 in all four, shown as no skill.

    `skill_tier` is `ScoringMixin:GetSkillTier()`, the tier the game draws
    the badge for (-1 bot, -2 no skill, 0 rookie, 1-7). That function
    caches its first answer on the player for the rest of the map, so the
    mod saves and restores the cached field around the call; a panel poll
    never fixes the game's answer early. The panel shows this tier, not
    the scoreboard's team-relative badge.

    `map_loaded_at` is the `Shared.GetSystemTime()` the Lua VM started
    with (`getperf`'s `loaded_at`), so the Console can say when the map
    last changed.
17. **The ranked-mod whitelist, read from Steam.** A mod not on the
    whitelist turns ranking off, and the server gives Lua no way to ask
    which mods are on it.

    - **Where it lives:** the "Required items" of the unlisted Workshop
      item 2909200101. `libSpark_Network.so` hard-codes four system items
      per branch (`ModServices::s_LiveModIds`): hotfix list 2633436686,
      client hotfix list 2633426471, the whitelist, and Thunderdome
      2908583482; the beta and testing branches use 2708090797,
      2708090349, 2860343495 and 2857373471. At boot the engine fetches
      the hotfix list and the whitelist (`Found 2 hotfix mods`, `Found 115
      mods in whitelist`). Hotfix mods are not on the whitelist and are
      never flagged. Lua gets only `ModServices.GetHotfixListModId()`, and
      the log names only the first offending mod.
    - **How the mod reads it:** `getwhitelist` reads the item's public
      Steam Community page, which lists the same 115 ids as the keyed
      `IPublishedFileService/GetDetails` (the keyless
      `ISteamRemoteStorage` calls answer `result 9` for unlisted items),
      then the hotfix list's page, one after the other: the 09-03 drop's
      libcurl aborts the server on concurrent HTTPS. The first request
      answers `fetching`. A copy goes to
      `config://improved-webadmin/whitelist.json`; a map change serves it,
      a copy older than an hour is read again, and after a failure the mod
      waits 5 minutes. Without the mod, or when the read fails, the panel
      falls back on the dated copy it ships (`panel/src/whitelist.json`,
      from `tools/make-whitelist.py`).
    - **`Shared.SendHTTPRequest`'s callback** gets `(body, curl error
      message, curl code, HTTP status)`: `("", "Failed to connect to ...",
      7, 0)` for a refused connection, `("", "Could not resolve host:
      ...", 6, 0)` for an unknown host, the whole page with `nil, 0, 200`
      on success. Steam answers 200 for an item it does not have, so a
      page with no item list is the failure to look for.
    - **Steam Community rate-limits:** a dozen reads in a few minutes got
      `429`. Python's urllib kept getting 429 where curl, same address and
      User-Agent, got 200, so `make-whitelist.py` uses curl. The mod reads
      at most twice an hour.

    Probe: `whitelist-branch.lua` and `whitelist-helpers.lua`, built by
    `make-whitelist-probe.sh`. Writing it hit the engine's Lua
    preprocessor trap ([TESTING.md](TESTING.md#traps)).

## Engine additions that would simplify the mod (item 18)

Several parts of the mod work around data the engine holds and does not
hand to Lua. The bindings are generated from spec files (`server_linux`
carries "Auto-generated from ModServices.txt"), so a getter over existing
data is probably small; the maintainers know the real cost.

**The ranking check**, decoded from the 09-28 `server_linux` (the
function at `0x11b730`). The engine enables ranking by itself. The check
stops at the first failure, the only one it logs:

1. not hidden (`Ranking disabled: server is hidden`)
2. a dedicated server
3. no cheats
4. no Lua hot reloading
5. at most 5 spectator slots
6. 12 to 20 player slots
7. every mounted mod, and its dependencies, whitelisted (`server has
   non-whitelisted mods mounted`; `Mod dependency %s[%llu] is not
   whitelisted`)

When all pass it sets a flag. `Server.GetIsRankingActive()` is what the
game reads for ranking (`PlayerRanking.lua`); that it reads this flag is
inferred, not traced. The mod sends it as `ranking_active` in the state
blob; the panel parses it but does not show it, since with this mod
mounted it is always `false`.

| | Ask | Replaces |
| --- | --- | --- |
| 1 | `Server.GetIsModWhitelisted(modId)` (true, false, or nil when the list was never read), `ModServices.GetWhitelistedModIds()`, `Server.GetRankingDisabledReason()` | All of item 17: about 240 lines scraping Steam Community's HTML, the 429 limit, the libcurl path that aborts on concurrent HTTPS, the hard-coded branch table, the cache file, and the panel's shipped `whitelist.json`. It would also cover dependencies and use the copy the engine enforces. |
| 2 | The log directory as a read-only root (`logs://log-Server.txt`), or `Shared.ReadLog(offset, maxBytes)` | Item 15's layout rule and its stale-copy check. The Console would work on any server layout. |
| 3 | `Server.GetTickStat()`: the last window's fields as a table, with its end time | About 290 lines that scan the log every 2 s and parse the 16-segment `TICKSTAT\|` line, and the dependence on ask 2 and on `tickstat N`, a toggle every admin shares. |
| 4 | `Event.Hook("ConsoleOutput", fn(text))`, or `Shared.ConsoleCommand` returning what its command printed | About 120 lines of wrappers on `Shared.Message` and `ServerAdminPrint`, re-installed every tick because Shine replaces them, plus the filter for Shine's echoes. `runcommand` would also show engine commands' output (`tickstat`, `bwlimit`, `perfmon`), which today reaches only the log. Touches the print path, so less small. |
| 5 | `Shared.JsonEncode(table)` over the C JSON writer libSpark_Core already links (`json_write_minified`) | dkjson, most of every reply's cost ([SERVER-COST.md](SERVER-COST.md)). Must write an empty table as `[]`. |

Smaller asks: the request's path, method and headers in `WebRequest`
(item 6); `Server.UninstallMod` (REQUIREMENTS item 2);
`Server.SearchWorshop` honouring its page, reporting Steam's failure and
finding a mod by id (REQUIREMENTS item 4); `Accumulate()` refusing an
empty sample instead of dying (item 14); a float `GetUpdateIntervalMs()`;
and a rename inside `config://`, which would retire recent players' two
slots. `ModServices.GetModState(modId)` exists and may report download
progress for `installmod`; that needs a rig probe, not an ask.

**Proposed engine additions**, with item 6's:

> Three getters would let the web admin mod drop its biggest workarounds.
> Each is over data the server already holds.
>
> 1. **The whitelist verdict.** The server reads the ranked-mod whitelist
>    at boot (`Found 115 mods in whitelist`) and checks every mounted mod
>    and its dependencies against it. Lua can't see any of that, and the
>    log names only the first offender, so the mod scrapes the whitelist
>    item's Steam Community page instead. Could Lua get
>    `Server.GetIsModWhitelisted(modId)` (true, false, or nil if the list
>    wasn't read), `ModServices.GetWhitelistedModIds()`, and
>    `Server.GetRankingDisabledReason()`, the reason the ranking check
>    stopped at (the `Ranking disabled: ...` string), or nil when ranked?
>    `Server.GetIsRankingActive()` already gives the yes or no.
> 2. **The server's own log.** `io.open` reaches `log-Server.txt` only
>    when `-logdir` is the config directory, and then a stale copy from an
>    earlier run opens just as well. Mounting the log directory read-only
>    (say `logs://`) or a `Shared.ReadLog(offset, maxBytes)` returning the
>    bytes, the file size and the header's Date/Time would make the log
>    tail work on any server layout.
> 3. **tickstat as data.** `Server.GetTickStat()` returning the last
>    window's fields as a table (the ones in the `TICKSTAT|` format
>    string, plus the window's end time) would replace parsing the line out
>    of the log. Ideally it would be readable without `tickstat N` being on,
>    since that is a console toggle every admin shares.
>
> Nothing breaks without them; the mod falls back to what it does today.

## Shine

Almost every server runs Shine, so it is the normal case. Source read from
its Workshop copy (`117887554`); behaviour measured on the rig with a
Shine config, 23 mods and the mod's Lua.

| What Shine does | Effect | Status |
| --- | --- | --- |
| Replaces `ServerAdminPrint` on its first tick, without chaining, with a version that returns at once when there is no client (`core/server/logging.lua`) | Vanilla admin commands run from the web admin printed nothing anywhere. | **Fixed**: the mod re-installs its wrapper every tick and before each request. After: `sv_kick` returns `No matching player`, `sv_listbans` 117 lines. |
| Replaces `Shared.Message` with a timestamping version | None: captured lines carry no timestamp, the audit line still arrives, and `sh_*` output (through `Print`) is captured. | Works |
| Ban plugin replaces `GetBannedPlayersList()` with its own list | String ids, an unstable order, float `time` (the spec's `getBanList`). The vanilla list drifts from it: 117 against 119. | Item 10's fix handles string ids; the panel reads Shine's table through `getbans` |
| Ban plugin redirects `sv_ban`/`sv_unban` to `sh_ban`/`sh_unban` (both run), and rejects banned players in its own connection hook | **An `sv_ban` of an absent id is a phantom ban**: `sh_ban` fails (`You cannot target yourself with this command.`), vanilla's `Ban` then prints `Player with SteamId N has been banned`, but the entry lands only in the vanilla list, which nothing enforces. | The panel bans with `sh_banid` (any id) and unbans with `sh_unban` under the plugin |
| Its own command output | Through `Shared.Message`, no audit line, then a receipt: `Console[N/A] banned <name>[N] for 1 hour.`, `Console[N/A] unbanned N.`, `N is not banned.`, `Console[N/A] set reserved slot count to N`, each followed by `Console[N/A] ran command <cmd> with arguments: <args>`. Weeks are the largest duration unit. | The mock's `--shine` reproduces it |
| `AdminPrint` sends each line to every admin in game through `ServerAdminPrint(admin, line)` after printing it once | The capture recorded each line once more per in-game admin. | **Fixed**: a `ServerAdminPrint` to a player repeating the line just captured, within a second, is skipped (`console-harness.lua`) |
| `mapvote` picks the next map, from `MapCycle.json` with `GetMapsFromMapCycle: true` | The Maps tab still edits the file that matters, but `mode` plays no part and edits reach the vote at the next map load (item 13). | Reported by `getmapvote`; the Maps tab says so |
| `reservedslots` plugin | Shine sets the count itself (`sh_setresslots`) and grants access by the `sh_reservedslot` permission; there is no id list, and vanilla's slots are not enforced. | Detected (`shine` in the state blob, `shine.slots` in `getreservedslots`) |
| `basecommands` runs `sv_say` as its own `sh_say` | No audit line and no `Chat All - Admin:` line, only the receipt. The message still reaches `AddChatToHistory`. `sv_tsay` is not redirected. | The Chat tab confirms a send by finding it in the chat |
| `basecommands` has `sh_gag`/`sh_ungag`, the only mute there is | The game has no mute command (CURRENT-UI defect 18). `Console[N/A] gagged <name>[<id>]` / `ungagged`, with the receipt; `No player matching '<id>' was found.` for nobody. Shine refuses to gag a bot. A gagged player's chat is dropped before `AddChatToHistory`, with no warning to the player. | `shine.basecommands` and `gagged` per player; Mute on the Players tab |
| The vanilla round commands | `sv_reset`, `sv_rrall`, `sv_randomall` and `sv_forceeventeams` behave as on vanilla. | Works |
| `sh_kick <no match>` from the console | Answers `You cannot target yourself with this command.` | Shown as printed |
| Its logging calls `Server.AddChatToHistory` | Shine's own messages may appear in `getchatlist`. | To check on a populated round |

The mod reports Shine and its active plugins (ban, reservedslots, mapvote,
basecommands) in the state blob's `shine`, so the panel picks the right
behaviour per tab. Under the ban plugin the Bans tab reads Shine's table
through `getbans`, which also gives who banned and for how long; a
`6e+24` duration is permanent.

## Console arguments

Every write the panel makes goes through `Shared.ConsoleCommand`. Measured
on the rig, vanilla and Shine alike:

| Input | Result |
| --- | --- |
| `sv_add_reserved_slot "Two Words" 123` | Stored as `"Two Words"`, quote marks included: quotes are not parsed |
| `sv_add_reserved_slot Two Words 123` | `Invalid arguments...`: arguments split on whitespace |
| `sv_say a; sv_say b` | One chat line, `a; sv_say b`: `;` does not separate commands |
| `sv_ban N 60 two  spaces` | Reason `two spaces`: runs of whitespace collapse |
| `sv_reserved_slots 99` on a 16-slot server | Only the audit line: out-of-range amounts are ignored silently |
| `sv_add_reserved_slot One N` when `One` exists | Replaces that slot: slots are keyed by name |

So a slot name cannot contain a space, and the panel says so. Nothing seen
lets a value start a second command, but the panel still strips `;`,
quotes and control characters from anything it puts on a command line,
since slot names can come from player names.

# Constraints and engine asks

Two separate things: what the engine now enforces (design around it),
and what the vanilla Lua handler gets wrong or leaves out (the mod ships
its own, so we fix it ourselves).

## What the 2026-09-03 hardening enforces

From `CHANGELOG.md` inside `ns2-linux-ship-344-26-09-03.zip`. The web
server behind the panel was replaced wholesale in that drop -- it was a
2010 library with no security fixes since 2013 -- and a dozen rules came
with it. All of these bind the new panel.

| Rule | Consequence for the SPA |
| --- | --- |
| **GET and POST only** | Fine as-is; the API is query-parameter based and uses neither PUT nor DELETE. |
| **Cross-site requests carrying a foreign `Origin` are refused `403`** | A Vite dev server on `:5173` talking to the game server **will be refused**. Development must go through a proxy or the mock server. Same-origin production builds are unaffected. |
| **Request bodies capped at 64 KB; malformed `Content-Length` refused** | Only `setmapcycle` posts a body. Measure a large cycle against the cap before assuming it fits. |
| **Login challenge is single-use and expires in 5 minutes** | **Settled, and a non-issue.** A nonce is reusable while it lives if the client increments `nc`; it dies on age at 301 s and the refusal carries `stale="true"` with a fresh nonce. A `fetch()` poll left running for 480 s in Chrome made 240 requests, all `200`, across that expiry -- no prompt, no failure, no 401 even visible. The panel needs no re-authentication logic. See [API.md](API.md#authentication-verified). |
| **10 failed logins per address per minute = 1 minute lockout** | A retry loop with bad credentials will lock the developer out of their own server. Back off on 401. |
| **Requests give up after 30 s with `503`** | Treat `503` as "server busy", not as a hard failure; retry with backoff rather than surfacing an error. |
| **Replies send no-cache, nosniff and no-framing headers** | No cache-busting tricks needed. The panel cannot be embedded in an iframe -- do not design a dashboard that expects to be. |
| **Refusals now return a complete response** | Errors are readable instead of hanging. Good; rely on it. |
| **Still plain HTTP** | Do not add anything that requires TLS: no mixed-content assumptions, no service worker, no secure-context-only APIs. The panel must also work behind an HTTPS proxy; how to secure a server is in the README's [Security](../README.md#security). |

Also relevant: the panel refuses to start entirely unless it is
localhost-restricted or has `-webusers`, `-webreqip` or `-webtoken`.
Any test instance needs one of those configured.

## What the Origin rule actually compares *(verified 2026-09-05)*

`Origin` is compared against the request's **`Host` header**, not against
`-webdomain`. Measured on a live 26-09-03 server, and **re-measured on
09-26** *(2026-09-27)* with the same results plus the rows marked:

| Request | Result |
| --- | --- |
| No `Origin` header at all | `200` |
| `Origin` matching the host | `200` |
| `Origin` matching the host but not the scheme (`https://127.0.0.1:8080`) *(09-26)* | `200` -- only the host is compared |
| `Origin: http://localhost:5173` | `403` |
| `Origin: https://evil.example` | `403` |
| `Origin: null` | `403` |
| `PUT` / `DELETE` | `405` |
| `HEAD` / `OPTIONS` *(09-26)* | `405` |

Refusals are logged as

```
WebAdmin - rejected request from 127.0.0.1 (origin does not match host)
```

but **not one line per refusal**, whatever the changelog says: on 09-26,
four `Origin` refusals produced two lines and five `Host` refusals
produced one. Repeated refusals appear to be collapsed. That matters for
fail2ban, not for the panel.

Two things follow for development. Requests with **no** `Origin` are
unaffected, so a Vite `server.proxy` works -- the proxied request is made
by Node, not the browser, and carries no `Origin`. And `Origin: null`
being refused means the panel cannot be driven from a sandboxed iframe or
a `file://` page.

### The Host rule, when no web users are configured *(09-25; measured on 09-26)*

With no `-webuser`/`-webpassword`/`-webusers`, the 09-25 drop refuses
any `Host` that is neither `localhost` nor an IP literal. The rule
applies to static files as well as to the API. With a login configured,
`Host` is not checked (`Host: adm.example` -> `200` on the rig).

| `Host` (no-login rig, bound to `127.0.0.1:8080`) | Result |
| --- | --- |
| `127.0.0.1:8080`, `localhost`, `localhost:8080`, `LOCALHOST:8080`, `[::1]:8080` | `200` |
| `10.1.2.3` -- any IP literal, not only loopback | `200` |
| no `Host` header at all | `200` |
| `adm.example`, `localhost.example` | `403` |
| `adm.example` with `Origin: https://adm.example` | `403` |
| `/index.html` with `Host: adm.example` | `403` |
| `127.0.0.1:8080` with `Origin: http://127.0.0.1:8080` | `200` |
| `127.0.0.1:8080` with `Origin: https://adm.example` | `403` |

Logged as `… (no users configured and Host is not localhost or an IP
address)`. The mock reproduces this rule whenever it runs without
`--auth` *(2026-09-27)*.

## No CDN

The server serves static files over plain HTTP on a possibly isolated
network. Every required dependency must be vendored into the build.
Avoid fetching at runtime from an external host.

## Lua changes the mod ships

The mod carries its own `lua/ServerWebInterface.lua`, so none of these
are requests any more -- they are work items. None needs engine or binary
work. Listed in the order we want them.

**Since 2026-09-27 this is not a minimal list.** Lua changes are made
whenever they improve the result, and the HTTP API may change shape when
there is a good reason. Backward compatibility is preferred where it is
cheap. The policy is *Lua changes* in the README's
[Design decisions](../README.md#design-decisions).

1. **Return console command output.** *(built 2026-09-05, `lua/ServerWebInterface.lua`)* Today `Shared.ConsoleCommand(actions.rcon)`
   runs and returns nothing, so the panel cannot show whether a kick
   worked or why a command failed, and fakes it with a timed refresh.
   Capturing output for the duration of the call and returning it is the
   single biggest improvement available, and it unlocks a real console
   tab. This is the one that justifies shipping Lua at all -- the
   evidence for why it matters is in
   [API.md](API.md#demonstrated-not-argued-verified). **Mechanism proven
   2026-09-05:** `ServerAdminPrint` (`core/lua/ServerAdmin.lua:156`) and
   `Shared.Message` are both writable globals, and `Shared.ConsoleCommand`
   is synchronous, so a wrapper captures a command's own output and
   returns it in the same response. See
   [REQUIREMENTS.md](REQUIREMENTS.md#mechanism-answered-spike-2026-09-05).

   **Shipped as two request types**, both in
   [openapi.yaml](openapi.yaml): `runcommand` returns what the command it
   just ran printed, and `getconsole?since=` streams the same capture for
   a console tab. The legacy `command`/`rcon` path is untouched, so the
   2012 panel keeps working -- and its commands show up in the stream
   too. `mod_version` in the state blob is how a panel tells this server
   from a stock one (item 5 below, also done).
2. ~~**A completion or error signal for `getmods`.**~~ **Done**
   *(2026-09-27)*, as far as the engine allows. Measured first
   ([REQUIREMENTS.md](REQUIREMENTS.md) item 4): an empty result is
   `{"items":[]}` (not `{}`, as this item used to say), and a search Steam
   failed comes back the same way, in the same frame, so the Lua cannot
   tell a failure from no matches -- only a search with no answer at all.
   The mod's `getmods` now says `done`, `count` and `capped` (50 hits, the
   engine's limit; it ignores the page), and reports a search with no
   answer after 30 s once, with `error`, instead of restarting it
   silently. It also starts a search without `searchtext` rather than
   never, reads a bad `p` instead of erroring, and keys its cache so `a`
   page 11 and `a1` page 1 differ. `installmod` refuses what is not a hex
   id and answers what it did. The 2012 panel reads only `loading` and
   `items`, both kept. Asking the engine to pass Steam's error to the
   callback would close the rest.
3. ~~**A cursor parameter for `getchatlist`.**~~ **Done** *(2026-10-06)*,
   for the Chat tab. `getchatlist&since=<id>` answers from the mod's own
   ring of 200, with times, `last_id` and `dropped`, like `getconsole`.
   The ring records every call to `Server.AddChatToHistory`, wrapped late
   (this file loads at `Server.lua:35`, the function is defined at `:82`)
   and re-wrapped if replaced, because two installed workshop mods ship
   their own `Server.lua`. Without `since` the reply is stock's, which the
   2012 panel polls. Measured on the rig (09-27 engine): `sv_say` and
   `sv_tsay 1` arrive as `Admin`, team 0 and team 1 team-only, with
   times; `since=1` returns only the second; a map change restarts the ids
   (`last_id` 0). Player chat needs a human and is still to be seen.
4. ~~**Consistent types.**~~ **Done** *(2026-10-06)*. `cheats`, `devmode`
   and `isbot` were stringified booleans while `iscomm` and
   `game_started` are real ones; the mod now sends all five as booleans.
   The 2012 panel reads none of the three. Our panel reads both forms,
   since a stock server still sends strings.
5. ~~**A build/version field** in the server-state response, so the panel
   can adapt to whichever server it is served from.~~ **Done** --
   `mod_version`, absent on a stock server.
6. **Answer a browser with the panel, not the state blob.** `/`
   used to fall through to the default handler and return the
   server-state blob -- names, SteamIDs and IPs -- to anyone who types
   the host and port the boot log prints. See
   [API.md](API.md#there-is-no-directory-index-either-verified).

   **The fallback is shipped** *(2026-10-06, by decision)*: a request
   with no parameters at all gets a page, holding no server data, whose
   meta refresh leads to `/index.html`. Measured on the rig, see API.md.
   It cannot tell `/` from a missing file, nor a browser from a script,
   so a script reading state must send `request=json`, as both panels
   do. The `Accept` route below stays the better answer, and needs an
   engine change (proposed at the end of this item).

   **Decide by the `Accept` header, not by the absence of parameters**
   *(2026-09-27)*. That is what the header is for: a browser navigating
   to `/` sends `Accept: text/html,...`, while `curl` and `fetch()` send
   `*/*` unless told otherwise. So HTML goes only to a request whose
   `Accept` names `text/html`; everything else, including a missing
   header or `*/*`, keeps getting JSON. Every existing script and the
   2012 panel's XHRs are unaffected, and nobody needs a special
   `request=` value to ask for JSON. The HTML answer is the panel itself
   or a stub pointing at `/index.html`. `OnWebRequest` returns only a
   content type and a body, so an HTTP redirect is not available from
   Lua.

   **Blocked: the engine does not hand headers to Lua** *(measured on
   09-26, 2026-09-27)*. The `WebRequest` hook gets exactly one argument,
   the parameter table, and a request carrying `Accept`, `Cookie` and
   `X-Probe` showed none of them. Path and method are missing too. So
   `Accept` negotiation needs an engine change: the request headers (and
   ideally path and method) passed to the hook, for example as a second
   table argument, which old handlers would ignore. Until then, the only
   signal Lua has is the parameterless test, now shipped above; the
   decision (2026-10-06) was both: the fallback now, and the ask.

   Replies carry no `Vary: Accept`, and Lua cannot add one. That is
   harmless, because the engine already marks every reply no-cache.

   **Proposed engine change:**

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

**Also shipped: recent players** *(built 2026-09-27)*. Everyone seen in
the last 24 hours, up to 100, kept in `config://webadmin-spa/` so the
list outlives a map change, and read with `getrecentplayers`. The file
can only be rewritten whole and nothing can delete or rename it, so saves
alternate between two slots and the loader takes the newest one that
parses. The design and what it survives are in
[REQUIREMENTS.md](REQUIREMENTS.md) item 6. Under Shine's ban plugin it
also names the bans of absent players, by wrapping `Plugin:AddBan`;
vanilla keeps `Unknown`, by decision (same item).

**Also shipped: which mods are mounted** *(built 2026-09-27)*.
`getinstalledmodslist` gains `active` per mod, from
`Server.GetActiveModId`, so the Mods tab does not have to infer it from
the cycle. The cycle is not what is mounted: the engine mounts two hotfix
mods of its own, and a cycle edit takes effect only at the next map
change. Measured in [REQUIREMENTS.md](REQUIREMENTS.md) item 3.

Item 1 is the one that changes what the panel can be. Items 2-6 are
cheap and can follow.

### Three one-line bugs found while verifying *(2026-09-05)*

Existing functions that do not work, each fixable in a line. Cheaper than
1-6 and worth doing first, since nothing has to be designed.

7. **`setreservedslotamount` does nothing.** *(fixed)* `ServerWebInterface.lua:209`
   calls `SetReservedSlotAmount(actions.amount)` against a function
   declared `SetReservedSlotAmount(client, amount)`. The amount lands in
   `client`, `amount` is `nil`, the guard rejects it, and the request
   returns `200`. Fix: `SetReservedSlotAmount(nil, actions.amount)`.
   The whole Reserved Slots tab has never worked. The console command
   `sv_reserved_slots N` was never affected -- it passes `client` first, and
   `SetReservedSlotAmount` does its own `tonumber` -- so a panel that sets
   the amount through the command works on a stock server too.

8. **`sv_unban` can never remove a ban.** *(fixed)* `Ban` stores `id` as a number
   (`tonumber(playerId)`, `ServerAdminCommands.lua:446`) and
   `bannedPlayersMap` is keyed by that number, but `UnBan` passes the raw
   console argument -- a string -- straight to `UnbanUser`
   (`ServerAdminCommands.lua:485`). `bannedPlayersMap["<id>"]` is nil, so it
   answers `No matching Steam Id in ban list: <id>` about an entry
   plainly present in `getbanlist`. Fix: `UnbanUser(tonumber(steamId))`.
   Affects the game console too, not just the web panel.

9. **Expired bans are never pruned from `getbanlist`.** *(fixed)* A one-minute ban
   was still listed long after expiry. It no longer blocks the player --
   `GetIsUserBanned` checks `ban.time` -- so the panel shows bans that are
   not in effect, and the Unban button on them does nothing (see 8).

7-9 pair naturally with 1: all four are cases where the panel tells the
operator something happened when it did not.

**All three are fixed, and a fourth with them** *(2026-09-05,
`lua/ServerWebInterface.lua`, verified on the rig).*

**The mod does not have to override `ServerAdminCommands.lua` after
all.** The earlier note here said item 8 forces a second file, because
the broken call is in that file rather than in `ServerWebInterface.lua`.
It does not: `UnbanUser` is a global, nobody takes a local alias of it,
and `ServerAdminCommands.lua` loads at `Server.lua:34` against our
`Server.lua:35`, so wrapping it from our file is in place before anything
can call it -- and it fixes the game console's own `sv_unban` too, not
only the web one. Carrying a 700-line copy of a file we did not write, to
change one line in it, is a maintenance cost the mod now avoids
entirely. (Since 2026-09-27 shipping such a copy is allowed when it is
the better fix; here wrapping still wins on its own merits.)

Measured after the fixes, on a live 26-09-03 server:

| | Before | After |
| --- | --- | --- |
| `setreservedslotamount=5` | amount stayed `0` | amount reads `5` |
| `sv_unban <id>` | `No matching Steam Id in ban list` | no output, and the ban is gone |
| A ban that expired an hour ago | still listed by `getbanlist` | not listed; the raw list still has it |

### 10. An unban that works does not let the player back in *(new defect)*

Found while testing item 8, and worse than it.

`GenerateBannedPlayersMap` (`ServerAdminCommands.lua:304`) only ever
*adds* to `bannedPlayersMap`, and `UnbanUser` removes from
`bannedPlayers` without clearing the map, so the removed ban survives
there. `GetIsUserBanned` and `GetIsUserBannedPermanently` read that map,
and `OnCheckConnectionAllowed` (line 376) reads them -- so the unbanned
player is still refused at connect, while every list in the panel says
they are not banned.

Measured on the rig, after a successful unban: `getbanlist` returned `[]`
and `GetIsUserBanned` still answered `true`.

It cannot bite on a stock server, because `sv_unban` never works there in
the first place. **Fixing item 8 is what exposes it**, which is why both
had to be fixed together -- shipping 8 alone would have replaced a
visible failure with an invisible one, and this project exists to stop
exactly that.

Fixed the same way: both functions are globals that
`OnCheckConnectionAllowed` calls by name, so the mod replaces them with
versions that consult the live ban list rather than the stale map. That
trades a hash lookup for a linear scan over the ban list on the
connection path, which for realistic ban lists is not a cost worth
naming. (A busy server's list measured 119 bans.)

**The first version of that fix was wrong on any Shine server**
*(found 2026-09-27 on a Shine config with 119 bans, fixed the same day)*. It read
`GetBannedPlayersList()` and compared `ban.id == id` with a numeric id.
Shine's ban plugin replaces `GetBannedPlayersList()` with one built from
its own table, keyed by **string** ids, so no ban ever matched: the mod's
`GetIsUserBanned` would have answered "not banned" for all 119 bans.
Shine rejects banned players in its own connection hook, so on a Shine
server the lockout would still have held, but only by luck. The vanilla map
lookup, by contrast, still works there, because the file Shine mirrors
bans into stores numbers. The comparison is now `tonumber(ban.id) == id`.
The live list's full shape is in the spec's `getBanList`.

## Shine *(2026-09-27)*

Almost every server runs Shine, so **Shine is the normal case, not an
edge case**. The panel and the mod's Lua must work on it. Shine replaces
several of the things this project builds on. Source read from its
Workshop copy (`117887554`); behaviour measured on the rig booted with a
Shine config and 23 mods, our Lua mounted.

| What Shine does | Effect on us | Status |
| --- | --- | --- |
| Replaces `ServerAdminPrint` on its first tick, **without chaining**, with a version that returns at once when there is no client (`core/server/logging.lua`) | Every vanilla admin command run from the web admin printed nothing, anywhere -- not to our capture, not to the log. `sv_kick nobody` gave only the audit line; `sv_listbans` gave nothing. | **Fixed**: our wrapper re-installs itself over the current `ServerAdminPrint` every tick and before each request. Measured after: `sv_kick` returns `No matching player`, `sv_listbans` 117 lines, `sv_help` 38. |
| Replaces `Shared.Message` with a timestamping version | None seen: captured lines carry no `[HH:MM:SS]` prefix, the audit line still arrives, and Shine's own command output (`sh_*` with no client goes through `Print`) is captured. | Works |
| Ban plugin replaces `GetBannedPlayersList()` with its own list | String ids, unstable order, float `time` (see the spec's `getBanList`). The vanilla list, loaded from `BannedPlayers.json`, drifts from Shine's: 117 against 119 on the rig. | Lua fixed (item 10); spec and panel types accept it |
| Ban plugin redirects `sv_ban`/`sv_unban` to `sh_ban`/`sh_unban` (both hooks run) and rejects banned players in its own connection hook | **An `sv_ban` of an id that is not connected is a phantom ban.** `sh_ban` targets connected players only and fails (`You cannot target yourself with this command.`), vanilla's `Ban` then succeeds and prints `Player with SteamId N has been banned` -- but the entry lands only in the vanilla list, which on a Shine server nothing enforces (our `GetIsUserBanned` reads Shine's list, and so does Shine's hook). Measured on the rig, 2026-09-27. | **Designed around**: under the ban plugin the panel bans with `sh_banid` (any id, kicks the target if connected) and unbans with `sh_unban` |
| Shine's own command output | Through `Shared.Message`, no audit line, and a receipt after it: `Console[N/A] banned <unknown>[N] for 1 hour.` / `... permanently.`, `Console[N/A] unbanned N.`, `N is not banned.`, `Console[N/A] set reserved slot count to N`, each followed by `Console[N/A] ran command <cmd> with arguments: <args>`. Durations are Shine's `TimeToDuration`: weeks are the largest unit. | Measured; the mock's `--shine` reproduces it |
| `mapvote` decides the next map; with `GetMapsFromMapCycle: true` it takes its maps from `MapCycle.json` | The Maps tab still edits the file that matters there. `mode` plays no part, the round limit (when set) ends a map instead of `time`, and edits reach the vote only at the next map load | **Measured** (item 13); the mod reports it in `getmapvote` and the Maps tab says so |
| `reservedslots` plugin | When active, Shine sets the count from its own config (`sh_setresslots`) and grants access by the `sh_reservedslot` permission -- there is no id list. Vanilla reserved slots are not what is enforced, so a Reserved Slots tab editing them would be misleading | **Detected** (the state blob's `shine`, and `getreservedslots` gains `shine.slots`); measured by loading the plugin at runtime with `sh_loadplugin` |
| Shine's logging calls `Server.AddChatToHistory` | Shine's own messages can appear in `getchatlist` | To check on a populated round |
| `basecommands` runs `sv_say` as its own `sh_say` *(measured 2026-10-06)* | No audit line and no `Chat All - Admin:` line: the command's only output is `Console[N/A] ran command sh_say with arguments: <text>`. The message does reach `AddChatToHistory`, so the mod's chat ring has it as `Admin`. `sv_tsay` is not redirected and prints as vanilla does. | The Chat tab confirms a send by finding it in the chat, not from the output |
| `basecommands` holds `sh_gag`/`sh_ungag`, the only mute there is *(measured 2026-10-06)* | The game has no mute command, and the 2012 panel's `sv_mute` dispatches nothing on vanilla or Shine (CURRENT-UI defect 18). An id that matches nobody: `No player matching '<id>' was found.`, with no receipt. Shine refuses to gag a bot. A gag prints `Console[N/A] gagged <name>[<id>]`, an ungag `Console[N/A] ungagged <name>[<id>]`, each with the receipt; an ungag of someone not gagged prints only the receipt. The gagged player's chat is refused before `AddChatToHistory`, and the player gets no warning (measured with a human, 2026-10-06). | The state blob's `shine.basecommands`, and `gagged` per player; Mute on the Players tab uses them |
| `AdminPrint` sends each of its lines to every admin in game, through `ServerAdminPrint(admin, line)`, after printing it once *(measured 2026-10-06, admin joined)* | Our capture recorded every Shine line twice -- the panel's activity strip showed the gag line doubled -- and would record it once more per extra admin | **Fixed**: a `ServerAdminPrint` to a player that repeats the line just captured, within a second, is a delivery, not a new line. An in-game admin's own command output is still captured. `console-harness.lua` |
| The vanilla round commands under Shine *(measured 2026-10-06)* | `sv_reset`, `sv_rrall`, `sv_randomall` and `sv_forceeventeams` dispatch and print as on vanilla. | Works |
| `sh_kick <no match>` from the console answers `You cannot target yourself with this command.` | A misleading message, but it is Shine's; the panel shows it as printed | Noted |

What follows for the design: the mod **detects Shine and says which of
its plugins are active** (ban, reservedslots, mapvote, and since
2026-10-06 basecommands) in the state blob,
next to `mod_version`, so the panel can pick the right behaviour per tab
instead of guessing. Under Shine, the source for the Bans tab is Shine's
own table, which also carries who banned and for how long -- data
`GetBannedPlayersList()` throws away. Both are built *(2026-09-27)*: the
`shine` key and the `getbans` request type, verified on the rig with a
Shine config (117 bans in force, one of them the `6e+24` kind, reported
permanent).

### 11. A removed reserved slot comes back after a restart *(fixed 2026-09-27)*

`RemoveReservedSlot` (`ServerAdminCommands.lua:657`) takes the slot out of
memory and then saves with `Server.SaveConfigSettings()`, where adding a
slot and setting the amount use `Server.SaveReservedSlotsConfig()`. The
removal never reaches `ReservedSlotsConfig.json`. Measured on the rig:
after `Removed reserved slot for One`, the file still held `One`, until an
unrelated `sv_reserved_slots 3` saved it. A restart in between brings the
slot back, while every list said it was gone.

`RemoveReservedSlot` is a local and cannot be wrapped. The mod adds a
second hook on `Console_sv_remove_reserved_slot` that marks the config
dirty, and the next tick saves it -- correct whichever hook the engine runs
first. Measured after the fix: the file reads `"ids": []` a second after
the removal.

### 12. Reading the map cycle rewrites it *(measured 2026-09-27)*

`getmapcycle` hex-encodes a copy of `MapCycle_GetMapCycle()`, but the copy
is `table.copyDict`, and that is shallow: `ns2/lua/Table.lua:441` computes
`vCopy` and then stores `v`. So `ModsIdsToHex` rewrites the **live**
cycle's `mods` arrays, global and per map, from numbers to hex strings.
Measured on the rig with a modded cycle: before one `getmapcycle`, the
in-memory `mods[1]` was `number:208649136`; after it, `string:c6fbbb0`, and
the same for `ns2_jambi`'s own mod.

Harmless today, by luck rather than design: rotation re-reads the file
(`MapCycle_GetLatestValidConfig()`), the in-memory copy is only consulted
for `time` and map names, and Shine's mapvote holds a table of its own (it
kept `number:129599221`). Anything else that calls `MapCycle_GetMapCycle()`
for mod ids gets strings. **Fixed** by a real deep copy.

### 13. `getmapcycle` shows memory, `setmapcycle` overwrites the file *(measured 2026-09-27)*

`getmapcycle` answers from the table loaded when the map loaded, while
rotation and `sv_changemap` read `MapCycle.json` from disk. A hand edit
of the file (`time` 40 -> 41) was invisible to `getmapcycle` (still 40),
and the next `setmapcycle` wrote 40 back over it: the panel both shows
the wrong cycle and destroys the right one. **Fixed**: the mod reads the
file, and falls back to memory only when the file is missing or does not
parse. It reads with `io.open`, not `LoadConfigFile`, which prints
`Loading config://MapCycle.json` and would put a line in the console
capture on every read.

`setmapcycle` also answers an empty `200` whatever happens. Measured:

| Sent | Result |
| --- | --- |
| No `maps` | Lua error (`bad argument #1 to 'ipairs'`), empty `200`, nothing written |
| Mod id `zzzz` | Logged `Failed to convert mod id string zzzz`, then **written** to the file as the string `"zzzz"`, and returned by `getmapcycle` |
| Mod id `workshop:1` | Passed through, as `ModIdsFromHex` intends |
| Entry `{"map", "min": 12, "mods": []}`, top-level `groups` | Round-trip intact: dkjson keeps unknown keys, empty arrays stay `[]`, `30.5` stays a float |

**Fixed**: the mod validates first and refuses without writing, and on
success reads the file back and returns it (`{ok, cycle}` or
`{ok: false, error}`). The 2012 panel ignores the reply.

**Under Shine's mapvote** (with `GetMapsFromMapCycle: true` and
`RoundLimit: 2`) the vote's options are read from the cycle once, at
plugin start. After a `setmapcycle` adding a 17th map, the plugin still
offered 16 until `sv_changemap`, then 17. `GetNextMap()` answers through
`pcall` (`ns2_jambi` after `ns2_summit`), and `VoteOnEnd` is set, so
`mode` plays no part and the round limit, not `time`, ends the map. The
mod reports all of it in `getmapvote`.

### 14. Performance data the panel could not have *(built 2026-09-27)*

Not a bug: an addition. Vanilla `getperfdata` keeps one reading a minute
of three numbers. The mod adds `getperf`: 10 s windows of the engine's
`ServerPerformanceData` (what `perfmon` logs), the tickrate counted per
tick and the slowest tick, an hour since the map load, read with a
cursor. `getperfdata` is untouched for the 2012 panel. Measurements in
[REQUIREMENTS.md](REQUIREMENTS.md) item 10.

**A trap for anyone touching it:** `ServerPerformanceData:Accumulate()`
of a sample with `GetDurationMs() == 0` is an integer division by zero in
the engine. The server dies with SIGFPE, and `pcall` does not help. The
first sample after every map load is empty. The mod skips empty samples
before accumulating, and `perf-harness.lua` fails if that guard is ever
lost.

### 15. The server's log, and a copy that is not it *(built 2026-09-28)*

Not a bug: an addition, with one trap found on the way. The mod adds
`getlog`: `log-Server.txt` by byte offset, whole lines only, for the Log
tab (REQUIREMENTS item 7). It reaches the file only through `config://`,
so only when the engine writes its log into the config directory:
`-logdir` equal to `-config_path`, or neither flag, which is the default
layout.

**The trap:** `config://log-Server.txt` opens just as well when it is a
copy an earlier run left there, and then it is frozen. Found on the rig: a
boot with `-logdir` elsewhere served the previous run's log as if it were
live. So the first `getlog` of each map load prints one line
(`webadmin-spa: checking that config://log-Server.txt is this server's
log (<n>)`) and looks for it in the file; if it is not there, the reply
is `stale` and the panel says why instead of showing the file. The line
lands in the server's real log either way.

Two engine behaviours the code depends on, both measured on 09-26: a line
reaches the file before `Shared.Message` returns, and **a file handle sees
the file as it was when it was opened**. The check prints before it opens;
`getlog` opens per request and never keeps a handle.

### 16. Hive skill and the map's load time in the state blob *(built 2026-10-07)*

Not bugs: two additions, for the Players tab's Skill column and the
Console's last map change. Each player row gains `skill`, `skill_offset`,
`comm_skill` and `comm_skill_offset`, read from ScoringMixin
(`GetPlayerSkill()` and its three neighbours, `ns2/lua/ScoringMixin.lua`)
with a `pcall` each, and left out for a player without them. Marines play
at `skill + skill_offset`, aliens at `skill - skill_offset`, and the
commander's pair the same way. The blob also gains `map_loaded_at`, the
`Shared.GetSystemTime()` the Lua VM started with (the stamp `getperf`
already serves as `loaded_at`), so the Console can say when the map last
changed without having seen it happen. Harness `state-harness.lua`.
**On the rig** *(2026-10-07, a human joined)*: skill 1771, offset -214,
commander 1931, offset +200, the same as Steam User Stats holds for that
player (offset 214 with sign 0, commander offset 200 with sign 1). So the
sign is the server's, and the panel's marine 1557 / alien 1985 and
commander 2131 / 1731 are the server's own. Every bot reports -1 in all
four, which the panel shows as no skill.

*(2026-10-08)* Each row with `skill` also gains `skill_tier`,
`ScoringMixin:GetSkillTier()`: the tier the game draws the skill badge
for (-1 bot, -2 no skill, 0 rookie, 1-7). That function caches its first
answer on the player (`skillTier`) for the rest of the map, and the game
calls it only for a rookie-only server's join check, so the Lua saves the
field before asking and puts it back after: a panel poll never decides
when the game's answer is fixed. Vanilla and UWE Hotfix 344 have the same
function; Devnull Extras ships a `GetPlayerSkillTier` that rates everyone
4200, but its file hooks never load it. Harness `state-harness.lua`.
The panel shows the server's own tier rather than the scoreboard's
team-relative badge, which would change with the player's team while the
skill beside it does not.

### 17. The ranked-mod whitelist, read from Steam *(built 2026-10-08)*

Not a bug: an addition. A mod not on the whitelist turns ranking off, and
until now the panel could only say so in general. The fan wiki's list was
no source: already stale (105 ids against 115).

**Where the list lives.** It is the "Required items" of the unlisted
Workshop item 2909200101, "Mod Whitelist". `libSpark_Network.so`
hard-codes four system items per branch (`ModServices::s_LiveModIds`):
the hotfix list 2633436686, the client hotfix list 2633426471, the
whitelist and Thunderdome 2908583482. The beta and testing branches use
2708090797, 2708090349, 2860343495 and 2857373471. At boot the engine
fetches the hotfix list and the whitelist in one UGC query (`Found 2
hotfix mods`, `Found 115 mods in whitelist`). The hotfix mods are not on
the whitelist and are never flagged. Lua gets only
`ModServices.GetHotfixListModId()` (a uint64 cdata, `2633436686ULL`), and
the server has no call that lists an item's children. The log names only
the **first** mod that is not whitelisted (with Steam unreachable, 1 of 20
on 2026-10-06), so it cannot give a verdict per mod.

**How the mod reads it.** `getwhitelist` reads the item's public page,
`steamcommunity.com/sharedfiles/filedetails/?id=2909200101`. That page
lists the same 115 ids as the keyed `IPublishedFileService/GetDetails`, and
the keyless `ISteamRemoteStorage` calls answer `result 9` for unlisted
items. It reads the hotfix list's page the same way, one page after the
other, never two at once: the 09-03 drop's libcurl (8.21, mbedTLS 3.6.7)
aborts the server on concurrent HTTPS. The first request starts a
read and answers `fetching`. A copy goes to
`config://webadmin-spa/whitelist.json`; a map change serves the copy, and a
copy older than an hour is read again. After a failure the mod waits 5
minutes before reading again. The panel falls back on a dated copy it
ships (`panel/src/whitelist.json`, from `tools/make-whitelist.py`).

**On the rig** *(2026-10-08, 09-27 engine)*: the two reads took 2 s and
gave the same 115 and 2 ids as the keyed API, and a `sv_changemap`
served the file's copy with no new read. `Shared.SendHTTPRequest`'s
callback gets `(body, curl's error message, curl's code, HTTP status)`. A
refused connection gives `("", "Failed to connect to 127.0.0.1:9 after 0
ms: Could not connect to server", 7, 0)`, and an unknown host gives
`("", "Could not resolve host: ...", 6, 0)`. A page gives the whole body
(64 KB) with `nil, 0, 200`. Steam answers 200 for an item it does not
have, so a page with no item list is the failure to look for. Probe:
`tools/spikes/whitelist-helpers.lua` and `whitelist-branch.lua`, built by
`make-whitelist-probe.sh`.

**Two traps found on the way:**

- **Steam Community rate-limits.** After a dozen reads in a few minutes it
  answered `429 Too Many Requests`. Python's urllib kept getting 429 while
  curl, from the same address with the same User-Agent, got 200, so
  `make-whitelist.py` reads through curl. The mod reads at most twice an
  hour, and a 429 is reported as `Steam answered HTTP 429` and waited out.
- **The engine's Lua preprocessor can drop the end of a file.** The 09-xx
  engines run each script through a preprocessor that adds `PROFILE`
  zones: it matches `function`/`do`/`if`/`repeat` against `end`/`until`.
  The first version of the probe nested its code inside `OnWebRequest`.
  The log then said `WARNING: File was not completely preprocessed! Here
  is where it stopped. File: lua/ServerWebInterface.lua:2632, Remaining
  Bytes: 1433`, and everything after `OnWebRequest` was dropped, its
  `Event.Hook` included, so every request answered `with error:`. File
  size is not the cause: the shipped file padded to 100 KB loads whole,
  and stock files run to 180 KB. The exact token that confused it was
  not pinned down (a quoted `"#"` was ruled out). Moved to top-level
  functions, the same code loads whole. **After any Lua change, check
  the server's log for that warning.**

### 18. What small engine additions would replace *(drafted 2026-10-08)*

Not a bug: a list of asks. Several parts of `ServerWebInterface.lua` work
around something the engine knows and does not hand to Lua. Checked
against the 09-28 binaries. The engine's Lua bindings are generated from
spec files (`server_linux` carries "Auto-generated from ModServices.txt"
and the FFI wrappers it emits), so a getter over data the engine already
holds is probably a small change; the engine's maintainers would know the
real cost.

**Ranking, decoded** *(09-28 `server_linux`, the function at `0x11b730`)*.
The engine turns ranking on by itself. It needs no request. Its check runs
in this order and stops at the first failure, which is the only one it
logs:

1. not hidden (`Ranking disabled: server is hidden`)
2. a dedicated server (`... not a dedicated server`)
3. no cheats (`... cheats active`)
4. no Lua hot reloading (`... lua hot reloading is enabled`)
5. **at most 5 spectator slots** (`... spectator slots higher than 5`)
6. **12 to 20 player slots** (`... player slots higher then 20`, `... lower then 12`)
7. **every mounted mod in the whitelist** (`... server has non-whitelisted
   mods mounted`; the per-mod lines name the first, and dependencies are
   checked too: `Mod dependency %s[%llu] is not whitelisted`)

When all pass it sets a flag (byte `0xf43` of its object).
`Server.GetIsRankingActive()` is the getter the game reads for ranking
(`PlayerRanking.lua`'s `GetTrackServer`); that it reads this same flag is
inferred, not traced, since its FFI implementation does not read that
offset directly. **The mod sends it as `ranking_active` in the state
blob** *(built 2026-10-08)*. It should read `false` wherever this mod is
mounted, until the mod is whitelisted: a rig check. It does not say why.
The panel parses it and shows it nowhere yet.

**What each addition would replace**, by how much it would simplify:

| | Ask | Replaces |
| --- | --- | --- |
| 1 | `Server.GetIsModWhitelisted(modId)` (true, false, or nil when the list was never read), `ModServices.GetWhitelistedModIds()`, `Server.GetRankingDisabledReason()` | All of item 17: about 240 lines that scrape Steam Community's HTML, a 429 rate limit, the libcurl path that aborts on concurrent HTTPS, a hard-coded branch table, a cache file, and the panel's shipped `whitelist.json` with `tools/make-whitelist.py`. It also gives what the mod cannot see: the dependency check, and the copy the engine actually enforces. |
| 2 | The log directory as a read-only root (`logs://log-Server.txt`), or `Shared.ReadLog(offset, maxBytes)` | Item 15's layout rule (`-logdir` equal to the config path, which also puts `dumps/` there) and the stale-copy check that prints a marker and looks for it. The Console tab would then work on any server layout. The tail logic (offsets, rotation, paging) stays. |
| 3 | `Server.GetTickStat()`: the last window's fields as a table, with its end time | About 290 lines that scan the log every 2 s, parse the 16-segment `TICKSTAT\|` line and stamp it with the scan's time. It would also remove the dependence on item 2 and on `tickstat N`, a console toggle shared by every admin. |
| 4 | `Event.Hook("ConsoleOutput", fn(text))` for every console line, the engine's included; or `Shared.ConsoleCommand` returning what its command printed | About 120 lines of wrappers on `Shared.Message` and `ServerAdminPrint`, re-installed every tick because Shine replaces them, and the filter for Shine's echoes. `runcommand` would then also show output from engine commands (`tickstat`, `bwlimit`, `perfmon`), which today reach only the log. This touches the print path, so it is less small. |
| 5 | `Shared.JsonEncode(table)` over the C JSON writer libSpark_Core already links (`json_write_minified`) | dkjson, which is most of every reply's cost ([SERVER-COST.md](SERVER-COST.md)). Not measured: no native encoder was at hand. It must write an empty table as `[]`, as dkjson does. |

Smaller, already recorded elsewhere: the request's path, method and
headers in `WebRequest` (item 6, drafted); `Server.UninstallMod`
(REQUIREMENTS item 2); `Server.SearchWorshop` passing its page through,
saying when Steam failed and finding a mod by id (REQUIREMENTS item 4);
`ServerPerformanceData:Accumulate()` refusing an empty sample instead of
dying of SIGFPE (item 14); a float `GetUpdateIntervalMs()`; and a rename
inside `config://`, which would retire recent players' two slots.
`ModServices.GetModState(modId)` already exists and may report a
download's progress for `installmod`; that is a rig probe, not an ask.

**Proposed engine additions**, together with item 6's:

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

### What console arguments can carry *(measured 2026-09-27)*

Every write the panel makes goes through `Shared.ConsoleCommand`, so what
survives the trip decides what the forms can accept. On the rig, vanilla
and Shine alike:

| Input | Result |
| --- | --- |
| `sv_add_reserved_slot "Two Words" 123` | Stored under the name `"Two Words"` -- **quote marks included**. Quotes are not parsed. |
| `sv_add_reserved_slot Two Words 123` | `Invalid arguments...`: arguments split on whitespace, so `Words` is taken as the id. |
| `sv_say a; sv_say b` | One chat line reading `a; sv_say b`. **`;` does not separate commands.** |
| `sv_ban N 60 two  spaces` | Reason stored as `two spaces`: runs of whitespace collapse. |
| `sv_reserved_slots 99` on a 16-slot server | Only the audit line. Out-of-range amounts are ignored without a word. |
| `sv_add_reserved_slot One N`, name already present | Replaces that name's slot: slots are keyed by name. |

So a reserved slot name cannot contain a space, and the panel says so
rather than letting quote marks into the file. Nothing seen lets a value
start a second command, but the panel still strips `;`, quotes and
control characters from anything it puts on a command line, since slot
names can come from player names.

## Answered: the whole thing can ship as a mod *(verified 2026-09-05)*

`Shared.SetWebRoot()` is called from Lua, not from the engine
(`ServerWebInterface.lua:25`). It **does** resolve through the mod
filesystem, and so does `lua/ServerWebInterface.lua` itself. Tested on a
live 26-09-03 server by mounting a mod carrying both:

| What was tested | Result |
| --- | --- |
| Mod supplies `web/index.html` and `web/marker.txt` | Both served, shadowing `ns2/web/` |
| Mod supplies `lua/ServerWebInterface.lua` with a new request type | `/?request=modmarker` returned `{"from":"mod"}` |
| That copy also carries the ask-6 one-line fix | `setreservedslotamount=5` set the amount to 5 and logged it; vanilla does nothing |

So a workshop mod delivers the panel **and** the Lua changes together,
with no game-file edits. This is why the project targets a mod. The proof
was a throwaway mod: a `web/index.html` and `web/marker.txt`, and a copy
of the vanilla `ServerWebInterface.lua` with one extra request type and
the one-line fix, mounted from a local directory and named in the map
cycle's `mods`.

`UWE Hotfix 344` already does the same thing for gameplay code -- it
ships `lua/NS2Gamerules.lua` over the vanilla one -- so this is the
supported mechanism, not a trick.

### What it costs

- **The server loses ranked status** while a non-whitelisted mod is
  mounted (`Ranking disabled: server has non-whitelisted mods mounted`).
  Accepted. Whitelisting can be requested once the mod is published and
  has some mileage.
- **Clients download the mod on join.** `NetworkServicesServer::SetModList`
  publishes the server's mods and clients fetch them. The built panel is
  about 650 KB, more than half of it minimaps; one download, cached -- but
  every player pays it for a panel only admins use.
- **The mod web root merges rather than replaces.** `/js/rcon.js` and
  `/css/bootstrap.css` still resolve from `ns2/web/` with the mod
  mounted. The panel is additive: the old 860 KB stays on disk and stays
  reachable at its old paths. Nothing links to it once `index.html` is
  replaced, but the size comparison is "what we serve", not "what we
  removed".
- No consistency risk: `ServerWebInterface.lua` is loaded only from
  `Server.lua:35`, so clients never see it.

### Still untested

The proof used a local mount directory, not a published workshop item.
Whether a published item mounts `web/` and `lua/` identically, and what a
joining client actually downloads, are the open questions -- see *Next* in
the [README](../README.md#next).

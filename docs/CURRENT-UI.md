# The panel as it ships today

Inventory of a dedicated server's `ns2/web/`, build 344. 860 KB total.

## Files

| File | Lines | What it is |
| --- | --- | --- |
| `index.html` | 341 | Whole app. Six tabs plus eight `<script type="text/html">` row templates. |
| `js/baselibs.js` | 97 | A 237 KB bundle, minified: **jQuery 1.7.2** (March 2012), Bootstrap 2's JavaScript, and **jqPlot** with its renderers. Only jQuery and Bootstrap carry a banner. |
| `js/jquery-ui-1.9.0.custom.min.js` | 5 | jQuery UI 1.9.0 (Oct 2012): core, widget, mouse, position, draggable, droppable, resizable, selectable, sortable. |
| `js/jquery.tablesorter.min.js` | 3 | Table sorting. |
| `js/rcon.js` | 496 | Players, bans, reserved slots, chat, performance, command sending. |
| `js/mapcycle.js` | 161 | Map cycle editor (drag and drop). |
| `js/modbrowser.js` | 149 | Workshop search and install. |
| `js/ui.js` | 16 | Tab switching. **Not referenced by `index.html`.** |
| `css/bootstrap*.css` | -- | Bootstrap 2.x, both plain and minified, plus responsive. |
| `css/dark-hive/` | -- | jQuery UI theme: one CSS file and ~20 PNG sprites. The bulk of the 860 KB. |
| `css/jquery.jqplot.css` | -- | Styles for jqPlot, which does ship -- inside `baselibs.js`. |
| `web/client_game/*.html` | -- | Three in-game video widgets. Unrelated to the admin panel; loaded by `GUIWebView`. Leave alone. |

## Tabs

`index.html:35-41` -- Maps, Mods, Players, Bans, Reserved Slots,
Performance. Players is the default.

Per-player actions are hardcoded `rconbutton` elements carrying a
command string (`index.html:76-96`):

```
sv_kick <steamid>            sv_mute <steamid>
sv_ban <steamid> 1440 WebUI  sv_slay <steamid>
sv_ban <steamid> 0 WebUI     sv_eject <steamid>
sv_switchteam <steamid> 0|1|2|3
```

Because commands return nothing ([API.md](API.md)), the UI guesses at
the result: `rcon()` in `rcon.js:290-300` string-matches the command it
just sent and schedules a list refresh 500 ms later.

## Defects found while reading it

Worth recording -- they are why the panel is being replaced rather than
patched, and two of them are user-visible.

1. ~~**The Performance tab is broken.** `showPerfChart()` (`rcon.js:277`)
   calls `$.jqplot(...)`, but no jqPlot JavaScript ships in `js/`.~~
   **Struck 2026-09-05** -- wrong. jqPlot is bundled inside
   `baselibs.js`; the chart renders. See below.
2. **Typo defeats the perf-sample de-duplication.** `rcon.js:255` writes
   `lastPerfTIme` while line 253 reads `lastPerfTime`, so the guard never
   advances and every poll re-appends all 30 samples.
3. **The retry path is dead.** `if (performance_data.length == 0)`
   (`rcon.js:261`, `:266`) tests an array initialised to `[[],[]]`, whose
   length is always 2. The retry never fires.
   *(Replaced 2026-09-27: the new Performance tab replaces a stock
   server's window on every read and reads the mod's `getperf` with a
   cursor, so nothing is appended twice; a failed read is retried on the
   next poll. `spa-perf.py` asserts both.)*
4. **`ui.js` is orphaned** -- present on disk, never loaded.
5. **Bootstrap ships twice**, minified and not, as does bootstrap-responsive.
6. Player IPs are rendered in plain text for anyone with panel access.

### Added on 2026-09-05, against a live server

Five more:

7. **Every bot's kick, mute, slay and ban button is inert.** The row
   templates send `sv_kick <%=steamid%>` (`index.html:77`) and
   `Kick()` resolves through `GetPlayerMatching(playerId)`. Bots report
   `"steamid": 0`, so nothing matches. The buttons render on every bot
   row and silently do nothing.
8. **The Reserved Slots tab has never worked** -- the request type behind
   it is broken in Lua. See [API.md](API.md) and
   [CONSTRAINTS.md](CONSTRAINTS.md) item 7. **Fixed by the mod
   2026-09-05**: with `lua/` mounted the tab's own request type sets the
   amount, as the tab always assumed it did.
9. **The Unban button cannot unban** -- same, item 8. It sends
   `sv_unban <%=id%>` (`index.html:112`), which the game rejects. **Fixed
   by the mod 2026-09-05**, together with a fourth defect that fixing it
   uncovered: the unban did not take effect at the connection check
   either, so a player unbanned through a working button would still have
   been refused. See [CONSTRAINTS.md](CONSTRAINTS.md) item 10.
10. **The mod browser can unrank the server without saying so.** Loading
    a non-whitelisted workshop mod disables ranking; the panel shows no
    warning before or after.
11. **The panel fetches a web font from Google over the internet.**
    `css/bootstrap.css:1` and `bootstrap.min.css` open with
    `@import url('https://fonts.googleapis.com/css?family=Droid+Sans:400,700')`.
    On an isolated network or a server without outbound access that
    request simply fails, and where it succeeds it tells Google every
    time an operator opens the panel. This is the concrete case for the
    no-CDN rule in [CONSTRAINTS.md](CONSTRAINTS.md#no-cdn).

Of 2-11: defects 2-5 and 11 are consequences of an unmaintained front
end, and 7-10 are cases where the panel reports success it never verified
-- the same root cause as the missing command output in
[API.md](API.md).

### Verified in a browser on 2026-09-05

Headless Chrome against a local test server ([TESTING.md](TESTING.md)), driven over the DevTools protocol:
load `/index.html`, authenticate once, click through to the Performance
tab, then read the page's own state. Scripts in
`tools/browser-checks/`.

**Defect 1 is wrong and is struck.** jqPlot is not missing -- it is
bundled into `baselibs.js` alongside jQuery and Bootstrap's JavaScript.

| Checked | Result |
| --- | --- |
| `typeof $.jqplot` | `function` |
| `typeof $.jqplot.DateAxisRenderer` | `function` |
| uncaught exceptions while opening the tab | 0 |
| `<canvas>` elements inside `#perfchart` | 7 |
| plotted series | 2, labelled `Players` and `Tickrate` |
| axes | x-axis time ticks, y-axis `0.0`-`35.0` |

The chart draws. The claim came from `index.html` having six
`<script src>` tags with no jqPlot among them, which is true and still
gave the wrong answer, because the library is inside one of the six.
Reading the tag list is not the same as loading the page.

**Defects 2 and 3 are confirmed, and they are the real fault in the tab.**
After a load and three further calls to `refreshPerformance()`:

| Checked | Result |
| --- | --- |
| `lastPerfTime` -- read by the guard, `rcon.js:253` | `0`, never advances |
| `lastPerfTIme` -- written by the typo, `rcon.js:255` | a real timestamp, and nothing reads it |
| samples `getperfdata` was returning | 25 |
| `performance_data[0].length` across four polls | 25 -> 50 -> 75 -> 100 |
| `performance_data.length` -- tested against `0`, `rcon.js:261` | `2`, so the retry is dead |

Every poll appends the whole window again. The tab polls once a minute
(`rcon.js:408`) and the window caps at 30 samples, so a tab left open for
an hour holds around 1,800 points for 30 samples' worth of data, drawn
over itself. The tab is not broken; it is wrong, which is harder to
notice.

**Defect 11 is confirmed on the wire**, not just in the stylesheet: one
request to `fonts.googleapis.com` and two font files from
`fonts.gstatic.com`.

### Two more, neither of them visible by reading the files

12. **The host root serves player data instead of the panel.** The panel
    lives at `/index.html`, which is the documented URL
    (`Dedicated_Server_Usage.txt:118`). `OnWebRequest(actions)` receives
    only the query parameters and never the path, so a bare `/` falls
    through to the default handler and answers with the full server-state
    blob -- every player's name, SteamID and IP address. The server's own
    boot line is `Web server running at 127.0.0.1:8080`, with no path, so
    the address an operator is handed is exactly the one that dumps
    player data to anyone who reaches it. **Fixed by the mod**
    *(2026-10-06)*: a request carrying no parameters gets a page leading
    to `/index.html` instead ([API.md](API.md#there-is-no-directory-index-either-verified)).

13. **Opening the panel pulls 4.7 MB from third parties.**
    `modbrowser.js:149` calls `getMods(1)` from `$(document).ready`, so
    every page load runs an empty-search workshop query and renders 50
    mod rows into the hidden Mods tab. One load, cache disabled, no tab
    clicked:

    | Origin | Requests | Bytes |
    | --- | --- | --- |
    | the game server | 46 | 614 KB |
    | `images.steamusercontent.com` | 49 | 4.55 MB |
    | `cdn.steamusercontent.com` | 1 | 68 KB |
    | `fonts.gstatic.com` | 2 | 43 KB |
    | `fonts.googleapis.com` | 1 | 0.8 KB |

    So 860 KB on disk is not the number to beat: 614 KB is what a load
    costs from the server, and the panel adds 4.66 MB of traffic to Steam
    and Google on top of it for a tab nobody opened. It also means an
    isolated server spends every page load waiting on requests that
    cannot complete. See [REQUIREMENTS.md](REQUIREMENTS.md) item 4 and
    [CONSTRAINTS.md](CONSTRAINTS.md#no-cdn).

12 and 13 are both cases where the panel does something off its own bat
that nobody asked it to do. Neither shows up in the source without
running it, which is the argument for having a browser in the loop at
all.

### One more, found building the Maps tab *(2026-09-27)*

14. **Saving the map cycle throws away what the editor does not know.**
    `saveMapCycle()` (`mapcycle.js:111-146`) rebuilds `maps` from the DOM
    ids of the sorted list and keeps only `map` and a recomputed `mods`
    per entry, on every drag and every field change. Shine's mapvote
    reads further keys from the cycle -- per-map `min`, `max`, `chance`,
    `time`, `rounds`, top-level map `groups` -- and all of them are gone
    after one save. An entry's `mods` are recomputed from `getmaplist`, so
    any mod listed for a map other than the one that ships it is dropped
    too. The replacement edits the cycle it read and writes it
    back with everything it did not touch.

### Two more, found building the Workshop tab *(2026-09-27)*

15. **Next and Previous page through nothing.** `modbrowser.js` sends
    `p`, but the engine ignores it (measured: pages 1, 2, 3 and 500 of a
    search were the same 50 items), so every page is page one again. The
    page-number links read `data.range`, which `getmods` has never
    returned, so they never render.
16. **Subscribe is a download, and unsubscribe is nothing.** The first
    click sends `installmod` as a `GET`; the second only flips a local
    flag, sends nothing and removes nothing (nothing can,
    [REQUIREMENTS.md](REQUIREMENTS.md) item 2). The flag is not read from
    the server, so it is lost on reload and says nothing about whether
    the download happened. There is no confirmation and no word about
    ranking.

### Two more, found in the parity audit *(2026-10-06)*

Both are buttons that send a command no server has. Measured on the rig,
vanilla and Shine: neither dispatches, and neither prints anything.

17. **Reset Round sends `sv_resetround`.** `index.html:253`. The command
    is `sv_reset` (`ServerAdminCommands.lua:124`). The button has never
    reset a round. The replacement's Players tab sends `sv_reset`.
18. **Mute sends `sv_mute`.** `index.html:80`. The game has no mute
    command at all. Shine's basecommands has one, `sh_gag`. The
    replacement offers Mute only under that plugin, as `sh_gag`/`sh_ungag`,
    shows who is muted, and otherwise disables the button and says why.

The 2012 panel's other round buttons work: `sv_rrall`, `sv_randomall` and
`sv_forceeventeams`. The last has no round check of its own
(`ForceEvenTeams()`, `TeamJoin.lua`) and only the 2012 panel's confirm
text warns; the replacement disables it mid-round and says why.

## Why it looks dated

It is dated: every dependency is from 2012 and none has been updated
since. That is also why replacing it is low-risk -- there is no build
step, no framework version to migrate, and no server-side coupling
beyond the query parameters in [API.md](API.md).

## Where each 2012 action went *(audited 2026-10-06)*

Every action in `index.html`, `rcon.js`, `mapcycle.js` and
`modbrowser.js`, where it lives in the replacement, and the gate that
proves it against the mock:

| 2012 panel | Now | Gate |
| --- | --- | --- |
| Player table: name, Steam id, IP, team, score, K/A/D, res, ping | Players | `spa-players.py` |
| Its Time column | Recent players' *played* (mod). The old column was time since that browser page first saw the player, reset by a reload | `spa-recent.py` |
| Kick | Players row | `spa-players.py` |
| Ban (24 hours) | Players row; `sh_banid` under Shine | `spa-bans.py` |
| Ban (Forever) | Bans tab, the Permanent preset | `spa-bans.py` |
| Mute (`sv_mute`, never existed: defect 18) | Players row, `sh_gag`/`sh_ungag` under Shine's basecommands; otherwise disabled with the reason | `spa-players.py` |
| Slay | Players row | `spa-players.py` |
| Move to Ready Room / Marines / Aliens / Spectate | Players row | `spa-players.py` |
| Eject | Players row, commanders only | `spa-players.py` |
| Reset Round (`sv_resetround`, never existed: defect 17) | Players toolbar, `sv_reset` | `spa-players.py` |
| All to Ready Room, All to Random Teams | Players toolbar | `spa-players.py` |
| Force Even Teams | Players toolbar, disabled mid-round | `spa-players.py` |
| Change Map (dropdown) | Maps, Change to | `spa-maps.py` |
| RCON Command | Console | `spa-console.py` |
| Chat log | Chat | `spa-chat.py` |
| Chat to All / Marines / Aliens | Chat | `spa-chat.py` |
| Ban list, Unban | Bans | `spa-bans.py` |
| Add Ban (id, duration, reason) | Bans | `spa-bans.py` |
| Reserved slots: list, add, remove, amount | Reserved Slots | `spa-slots.py` |
| Map cycle: drag, add, remove, time, mode | Maps | `spa-maps.py` |
| Map cycle's mods (checkboxes) | Mods | `spa-mods.py` |
| Mod browser: search, subscribe | Workshop | `spa-workshop.py` |
| Performance chart | Performance | `spa-perf.py` |

Nothing is left out. Two of the old buttons never worked and now do what
they were for, and a third (Unban) works with the mod's fixes.

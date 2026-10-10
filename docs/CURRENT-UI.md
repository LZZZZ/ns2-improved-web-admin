# The 2012 panel

What a dedicated server ships in `ns2/web/` (build 344, 860 KB), its
defects, and where each of its actions went. Code cites the defects by
number, so keep the numbers.

Every dependency dates from 2012 and none has been updated. There is no
build step and no server-side coupling beyond the query parameters in
[API.md](API.md), which is why replacing it is low-risk.

## Files

| File | Lines | What it is |
| --- | --- | --- |
| `index.html` | 341 | The whole app: six tabs and eight `<script type="text/html">` row templates. |
| `js/baselibs.js` | 97 | A 237 KB minified bundle: jQuery 1.7.2, Bootstrap 2's JavaScript, and jqPlot with its renderers. |
| `js/jquery-ui-1.9.0.custom.min.js` | 5 | jQuery UI 1.9.0: core, widget, mouse, position, draggable, droppable, resizable, selectable, sortable. |
| `js/jquery.tablesorter.min.js` | 3 | Table sorting. |
| `js/rcon.js` | 496 | Players, bans, reserved slots, chat, performance, command sending. |
| `js/mapcycle.js` | 161 | Map cycle editor. |
| `js/modbrowser.js` | 149 | Workshop search and install. |
| `js/ui.js` | 16 | Tab switching. Not referenced by `index.html`. |
| `css/bootstrap*.css` | -- | Bootstrap 2, plain, minified and responsive. |
| `css/dark-hive/` | -- | jQuery UI theme: one CSS file and ~20 PNG sprites, most of the 860 KB. |
| `css/jquery.jqplot.css` | -- | jqPlot's styles. |
| `web/client_game/*.html` | -- | Three in-game video widgets loaded by `GUIWebView`. Not part of the panel. |

## Tabs

`index.html:35-41`: Maps, Mods, Players (the default), Bans, Reserved
Slots, Performance.

Per-player actions are `rconbutton` elements carrying a command string
(`index.html:76-96`):

```
sv_kick <steamid>            sv_mute <steamid>
sv_ban <steamid> 1440 WebUI  sv_slay <steamid>
sv_ban <steamid> 0 WebUI     sv_eject <steamid>
sv_switchteam <steamid> 0|1|2|3
```

Commands return nothing ([API.md](API.md#console-commands)), so `rcon()`
(`rcon.js:290-300`) refreshes the list 500 ms later and lets the operator
guess.

## Defects

Found by reading the files and by driving the panel in headless Chrome
against the rig (`tools/browser-checks/`). Most are cases where the panel
reports success it never verified, or does something nobody asked for.

1. *Withdrawn.* jqPlot was thought missing, but it is bundled in
   `baselibs.js`, and the Performance chart renders (`perf-browser.py`).
2. **Every poll re-appends the whole performance window.** `rcon.js:255`
   writes `lastPerfTIme` while line 253 reads `lastPerfTime`, so the
   de-duplication guard never advances. In Chrome, `performance_data[0]`
   grew 25 → 50 → 75 → 100 over four polls of a 25-sample window; a tab
   left open an hour holds about 1,800 points for 30 samples, drawn over
   themselves.
3. **The retry path is dead.** `if (performance_data.length == 0)`
   (`rcon.js:261`, `:266`) tests an array initialised to `[[],[]]`, whose
   length is always 2.
4. **`ui.js` is orphaned**: on disk, never loaded.
5. **Bootstrap ships twice**, minified and not, as does
   bootstrap-responsive.
6. **Player IPs are shown in plain text** to anyone with panel access.
7. **A bot's kick, mute, slay and ban buttons do nothing.** The templates
   send `sv_kick <%=steamid%>` (`index.html:77`), and bots report
   `"steamid": 0`, which matches no one.
8. **The Reserved Slots tab never worked**: its request type is broken in
   Lua (CONSTRAINTS item 7).
9. **The Unban button cannot unban** (CONSTRAINTS item 8), and an unban
   that did work would not have reached the connection check (item 10).
10. **The mod browser can unrank the server without a word.** Loading a
    mod that is not whitelisted disables ranking; the panel warns neither
    before nor after.
11. **The panel fetches a web font from Google.** `css/bootstrap.css:1`
    and `bootstrap.min.css` `@import` Droid Sans from
    `fonts.googleapis.com`: one request there and two font files from
    `fonts.gstatic.com` on every load. It fails on an isolated network and
    tells Google whenever an operator opens the panel.
12. **The host root serves player data instead of the panel.** `/` falls
    through to the state blob ([API.md](API.md#no-404-and-no-directory-index)),
    and the boot line `Web server running at 127.0.0.1:8080` gives exactly
    that address. The mod answers `/` with a page leading to `/index.html`
    (CONSTRAINTS item 6).
13. **Opening the panel pulls 4.7 MB from third parties.**
    `modbrowser.js:149` calls `getMods(1)` from `$(document).ready`, so
    every load runs a Workshop search and renders 50 rows into the hidden
    Mods tab. One load, cache disabled, no tab clicked:

    | Origin | Requests | Bytes |
    | --- | --- | --- |
    | the game server | 46 | 614 KB |
    | `images.steamusercontent.com` | 49 | 4.55 MB |
    | `cdn.steamusercontent.com` | 1 | 68 KB |
    | `fonts.gstatic.com` | 2 | 43 KB |
    | `fonts.googleapis.com` | 1 | 0.8 KB |

    An isolated server spends every page load waiting on requests that
    cannot complete.
14. **Saving the map cycle drops what the editor does not know.**
    `saveMapCycle()` (`mapcycle.js:111-146`) rebuilds `maps` from the DOM
    on every change, keeping only `map` and a recomputed `mods` per entry.
    Shine's per-map `min`, `max`, `chance`, `time`, `rounds` and top-level
    `groups` are lost after one save, and so is any mod listed for a map
    other than the one that ships it.
15. **Next and Previous page through nothing.** The engine ignores `p`
    (REQUIREMENTS item 4), so every page is page one. The page-number
    links read `data.range`, which `getmods` never returns.
16. **Subscribe is a download and unsubscribe is nothing.** The first
    click sends `installmod`; the second flips a local flag that is not
    read from the server and is lost on reload. No confirmation, no word
    about ranking.
17. **Reset Round sends `sv_resetround`** (`index.html:253`), which does
    not exist; the command is `sv_reset` (`ServerAdminCommands.lua:124`).
    It has never reset a round.
18. **Mute sends `sv_mute`** (`index.html:80`). The game has no mute
    command; Shine's basecommands has `sh_gag`.

17 and 18 were checked on the rig, vanilla and Shine: neither dispatches
nor prints anything. The other round buttons (`sv_rrall`,
`sv_randomall`, `sv_forceeventeams`) work. `sv_forceeventeams` has no
round check of its own (`ForceEvenTeams()`, `TeamJoin.lua`); only the 2012
panel's confirm text warns.

## Where each 2012 action went

Every action in `index.html`, `rcon.js`, `mapcycle.js` and
`modbrowser.js`, where it lives now, and the gate that checks it against
the mock:

| 2012 panel | Now | Gate |
| --- | --- | --- |
| Player table: name, Steam id, IP, team, score, K/A/D, res, ping | Players, one table per team | `spa-players.py` |
| Its Time column (time since that page first saw the player) | Recent players' *played* (mod) | `spa-recent.py` |
| Kick | Players row | `spa-players.py` |
| Ban (24 hours) | Players row; `sh_banid` under Shine | `spa-bans.py` |
| Ban (Forever) | Bans tab, the Permanent preset | `spa-bans.py` |
| Mute (defect 18) | Players row, `sh_gag`/`sh_ungag` under Shine's basecommands; otherwise disabled with the reason | `spa-players.py` |
| Slay | Players row | `spa-players.py` |
| Move to Ready Room / Marines / Aliens / Spectate | Players row | `spa-players.py` |
| Eject | Players row, commanders only | `spa-players.py` |
| Reset Round (defect 17) | Players toolbar, `sv_reset` | `spa-players.py` |
| All to Ready Room, All to Random Teams | Players toolbar | `spa-players.py` |
| Force Even Teams | Players toolbar, disabled mid-round | `spa-players.py` |
| Change Map | Maps, Change to | `spa-maps.py` |
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

Nothing is left out. Reset Round and Mute now do what they were for, and
Unban works with the mod's fixes.

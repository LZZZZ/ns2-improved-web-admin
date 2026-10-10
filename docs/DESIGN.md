# Design

What the project covers, how it is built and why, and what each tab does.

## Why a mod

The game ships the original 2012 panel (jQuery 1.7.2, jQuery UI 1.9,
Bootstrap 2; see [CURRENT-UI.md](CURRENT-UI.md)) as static files, over a
304-line Lua backend that already answers in JSON. A mod can replace both
without an engine change or a game-file edit, because
`Shared.SetWebRoot()` resolves through the mod filesystem and a mod can
shadow `lua/ServerWebInterface.lua`
([proof](CONSTRAINTS.md#shipping-as-a-mod)).

## Scope

| In scope | Out of scope |
| --- | --- |
| A workshop mod: `web/` front end plus `lua/` overrides | Any change to `server_linux` / `ns2.exe` |
| Parity with the 2012 panel, plus command output, the server log, recent players and real performance data | Replacing Shine's admin tooling |
| A corrected `ServerWebInterface.lua` | A new authentication scheme: the engine's HTTP Digest login is used as it is |
| | Anything that needs a game update to ship |

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Framework | **Preact + Vite + TypeScript** | The player table polls every few seconds and must keep scroll position, sort order and a half-typed filter, so keyed re-rendering is required. TypeScript catches the API's stringified booleans and hex mod ids; types mirror [openapi.yaml](openapi.yaml). |
| Layout | `panel/` source, `web/` built output, `lua/` the mod's Lua, `workshop/` the item's page | The workshop item is `web/`, `lua/` and `LICENSE`, nothing else: every joining client downloads it. |
| Build output | Committed | The item can be assembled without a toolchain. |
| Dev loop | `vite build --watch`, with the mock serving the built output | A dev server on another port is refused `403` by the engine's Origin rule, and a proxy would hide that rule and the no-404 fallthrough, the two places this API bites. |
| Lua changes | **Change the Lua wherever it improves the result** | The mod replaces `ServerWebInterface.lua` wholesale. Other game Lua may be wrapped or overridden too; a wrapper usually survives a game update, a shipped copy must be re-diffed against each. Keep the HTTP API backward compatible when that is cheap, so the 2012 panel still works (gate `mock-acceptance.py`). When breaking it, record why and update `openapi.yaml`, the mock and the fixtures in the same commit. |
| Stock servers | Require the mod; detect it and degrade loudly | The panel reads `mod_version` from the state blob, and on a stock server says what is unavailable. |
| Shine | **First-class** | Almost every server runs it, and it replaces ban handling, `ServerAdminPrint` and map rotation. Every tab works on both ([details](CONSTRAINTS.md#shine)). |
| Charts | **uPlot** | Canvas time series with cursor sync and drag-zoom. Tickrate, slowest tick, score and players share one unitless axis (all about 0-100); the legend carries the units. No dual y-axes. |
| Icons | Lucide (`lucide-preact`, ISC), tree-shaken | Each icon carries `title` and hidden text for hover, screen readers and the gates. |
| CSS | Hand-written, with custom properties | Dark by default; light and follow-the-system available. |
| Dependencies | Vendored, pinned, no CDN | Plain HTTP, possibly on an isolated network. |
| Size | A soft target of 1 MiB for `web/` | About 690 KB: 250 KB of script and style, 367 KB of minimaps fetched only on hover. Every joining client downloads it. |
| Images | PNG | In every MIME table the engine's binaries carry, and the engine sends `nosniff`. WebP is only in the newer network library's. |
| Browsers | Current Chrome and Firefox | Users are server operators. |

## What the panel deliberately does not do

Each is a defect of the 2012 panel, and easy to reintroduce:

- It never reports success it has not verified. On a stock server a
  command is "sent, unverified"; with the mod it shows what the command
  printed, or "ran, and printed nothing".
- It never renders a control it cannot honour: a bot's action buttons are
  disabled with the reason.
- It shows no IP or Steam id until asked, per row. Two exceptions, by
  design: Recent players shows IPs, since spotting a returning player under
  another account is what it keeps them for; and the Console shows the
  server's log verbatim, since it is the server's own record.
- It fetches nothing from a third party at runtime: no CDN, no web font,
  and Workshop thumbnails only when turned on.

## The tabs

"Needs the mod" means the tab does nothing useful on a server without it,
and says so.

| Tab | What it does |
| --- | --- |
| Players | One table per team under the game's team logos. Sort, filter, kick, ban, slay, move, eject, mute (Shine's `sh_gag`), and the round buttons. IPs and Steam ids masked until asked, per row. Bot buttons disabled, with the reason. Links to each player's Steam profile and ns2panel.com page. With the mod: Hive skill with the game's badge, and the marine, alien and commander figures on hover. On the 09-26+ engine: Family Sharing and rejected moves. |
| Recent players | Everyone seen in the last 24 hours (up to 100), connected or not, so a player who left can still be banned. Search by part of a name, a former name, any Steam id form or an IP. Needs the mod. |
| Bans | The bans in force, from the table that decides them (Shine's, under its ban plugin). Ban by any common Steam id form, unban per row. |
| Chat | The chat with team and time; send to all, marines or aliens. A send is confirmed by finding it in the chat. |
| Maps | The cycle and the available maps side by side. Drag or arrow to reorder, drag in to add, drag out to remove. Every change is written at once, re-read first so a concurrent change is not overwritten, and can be undone. Shine's per-map options and map groups survive. Warnings for a missing map, a mod map whose mod is not loaded, and a duplicate. A stock map's minimap on hover. Shine's mapvote explained. |
| Mods | Installed mods in mount order: which are loaded now, load or stop loading with every map, and whether each is on the ranked whitelist. |
| Workshop | Search the Workshop through the server, read a mod's details, install it. Thumbnails only when turned on in Settings. |
| Reserved Slots | The amount, and the slots by name. Shine's count when its plugin is on. |
| Performance | What `perfmon` measures, in 10 s windows on one time axis: tickrate, slowest tick, score and players, then frame time, late updates, entities and the Lua heap. With the engine's `tickstat` on: tick spacing, snapshot size against what `bwlimit` allows, choke, rate steps. Needs the mod for all but the stock readings. |
| Console | The server's `log-Server.txt`, filtered by kind and coloured, with the command line under it. A command shows what it printed; names and help are suggested as you type. Save writes what was read to a file. |
| Activity | Every command this page sent and what it printed, newest first. |
| Settings | Masking, refresh rates, theme, clock format, Workshop thumbnails, what is remembered, and the server's `tickstat` switch. Kept in the browser. |

## Next

- **Make the item public** once a populated round looks right: the
  visibility setting on its Steam page, or `tools/build-workshop.sh
  --visibility 0` and an upload.
- **Captures from a populated round** with the mod mounted: named players,
  teams and a commander, chat, performance under load, the log, a paged
  `getperf` reply.
- **Ranking.** Request whitelisting once the mod is public and has some
  mileage.
- **Engine additions** that would replace the mod's biggest workarounds:
  [CONSTRAINTS.md](CONSTRAINTS.md) items 6 and 18. Uninstalling mods is
  the only feature that needs one (REQUIREMENTS item 2).
- Optionally, offer the code for inclusion in the game.

# NS2 Improved Web Admin

A modern replacement for the Natural Selection 2 dedicated server's web
admin panel, shipped as a **workshop mod**: a new front end plus a
corrected `ServerWebInterface.lua`, mounted together.

> **Read this first.** This project was entirely vibe-coded: written by an
> AI coding assistant, directed and reviewed by a human. It is **still in
> development**: the Workshop item is an unlisted beta. It is
> provided **as is, with no warranty** of any kind. It runs Lua inside your
> game server and changes how that server handles bans, reserved slots and
> the map cycle. **Use it at your own risk**, test it on a server you can
> afford to break first, and keep backups of your config. Read
> [Security](#security) before you make the web admin reachable from
> anywhere but the server itself.

The panel the game ships is the original 2012 build: jQuery 1.7.2,
jQuery UI 1.9, Bootstrap 2 and a dark-hive theme. It is **static files
on disk**, not compiled into the engine, and its backend is 304 lines of
Lua that already answer in JSON. Replacing both needs no engine change:
`Shared.SetWebRoot()` resolves through the mod filesystem and a mod can
shadow `lua/ServerWebInterface.lua`, so one mod carries the panel and the
Lua fixes, with no game-file edits ([docs/CONSTRAINTS.md](docs/CONSTRAINTS.md#answered-the-whole-thing-can-ship-as-a-mod-verified-2026-09-05)).

## Status

The panel and the mod's Lua are built, on vanilla servers and on Shine
ones, and verified against a real dedicated server, the mock and the
OpenAPI spec. Every action the 2012 panel had is accounted for and gated
([docs/CURRENT-UI.md](docs/CURRENT-UI.md#where-each-2012-action-went-audited-2026-10-06)).

**Published as an unlisted beta, 0.1.0**: Workshop item
[3816039702](https://steamcommunity.com/sharedfiles/filedetails/?id=3816039702), hex `e3742516`. Anyone with the link can open it and
a server can mount it, but Workshop search does not list it. A dedicated
server downloaded it from the Workshop and served the panel and the Lua
from it on 2026-10-08
([CONSTRAINTS.md](docs/CONSTRAINTS.md#mounted-from-the-workshop-verified-2026-10-08)).
What is still open is in [Next](#next).

## Installing

The mod is on the Steam Workshop as
[NS2 Improved Web Admin](https://steamcommunity.com/sharedfiles/filedetails/?id=3816039702)
(item 3816039702, hex `e3742516`). Read [Security](#security) first, and
expect the server to be unranked while the mod is mounted.

1. Add `e3742516` to `mods` in the server's `MapCycle.json`, then change
   map or restart; the server downloads the item itself.
2. **Keep the server's log in its config directory**, so the mod can read
   it: start the server with `-logdir` set to the same directory as
   `-config_path`, or with neither flag, which is the engine's default
   layout and works as it is. Lua can open files only under the config
   directory. Without this, the Console tab cannot show the log and the
   Performance tab has none of the engine's own lines (`tickstat`,
   `perfmon:`); each says why, and everything else works. The engine also writes `dumps/` wherever the log goes.
   If you move the log out of the config directory later, delete the
   `log-Server.txt` left there: the panel spots the stale copy and says
   so, but shows nothing.
3. Open `/index.html` on the web admin port, as before.

## Screenshots

Taken against the [mock server](mock/README.md), so every player, IP and log
line is made up. Regenerate them with `tools/browser-checks/screenshots.py`.

**Performance**, with the engine's `tickstat` on: what `perfmon` measures
in 10 s windows, plus tick spacing and snapshot size against what
`bwlimit` allows.

![The Performance tab](docs/screenshots/performance.png)

**Players**, one table per team, with Hive skill and the game's skill
badges, Family Sharing, rejected moves, and Steam ids and IPs masked until
asked.

![The Players tab](docs/screenshots/players.png)

**Maps**, under Shine's mapvote: the cycle and the available maps side by
side, each change written at once.

![The Maps tab](docs/screenshots/maps.png)

**Mods**, in mount order, with whether each is loaded and on the ranked
whitelist.

![The Mods tab](docs/screenshots/mods.png)

**Console**: the server's own log, filtered by kind and coloured, with the
command line under it.

![The Console tab](docs/screenshots/console.png)

## The tabs

| Tab | What it does |
| --- | --- |
| Players | One table per team (Marines, Aliens, Ready room, Spectators), under the game's team logos. Sort, filter, kick, ban, slay, move, eject, mute (Shine's `sh_gag`), and the round buttons. IPs and Steam ids masked until asked, per row. A bot's buttons disabled, with the reason. With the mod: Hive skill with the game's skill badge, and the marine, alien and commander figures on hover. On the 09-26+ engine: Family Sharing and rejected moves. Links to the player's Steam profile and ns2panel.com page. |
| Recent players | Everyone seen in the last 24 hours (up to 100), connected or not, so a player who left can still be banned. Search by part of a name, a former name, any Steam id form or an IP. Links to each player's Steam profile and ns2panel.com page. Needs the mod. |
| Bans | The bans in force, from the table that decides them (Shine's, under its ban plugin). Ban by any common Steam id form, unban per row. |
| Chat | Read the chat with team and time, and send to all, marines or aliens. A send is confirmed by finding it in the chat. |
| Maps | The cycle and the available maps side by side. Drag or arrow to reorder, drag in to add, drag out to remove. Every change is written at once, re-read first so a cycle changed meanwhile is not overwritten, and can be undone. Shine's per-map options and map groups survive. Warnings for a map the server lacks, a mod map whose mod nothing loads, and a duplicate. A stock map's minimap on hover. Shine's mapvote explained. |
| Mods | The installed mods in mount order, which are loaded now, load or stop loading with every map, and whether each is on the ranked whitelist. |
| Workshop | Search the Workshop through the server, read a mod's details, install it. Thumbnails only when turned on in Settings. |
| Reserved Slots | The amount, and the slots by name. Shine's count when its plugin is on. |
| Performance | What `perfmon` measures, in 10 s windows, on one time axis: tickrate, the slowest tick, score and players, then frame time, late updates, entities and the Lua heap. With the engine's `tickstat` on, its lines too: tick spacing, snapshot size against what `bwlimit` allows, choke, rate steps. Needs the mod for all but the vanilla readings. |
| Console | The server's own `log-Server.txt`, filtered by kind and coloured, with the command line under it. A command shows what it printed. Command names and their help are suggested as you type. Save writes what was read to a file. |
| Activity | Every command this page sent and what each printed, newest first. |
| Settings | Masking, refresh rates, theme, clock format, Workshop thumbnails, what is remembered, and the server's `tickstat` switch. Kept in the browser. |

## Scope

| In scope | Out of scope |
| --- | --- |
| A workshop mod: `web/` front end plus `lua/` overrides | Any change to `server_linux` / `ns2.exe` |
| Parity with the 2012 panel's six tabs, plus what it could not do: command output, the server log, recent players, real performance data | Replacing Shine's admin tooling |
| A corrected `ServerWebInterface.lua` | A new authentication scheme: the panel uses the engine's HTTP Digest login as it is |
| | Anything that needs a game update to ship |

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Framework | **Preact + Vite + TypeScript** | The player table polls every few seconds and must keep scroll position, sort order and a half-typed filter, so keyed re-rendering is the requirement. TypeScript because the API's stringified booleans and hex mod ids are exactly the traps a compiler should catch; types mirror [docs/openapi.yaml](docs/openapi.yaml). |
| Layout | `panel/` source, `web/` built output, `lua/` the mod's Lua, `workshop/` the item's page | The workshop item is `web/`, `lua/` and `LICENSE` verbatim, and nothing else: every joining client downloads it. |
| Build output | Committed | It ships inside the mod as static content, so the item can be assembled without a toolchain. |
| Dev loop | `vite build --watch` with the mock serving the built output | A Vite dev server on another port is refused `403` by the engine's Origin rule, and a proxy around it would hide both that rule and the no-404 fallthrough, the two places this API bites. |
| Lua changes | **Change the Lua wherever it improves the result** | The mod replaces `ServerWebInterface.lua` wholesale, so the vanilla file is a starting point, not something to preserve. Other game Lua may be wrapped or overridden too; a wrapper usually survives a game update, a shipped copy has to be re-diffed against each one. **Keep the HTTP API backward compatible when that costs little**, so the 2012 panel keeps working against the mod (gate `mock-acceptance.py`). Break it when there is a good reason, record the reason, and move `openapi.yaml`, the mock and the fixtures in the same commit. |
| Stock servers | Require the mod; detect it and degrade loudly | The panel reads `mod_version` from the state blob. On a stock server it says plainly what is unavailable rather than implying it worked. |
| Shine | **First-class** | Almost every server runs it, and it replaces ban handling, `ServerAdminPrint` and map rotation. The mod reports Shine and its relevant plugins in the state blob, and every tab works on both. See [docs/CONSTRAINTS.md](docs/CONSTRAINTS.md#shine-2026-09-27). |
| Charts | **uPlot** | Canvas, time series, cursor sync and drag-zoom built in. Tickrate, the slowest tick, score and players share one chart and one unitless axis, since all four sit in about 0-100; the legend and readouts carry the units. No dual y-axes. |
| Icons | Lucide (`lucide-preact`, ISC), tree-shaken | Each icon carries `title` and hidden text, so hover, screen readers and the gates read the words. |
| CSS | Hand-written, with custom properties | A component framework is not needed. Dark by default, light and follow-the-system available. |
| Dependencies | Vendored, pinned, no CDN | Plain HTTP on a possibly isolated network. See [docs/CONSTRAINTS.md](docs/CONSTRAINTS.md#no-cdn). |
| Size | A soft target of 1 MiB for `web/` | About 650 KB today: 250 KB of script and style, and 367 KB of minimaps fetched only on hover. Every joining client downloads the mod, so growth is worth noticing. |
| Images | PNG | PNG is in every MIME table the engine's binaries carry, and the engine sends `nosniff`, so the type has to be right. WebP is only in the newer network library's table. |
| Browsers | Current Chrome and Firefox | Server operators, not players. |

## What the panel deliberately does not do

Each of these is a defect in the panel being replaced, and would be easy
to reintroduce:

- It never reports success it has not verified. On a stock server a
  command is "sent, unverified"; with the mod it is what the command
  printed, and "ran, and printed nothing" when it printed nothing.
- It never renders a control it cannot honour. A bot's action buttons are
  disabled and carry the reason.
- It shows no IP or Steam id until asked, and asks per row. Two exceptions,
  by design: the Recent players tab shows IPs in the clear, because
  spotting a returning player under another account is what it keeps them
  for (Steam ids stay masked there); and the Console shows the server's log
  verbatim, identifiers and chat included, because it is the server's own
  record.
- It fetches nothing from a third party at runtime: no CDN, no web font,
  and Workshop thumbnails only when turned on.

## Security

The engine's web admin speaks **plain HTTP**, with or without this mod.
Its login is HTTP Digest, so the password itself never crosses the wire,
but everything after the login does, in the clear: player names, Steam
ids and IP addresses, chat, the server's log, and every command an admin
runs. Anyone on the network path can read it, and a captured Digest
exchange can be attacked offline to guess the password. **Do not expose
the web admin port to the internet as it is.** The mod cannot add HTTPS:
the web server is the engine's.

1. **Bind it to loopback.** `-webdomain 127.0.0.1` makes the web server
   listen there only. Then reach it through one of the next two.
2. **An SSH tunnel** is the simplest, with nothing to set up on the server:

   ```
   ssh -N -L 8080:127.0.0.1:8080 you@your-server
   ```

   then open `http://127.0.0.1:8080/index.html` on your own machine. The
   traffic is encrypted by SSH, and the browser's `Host` and `Origin` are
   `127.0.0.1:8080`, which the engine accepts as they are.
3. **An HTTPS reverse proxy** (nginx, Caddy, Apache, ...) suits several
   admins and a bookmark: TLS ends at the proxy, and the engine stays on
   loopback. No proxy configuration is tested in this repository, but the
   engine's rules it has to satisfy were measured
   ([CONSTRAINTS.md](docs/CONSTRAINTS.md#what-the-origin-rule-actually-compares-verified-2026-09-05)):
   - **`Origin` is compared with `Host`.** A browser sends your public
     site as the `Origin` of every `POST` (the panel posts map cycle
     changes), so the engine refuses it unless the two match. Either pass
     the public `Host` through unchanged, or send a loopback `Host` and
     rewrite a matching `Origin` to `http://127.0.0.1:<port>`. Rewrite
     only an `Origin` that is your own site, and refuse any other at the
     proxy: rewriting every `Origin` would switch off the engine's
     protection against cross-site requests.
   - **With no login configured, `Host` must be `localhost` or an IP
     address** (09-25 and later), so the proxy must send a loopback
     `Host`.
   - **Who checks passwords.** Either keep the engine's own login (Digest
     through the proxy; not tested here), or let the proxy authenticate
     and run the engine with no login on loopback. In the second case the
     proxy is the only lock, so make sure nothing else can reach the
     engine's port.
   - **The failed-login lockout is per address.** Ten failed logins in a
     minute lock that address out for a minute, and behind a proxy every
     admin shares the proxy's address.
   - Nothing else is needed: the panel makes only `GET` and `POST`
     requests to its own origin, with no WebSockets.

   The mock applies the same `Origin` and `Host` rules
   (`node mock/server.js --web web`, without `--auth`), so a proxy
   configuration can be tried against it first.
4. **Prefer `-webusers` to `-webpassword`.** `-webusers` reads a Digest
   `.htpasswd` file. A password on the command line can be read by any
   local user through the process list, and it ends up in crash dumps.
5. If the web server must listen on a public address, firewall its port
   to the addresses that need it, and feed the engine's
   `WebAdmin - rejected request from <address>` log lines to fail2ban.

The engine's changelog notes that the same web server also serves the
server's mod backup downloads. If your setup relies on those, check what
binding it to loopback does to them first.

## The mod

| Directory | What it is |
| --- | --- |
| `panel/` | Front-end source: Preact + Vite + TypeScript. |
| `web/` | The built panel. Committed, and the mod's web root verbatim. |
| `lua/` | The mod's Lua. `ServerWebInterface.lua` shadows the game's copy: console capture with `runcommand` and `getconsole`, `getbans`, a recent-players list kept across map changes (`getrecentplayers`) that also names Shine bans of absent players, Shine detection and `mod_version` in the state blob, a map cycle read from the file and checked before it is written, `getmapvote` for Shine's mapvote, `getperf` for what `perfmon` logs, in 10 s windows served in pages of 60, with the engine's own `tickstat` lines, rate steps, bwlimit warning and `perfmon:` blocks read from its log, a map's load time, the engine's ranking verdict (`ranking_active`) and each player's Hive skill and skill tier in the state blob, `getlog` for the server's own log by byte offset (checking that the file is the one being written), which installed mods are mounted now (`active`), a workshop search that settles and says so and an `installmod` that answers, the ranked-mod whitelist read from Steam (`getwhitelist`), and five bug fixes -- reserved slots, `sv_unban`, expired bans, an unban that never reached the connection check, and a slot removal that was never saved. |
| `workshop/` | The Workshop page, not uploaded as content: `preview.jpg` (a crop of the Performance screenshot), `description.bbcode` (`{version}` becomes `kModVersion`; a line starting `{if-id}` is kept only once the item id is known and one starting `{if-no-id}` only before, with `{id}` and `{hexid}` filled in), and `publishedfileid` once the item exists. |

## Documentation index

| File | What it is |
| --- | --- |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | What the replacement has to do, from using the shipped panel. Each item carries a feasibility verdict tested against a real server, and what was built. |
| [docs/API.md](docs/API.md) | The web admin HTTP API as actually implemented, read from `ServerWebInterface.lua`. Every request type, its parameters and its response shape. |
| [docs/openapi.yaml](docs/openapi.yaml) | The same API as an OpenAPI 3.1 spec: every request type, parameter, response schema and refusal status. Each response names the fixtures it was read from, and `tools/check-openapi.py` validates them against it. |
| [docs/CURRENT-UI.md](docs/CURRENT-UI.md) | The 2012 panel: file inventory, the six tabs, the defects found in it, and where each of its actions went. |
| [docs/CONSTRAINTS.md](docs/CONSTRAINTS.md) | What the 2026-09-03 engine hardening allows and forbids, the Lua changes the mod ships, what shipping as a mod costs, and the engine additions that would simplify it. |
| [docs/SERVER-COST.md](docs/SERVER-COST.md) | What the mod's Lua costs the server: how much of the vanilla file changed, what runs every tick and per request, measured with the game's dkjson. |
| [docs/TESTING.md](docs/TESTING.md) | A local dedicated server for testing: how to build one, run it, mount this repo's Lua on it, capture fixtures, and the traps. |
| [mock/README.md](mock/README.md) | The mock server: what it reproduces, the bugs it reproduces on purpose, and how faithfulness is proved. |

## Building and testing

```
cd panel && npm install
npx vite build                     # or: npx vite build --watch

# from the repo root: a stock server, one running this mod's Lua, and
# one running the mod's Lua and Shine
node mock/server.js --port 8091 --web web
node mock/server.js --port 8094 --web web --mod --perf-window 2
node mock/server.js --port 8096 --web web --mod --shine
# a modded server's map cycle, maps and mods, for the Maps tab
node mock/server.js --port 8099 --web web --mod --shine=ban,reservedslots,mapvote --maps=modded
# a server whose log the mod cannot reach, for the Console tab
node mock/server.js --port 8100 --web web --mod --log=off
# a server with no chat buffer, and one on the 09-26+ engine
node mock/server.js --port 8101 --web web --no-chat-buffer
node mock/server.js --port 8102 --web web --mod --beta-players
# one that cannot read the whitelist from Steam
node mock/server.js --port 8103 --web web --mod --whitelist=fail --whitelist-delay 300
```

Then open `http://127.0.0.1:8091/index.html`. Source is `panel/`, the
build lands in `web/`, and `web/`, `lua/` and `LICENSE` are the workshop
item, staged by `tools/build-workshop.sh`. There
is no dev server: development runs against the mock serving the real
build, in production shape.

Everything is gated, and each gate is a script rather than a claim:

```
tools/browser-checks/run-all.sh --stock-web <server>/ns2/web
python3 tools/check-openapi.py
for h in tools/spikes/*-harness.lua; do luajit "$h" --core <server>/core/lua; done
```

`run-all.sh` runs every browser gate, one at a time, each against freshly
started mocks; name gates to run only those. `--stock-web` is a dedicated
server install's `ns2/web`, the shipped 2012 panel, which only
`mock-acceptance` needs. Run the gates and `check-openapi.py` before and
after any change to `lua/`, `mock/` or `panel/`, and the LuaJIT harnesses
after any change to `lua/`. A harness reads the game's own dkjson from the
install's `core/lua`, named by `--core`. Most browser gates
assert *wording*, not just rendering: no check passes if the panel ever
reports success it did not verify.

## Tools

| File | What it does |
| --- | --- |
| `tools/capture-fixtures.sh` | Walk every request type against a real server into `fixtures/live/`. `--env FILE` names a shell file that sets `WEBUSER`, `WEBPASS` and `WEBPORT`. `--mutating` also exercises the three writes; `--mod` also captures the mod's own request types, which needs `lua/` mounted. |
| `tools/redact-fixtures.py` | Rewrite `fixtures/live/` into committable `fixtures/` with stable fake names, SteamIDs and `0.0.0.0`, inside `getlog`'s log lines too, where `--path OLD=NEW` also rewrites the capturing machine's directories (and any home directory left becomes `/home/user`). `--src` picks a subdirectory, so one capture can be redacted without rewriting the rest. |
| `tools/check-openapi.py` | Validate every committed fixture against [docs/openapi.yaml](docs/openapi.yaml). Reports schema violations, fields a capture has that the spec does not describe, and fixtures no response claims. Needs PyYAML. |
| `tools/make-minimaps.sh` | `tools/make-minimaps.sh <server>/ns2/maps/overviews`. Convert the stock maps' overviews (`*.tga`) into the Maps tab's minimaps, `panel/src/minimaps/*.png`: trimmed, 320 px, 64-colour PNG. Re-run after a game update that changes a map. |
| `tools/make-skill-tiers.sh` | `tools/make-skill-tiers.sh <client>/ns2/ui/skill_tier_icons.dds`. Convert the game's skill badges (from the **client** install: the server has no UI art) into the Players tab's sprite sheet, `panel/src/assets/skill-tiers.png`. Re-run if a game update changes the badges. |
| `tools/make-team-logos.sh` | `tools/make-team-logos.sh <client>/ns2/ui`. Convert the game's marine and alien logos (`logo_marine.dds`, `logo_alien.dds`, from the client install) into the Players tab's team headings, `panel/src/assets/logo-marines.png` and `logo-aliens.png`. |
| `tools/make-commands.py` | Regenerate `panel/src/commands.json`, what the Console's command line suggests: the game's admin commands and Shine's, with their arguments and help, read from a server install's Lua (`--lua <server>/ns2/lua --shine <Shine's lua/shine>`), plus a hand-kept list of engine commands. Re-run after a game or Shine update. |
| `tools/make-whitelist.py` | Regenerate `panel/src/whitelist.json`, the dated copy of the ranked-mod whitelist the panel ships, from the Workshop pages the mod's `getwhitelist` reads (no API key; needs curl). The panel falls back on it without the mod or when the server could not read Steam, and shows its date. Re-run before a release. |
| `tools/build-workshop.sh` | Stage the Workshop item in `build/workshop/` (gitignored): `content/` with only `web/`, `lua/` and `LICENSE`, the preview, and a `workshopitem.vdf` for `steamcmd +workshop_build_item`. Refuses uncommitted changes to what it ships (`--allow-dirty` overrides). A new item (no `workshop/publishedfileid`) needs `--visibility`: 3 is unlisted, for testing before going public. `--changenote` defaults to the version. Uploads nothing; prints the steamcmd command, since the login is interactive. |
| `tools/nonce-under-load.py` | Poll one digest nonce at the panel's own cadence until the server refuses it, then re-auth with the nonce the refusal carries. Answers "does a long poll need re-authentication logic?" without a browser. |
| `mock/server.js` | The mock NS2 web admin. `node mock/server.js --web web` serves the API and the built panel; `--web <server>/ns2/web` serves the shipped 2012 one instead. `--mod` makes it behave as a server running this mod's Lua, `--shine` as one running Shine, `--maps=modded` gives it a modded server's map cycle. See [mock/README.md](mock/README.md). |
| `tools/browser-checks/run-all.sh` | Every gate below, one at a time, each against freshly started mocks (the ports above). `--stock-web <server>/ns2/web` is the shipped 2012 panel for `mock-acceptance`. Name gates to run only those; a gate takes `name@ENV=value ...` for its environment. Logs land in `$LOG` (default `${TMPDIR:-/tmp}/improved-webadmin-gates`). |
| `tools/browser-checks/spa-players.py` | Gate: the Players tab in headless Chrome against the mock. Asserts masking, disabled bot controls, honest command reporting, sort/filter surviving polls, no third-party requests, icon buttons with their words hidden, the Activity tab and each tab's one-line confirmation, the Shared column, the Steam profile and ns2panel.com links (never for bots, the id still masked) and the mod's Skill column with its team and commander figures on hover. `SPA_EXPECT_MOD=1` asserts the mod-server wording instead of the stock wording. |
| `tools/browser-checks/spa-console.py` | Gate: the Console tab's command line, against a `--mod` mock, a `--mod --shine` one and a stock one. Asserts that a failing command shows its reason under the input, that one which printed nothing says so rather than claiming success, an unknown command named as indistinguishable, history on the arrow keys, another client's command reaching the log, the last map change's time from the server and moved by a map change, command names suggested as typed (by prefix or any part, Tab, Enter on an arrowed pick or a click to complete, Escape to close), the arguments and help under the input, Shine's commands only on a Shine server, anything typed still sent, and on a stock server the tab explaining itself with no input it cannot honour. |
| `tools/browser-checks/spa-log.py` | Gate: the Console tab's log against `--mod`, stock and `--mod --log=off`. Asserts no read before the tab opens or after it closes (stock never asked), the first read the file's last 64 KB from a line, Load earlier to the start with every line once, a line written elsewhere arriving by the next poll and idle polls carrying nothing, a half-written line held until complete, a 700 KB burst caught up with no gap and no reply over 64 KB, a cut file, a restart and a tab away for megabytes each saying so, a map change not interrupting it, filters with counts (Engine and Other off at first, kept in the browser) and search, following the end only when the reader is there, IPs and Steam ids shown as written, markup as text, a stale copy refused and an unreachable log explained, each kind in its colour, chat in its speaker's team colour, Save writing every line read, and log refresh off reading only on Read now. |
| `tools/browser-checks/spa-bans.py` | Gate: the Bans tab against four mocks -- stock, `--mod`, `--mod --shine` and stock with `--shine`. Asserts expired bans hidden, Unban disabled on stock with its reason, what each ban and unban printed, `sh_banid`/`sh_unban` under Shine, `6e+24` read as permanent, rows that hold still when Shine reshuffles the list, and no `;` reaching a command line. |
| `tools/browser-checks/spa-slots.py` | Gate: the Reserved Slots tab against stock, `--mod` and `--mod --shine=ban,reservedslots,mapvote`. Asserts the amount capped at max players, set and read back, slot names made into one console argument, duplicate names flagged, and Shine's count used with the vanilla list read-only when its plugin is on. |
| `tools/browser-checks/spa-recent.py` | Gate: the Recent players tab against stock, `--mod` and `--mod --shine`. Asserts the stock server is explained and never asked, the window and capacity stated from the reply, search by part of a name, a former name, a STEAM_ id and an IP, IPs shown and Steam ids masked beside the Steam profile and ns2panel.com links, a kicked player turning to "left", Ban sent as `sv_ban` or `sh_banid` with `;` stripped, a Shine ban stored under the player's name while vanilla keeps `Unknown`, a banned row's Ban disabled with its reason, and torn, unreadable or failing saves reported. |
| `tools/browser-checks/spa-maps.py` | Gate: the Maps tab against stock, `--mod` and `--mod --shine=ban,reservedslots,mapvote --maps=modded`. Asserts every change is a `POST` with everything in the body, written and read back (stock: reported as the server's copy, not the file), Undo, drag and arrow reorder, a map dragged in landing where it is dropped and one dragged out removed, a cycle changed behind the panel left alone, a refused write reported and reverted, a mod map added with its mod, Shine's per-map options and map groups surviving every write, the missing-mod, unknown-map and duplicate warnings, mode disabled under Shine's mapvote and Shine's next map, `;` stripped from Change to, and a stock map's minimap on hover (fetched only then; a mod map says it has none). |
| `tools/browser-checks/spa-mods.py` | Gate: the Mods tab against stock, `--mod` and `--mod --shine=ban,reservedslots,mapvote --maps=modded`. Asserts the table in mount order (the engine's two, then the cycle's, numbered, a missing id in its place), the hex id selectable and the workshop id right, Load with every map appending as a `POST` and saying it loads at the next map change (then loaded after one), Stop loading saying it unloads, Undo, a cycle changed behind the panel left alone, the engine's own two mods explained, map mods left to the Maps tab, a global map mod its maps depend on asked about first, Shine's options, groups and per-map mods surviving, a cycle id that is not installed shown and removable, stock marking nothing loaded, no workshop search at all, and the whitelist: the shipped copy and why on stock, the server's read replacing it on `--mod`, a hotfix mod counted as whitelisted, and a failed read (`--whitelist=fail`, port 8103) falling back with its reason. |
| `tools/browser-checks/spa-workshop.py` | Gate: the Workshop tab against the same three. Asserts no search before the tab is opened and no polling once one settles, the 50-result cap stated with a link to the Steam Workshop and no paging offered, an empty result read as no matches or no Steam, a description with markup and BBCode shown as text and nothing run, the ids, author and Steam's problem flag in the details, Install asking first and sent as a `POST`, "downloading" until the installed list has it and then "installed", an install that never arrives never called installed, Open in Mods filtering that tab, installed and loaded results marked, each result marked whitelisted or not, a search with no answer given up (with Retry, and the stock caveat), and thumbnails fetched only when turned on in Settings, with no referrer. |
| `tools/browser-checks/spa-perf.py` | Gate: the Performance tab against `--mod --perf-window 2`, stock and `--mod --log=off`. Asserts no polling before the tab opens or after it closes, `getperf` read with a cursor and every window held exactly once, a history longer than 60 windows fetched page after page at once, the axis and the comparison following the configured tickrate (60, not 30), a bad score shown as bad in words and colour and an interp fail flagged, drag-to-zoom reaching every chart and a hover reading out the same moment in another, a map change keeping the earlier map's windows, a clean rebuild on a theme switch, and on stock only `getperfdata`, replaced on every read rather than appended. Then tickstat: off until Settings turns it on, and on only once the server's log says so; every line held once; a snapshot p99 over what bwlimit allows an error with the bwlimit that fixes it (the engine's full-game floor when that is higher); the engine's warning shown; a map change keeping the lines; Stop confirmed the same way; an unreadable log explained. |
| `tools/browser-checks/spa-settings.py` | Gate: the Settings tab against `--mod --perf-window 2` and stock. The one gate that keeps localStorage across loads. Asserts the defaults, the tab working while the server cannot be reached, the server-state and chat refresh counted from the network and independent of each other, dark, light and a system theme that follows the OS both ways and rebuilds the charts, the clock setting in the footer, a ban's date and the perf axis (en-US in Sao Paulo), everything kept across a reload with the last tab reopened, the tabs' shortcuts writing the same values, bad stored fields defaulted one by one, storage that throws, a change from another page followed at once, and Reset asking first. |
| `tools/browser-checks/spa-chat.py` | Gate: the Chat tab against `--mod`, stock, `--mod --shine` and `--no-chat-buffer`. Asserts reads with a cursor on the mod and without on stock (which it says keeps 20, with no times), team chat marked and Steam ids masked, a send confirmed from the chat itself (Shine's `sh_say` prints only a receipt), nothing shown twice, a flood reported as dropped, a map change said, a gagged player's chat never arriving, and a server with no chat buffer explained. |
| `tools/browser-checks/mock-acceptance.py` | Gate: the *shipped* 2012 panel still runs against the mock (a stock mock on 8090 serving `--stock-web`). |
| `tools/browser-checks/screenshots.py` | Retake the README's screenshots (`docs/screenshots/`) in headless Chrome against fresh mocks on ports 8140-8143, with the panel's default settings. Name shots to retake only those. |
| `tools/browser-checks/` | The rest drive the *shipped* panel in headless Chrome over the DevTools protocol, for the questions only a browser answers: `perf-browser.py` (does the 2012 Performance tab really throw?), `perf-shot.py` (screenshot it), `load-cost.py` (what one page load costs, on and off the server) and `fetch-reauth.py` (does a long `fetch()` poll survive nonce expiry without a prompt?). `cdp.py` is the shared client. Needs `websockets` and `google-chrome`; the ones that talk to a real server read `WEBUSER`/`WEBPASS`/`WEBPORT` from the environment. |
| `tools/spikes/` | Probes for a real server and off-server LuaJIT harnesses for the mod's Lua. The harnesses -- `maps-harness.lua` (which also covers `getinstalledmodslist`), `recent-players-harness.lua`, `workshop-harness.lua` (`getmods`, `installmod`), `perf-harness.lua` (`getperf`), `tickstat-harness.lua` (`getperf`'s engine lines, over real 09-27 lines in `tickstat-rig-20260928.txt`), `log-harness.lua` (`getlog`), `chat-harness.lua` (the chat ring and `getchatlist&since=`), `console-harness.lua` (the console capture with Shine's copies to admins), `state-harness.lua` (the state blob's per-player additions) and `whitelist-harness.lua` -- run with `luajit` and no server. `server-cost-bench.lua` times the per-tick hook and the heavier requests after an hour on one map ([docs/SERVER-COST.md](docs/SERVER-COST.md)). The `make-*-probe.sh` scripts build the probes. See [docs/TESTING.md](docs/TESTING.md). |

## Source of truth

Read from a dedicated server install, not from documentation:

- `ns2/web/` -- the panel as shipped.
- `ns2/lua/ServerWebInterface.lua` -- the whole backend, 304 lines.
- `CHANGELOG.md` inside the 2026-09-03 engine drop
  (`ns2-linux-ship-344-26-09-03.zip`) -- the web server hardening this has
  to live with.

A dedicated server install is a steamcmd tree; hand-edits there are lost
on `app_update 4940 validate`. Nothing in this project edits it.

## Next

- **Make the item public** once a populated round looks right:
  the visibility setting on the item's Steam page, or
  `tools/build-workshop.sh --visibility 0` and an upload.
- **Captures from a populated round** with the mod mounted: players with
  names, teams and a commander, chat, performance under load, the log,
  and a paged `getperf` reply.
- **Ranking.** A server loses ranked status while a non-whitelisted mod is
  mounted, this one included. Whitelisting can be requested once the mod
  is published and has some mileage.
- **Engine additions** that would replace the mod's biggest workarounds
  are listed in [docs/CONSTRAINTS.md](docs/CONSTRAINTS.md) items 6 and 18.
  A mod-uninstall binding ([docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
  item 2) is the only feature that needs one.
- Optionally, offer the code for inclusion in the game. The mod works
  either way.

## License

The project's own code is under the [MIT License](LICENSE). Some files are
not ours to license and keep their owners' terms: the vanilla code in
`lua/ServerWebInterface.lua` (Unknown Worlds Entertainment), art taken
from Natural Selection 2, and the bundled libraries, whose notices ship in
`web/THIRD-PARTY-LICENSES.txt`. [LICENSE](LICENSE) lists them all.

This project is not affiliated with or endorsed by Unknown Worlds
Entertainment or Valve.

## House rules

- Never commit player data. Live captures go in `fixtures/live/`, which
  is gitignored -- server state includes names, SteamIDs and **IP addresses**.
- Never commit web admin credentials. The tools read `WEBUSER` and
  `WEBPASS` from the environment.

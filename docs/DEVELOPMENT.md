# Development

How the repository is laid out, how to build and test it, and the tools.
Testing against a real dedicated server is in [TESTING.md](TESTING.md).

## Layout

| Directory | What it is |
| --- | --- |
| `panel/` | Front-end source: Preact + Vite + TypeScript. |
| `web/` | The built panel, committed; the mod's web root verbatim. |
| `lua/` | `ServerWebInterface.lua`, shadowing the game's. What it adds is in [API.md](API.md#what-the-mod-adds), why in [CONSTRAINTS.md](CONSTRAINTS.md). |
| `mock/` | The mock server ([mock/README.md](../mock/README.md)). |
| `fixtures/` | Redacted responses captured from real servers. |
| `tools/` | Gates, generators, probes and harnesses (below). |
| `workshop/` | The Workshop page, not uploaded as content: `preview.jpg`, `description.bbcode` (`{version}` becomes `kModVersion`; a line starting `{if-id}` is kept only once the item id is known, `{if-no-id}` only before, with `{id}` and `{hexid}` filled in), and `publishedfileid`. |

The Workshop item is `web/`, `lua/` and `LICENSE`, staged by
`tools/build-workshop.sh`.

## Building and testing

```
cd panel && npm install
npx vite build                     # or: npx vite build --watch

# from the repo root: a stock server, one running this mod's Lua, and
# one running the mod's Lua and Shine
node mock/server.js --port 8091 --web web
node mock/server.js --port 8094 --web web --mod --perf-window 2
node mock/server.js --port 8096 --web web --mod --shine
# a modded server's map cycle, maps and mods
node mock/server.js --port 8099 --web web --mod --shine=ban,reservedslots,mapvote --maps=modded
# a server whose log the mod cannot reach
node mock/server.js --port 8100 --web web --mod --log=off
# no chat buffer; the 09-26+ engine's player fields
node mock/server.js --port 8101 --web web --no-chat-buffer
node mock/server.js --port 8102 --web web --mod --beta-players
# a failed whitelist read
node mock/server.js --port 8103 --web web --mod --whitelist=fail --whitelist-delay 300
```

Then open `http://127.0.0.1:8091/index.html`. There is no dev server:
development runs against the mock serving the real build
([why](DESIGN.md#design-decisions)).

Every claim is a gate script:

```
tools/browser-checks/run-all.sh --stock-web <server>/ns2/web
python3 tools/check-openapi.py
for h in tools/spikes/*-harness.lua; do luajit "$h" --core <server>/core/lua; done
```

Run the browser gates and `check-openapi.py` before and after any change
to `lua/`, `mock/` or `panel/`, and the LuaJIT harnesses after any change
to `lua/`. `run-all.sh` runs each gate against freshly started mocks on
the ports above; name gates to run only those (`name@ENV=value ...` sets a
gate's environment). `--stock-web` is a server install's `ns2/web`, the
2012 panel, used only by `mock-acceptance`. Logs go to `$LOG` (default
`${TMPDIR:-/tmp}/improved-webadmin-gates`). The harnesses load the game's
dkjson from the install's `core/lua`. Most gates assert the panel's
*wording*: no check passes if the panel reports success it did not
verify.

## Tools

| File | What it does |
| --- | --- |
| `tools/build-workshop.sh` | Stage the Workshop item in `build/workshop/` (gitignored): `content/` with `web/`, `lua/` and `LICENSE`, the preview, and a `workshopitem.vdf` for `steamcmd +workshop_build_item`. Refuses uncommitted changes to what it ships (`--allow-dirty`). A new item needs `--visibility` (3 is unlisted). `--changenote` defaults to the version. Uploads nothing; prints the steamcmd command, since the login is interactive. |
| `tools/capture-fixtures.sh` | Walk every request type against a real server into `fixtures/live/` ([TESTING.md](TESTING.md#capturing-fixtures)). |
| `tools/redact-fixtures.py` | Rewrite `fixtures/live/` into committable `fixtures/` with stable fake names, SteamIDs, IPs and paths. |
| `tools/check-openapi.py` | Validate every fixture against `docs/openapi.yaml`: schema violations, undescribed fields, unclaimed fixtures. Needs PyYAML. |
| `tools/make-minimaps.sh` | `<server>/ns2/maps/overviews` → `panel/src/minimaps/*.png` (320 px, 64 colours). Re-run when a game update changes a map. |
| `tools/make-skill-tiers.sh` | `<client>/ns2/ui/skill_tier_icons.dds` (client install; the server has no UI art) → `panel/src/assets/skill-tiers.png`. |
| `tools/make-team-logos.sh` | `<client>/ns2/ui` (`logo_marine.dds`, `logo_alien.dds`) → `panel/src/assets/logo-marines.png`, `logo-aliens.png`. |
| `tools/make-commands.py` | Regenerate `panel/src/commands.json`, the Console's suggestions: the game's and Shine's admin commands with arguments and help (`--lua <server>/ns2/lua --shine <Shine's lua/shine>`), plus a hand-kept list of engine commands. Re-run after a game or Shine update. |
| `tools/make-whitelist.py` | Regenerate `panel/src/whitelist.json`, the dated whitelist copy the panel falls back on, from the same Workshop pages `getwhitelist` reads (needs curl). Re-run before a release. |
| `tools/nonce-under-load.py` | Poll one Digest nonce at the panel's cadence until the server refuses it, then re-authenticate. |
| `tools/browser-checks/run-all.sh` | Run the gates, above. |
| `tools/browser-checks/spa-*.py` | One gate per tab, in headless Chrome against the mocks: `spa-players`, `spa-recent`, `spa-bans`, `spa-chat`, `spa-maps`, `spa-mods`, `spa-workshop`, `spa-slots`, `spa-perf`, `spa-console` (command line), `spa-log` (the Console's log), `spa-settings`. Each script's docstring lists what it asserts. |
| `tools/browser-checks/mock-acceptance.py` | Gate: the shipped 2012 panel still runs against the stock mock. |
| `tools/browser-checks/screenshots.py` | Retake the README's `docs/screenshots/` against fresh mocks on ports 8140-8143. Name shots to retake only those. |
| `tools/browser-checks/` (others) | Drive the shipped panel over the DevTools protocol: `perf-browser.py`, `perf-shot.py`, `load-cost.py` (what a page load costs), `fetch-reauth.py` (a long `fetch()` poll across nonce expiry). `cdp.py` is the shared client. Need `websockets` and `google-chrome`; those that talk to a real server read `WEBUSER`/`WEBPASS`/`WEBPORT`. |
| `tools/spikes/` | Probes for a real server, LuaJIT harnesses for the mod's Lua, and `server-cost-bench.lua` ([TESTING.md](TESTING.md#probes-harnesses-and-the-benchmark)). |

## Source of truth

Read from a dedicated server install, not from documentation:

- `ns2/web/`: the 2012 panel.
- `ns2/lua/ServerWebInterface.lua`: the whole stock backend.
- `CHANGELOG.md` in the 09-03 engine drop (`ns2-linux-ship-344-26-09-03.zip`):
  the web server hardening.

A server install is a steamcmd tree; `app_update 4940 validate` undoes
hand-edits. Nothing in this project edits it.

## House rules

- Never commit player data. Live captures go in `fixtures/live/`
  (gitignored): server state includes names, SteamIDs and **IP
  addresses**.
- Never commit web admin credentials. The tools read `WEBUSER` and
  `WEBPASS` from the environment.

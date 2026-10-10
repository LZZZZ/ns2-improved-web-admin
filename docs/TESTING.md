# Testing on a real server

"The rig" is a real NS2 dedicated server on your own machine, used to
capture fixtures and to check the panel and the mod's Lua against the
engine. Day-to-day work runs against the [mock](../mock/README.md); boot
the rig when only the real engine can answer.

Keep it outside this repository: it is about 3.5 GB.

## Building one

```bash
steamcmd.sh +force_install_dir <rig>/serverfiles +login anonymous \
            +app_info_update 1 +app_update 4940 validate +quit
<rig>/serverfiles/steam-runtime/setup.sh --host=amd64 --target=amd64 --release --auto-update
```

Anonymous login works. Without `+app_info_update 1`, `app_update 4940`
fails with `Failed to install app '4940' (Missing configuration)`. The
download is 3.6 GB, about three minutes.

Use a clean install rather than a copy of a production server: no mods,
no Shine, no production config, and stock `ns2/web/` and
`ServerWebInterface.lua`, which [API.md](API.md) and
[CURRENT-UI.md](CURRENT-UI.md) describe. Give the rig its own
`-config_path`, `-logdir` and `-modstorage` directories inside its tree.

### Engine version

The docs' measurements ran on the 09-03 engine drop and later ones (09-26
hotfix, 09-27, 09-28), extracted over the install's `x64/`, and each names
its drop. The `fixtures/` were captured on 09-03; a 09-26 recapture
validated against the spec with no change in shape.

- **A Steam validate reverts the engine** to stock. Re-apply the drop
  after every validate, and check the boot log's `Build:` line before a
  capture.
- Zips drop the executable bit: `chmod +x` `server_linux` and `x64/*.so`.
- The 09-03 drop's `libcurl.so` (8.21 / mbedTLS 3.6.7) aborts the server on
  concurrent HTTPS, which a Workshop search uses. Later drops need libcurl
  7.66 or newer (`curl_multi_poll`).
- Retail binaries ship unstripped (`server_linux` 16 MB,
  `libSpark_Core.so` 41 MB); the 09-03 drop's are stripped (1.5 MB,
  6.5 MB).

## Running it

```bash
. ./webadmin.env      # WEBUSER WEBPASS WEBPORT GAMEPORT; chmod 600, never committed
exec serverfiles/steam-runtime/shell.sh serverfiles/x64/server_linux \
  -name 'improved-webadmin local test (do not join)' \
  -port "$GAMEPORT" -map ns2_summit -limit 16 -speclimit 5 \
  -password localtest \
  -webadmin -webdomain 127.0.0.1 -webport "$WEBPORT" \
  -webuser "$WEBUSER" -webpassword "$WEBPASS" \
  -config_path "$PWD/config" -modstorage "$PWD/mods" -logdir "$PWD/logs"
```

The repo's tools read `WEBUSER`, `WEBPASS` and `WEBPORT` from the
environment; keep them in that file. Drive the rig with `curl --digest -u
"$WEBUSER:$WEBPASS"`.

- **Wait for `Web server running at 127.0.0.1:8080`.** If the port is
  still held, the engine logs `Couldn't start web server` and runs on
  without it.
- **Joining from a local client:** `connect 127.0.0.1:27015 localtest`.
  Without the password the server answers `Incorrect password`.
- **Stop it with `pkill -x server_linux`**, never `pkill -f` (see
  [Traps](#traps)).
- **The engine always downloads UWE Hotfix 344 and NSL Badges**, whatever
  `-modstorage` says. Neither changes the API, but both appear in
  `getinstalledmodslist`.
- **Headless bots do not work.** `BotTeamController` deletes every bot
  while no human is on a playing team. Once one human joins, `sv_maxbots
  12` fills the teams.

## Capturing fixtures

```bash
tools/capture-fixtures.sh --env webadmin.env              # read-only
tools/capture-fixtures.sh --env webadmin.env --mutating   # also the writes
tools/capture-fixtures.sh --env webadmin.env --mod        # also the mod's request types (lua/ mounted)
tools/redact-fixtures.py --path <rig>=/srv/ns2            # fixtures/live/ -> fixtures/
```

Raw captures land in `fixtures/live/`, gitignored because they carry
names, SteamIDs and IPs. `redact-fixtures.py` rewrites them into
`fixtures/` with stable fakes (one real player is one fake everywhere). It
redacts a `name` only in a record with a `steamid` or a `reason`, so map
and mod names survive. Log lines name the server's directories, so pass a
`--path` for each directory outside the rig's tree (a `-consolefifo`, for
example); any home directory left becomes `/home/user`.

`redact-fixtures.py` rewrites all of `fixtures/live/`, so a capture with
the mod mounted overwrites the stock fixtures (`serverstate.json` gains
`mod_version`). Capture the two sets separately, or use `--src`, and `git
checkout` what you did not mean to replace.

A populated `player_list`, real chat, a successful kick or a ban need a
human in the server; bots report `"steamid": 0`.

## Running this repo's Lua on the rig

The mod mounts by overwriting an installed workshop item's files and
putting that item in the cycle. These docs used Combat Fix (`509780686`,
hex `1e62a2ce`).

```bash
cd <rig>
cp config/MapCycle.json config/BannedPlayers.json /tmp/        # back up
cp <repo>/lua/ServerWebInterface.lua \
   mods/SparkCache/509780686/1441020960/lua/
# add "mods": ["1e62a2ce"] to config/MapCycle.json: mods mount at map load
# boot; for the log tail, -logdir equal to -config_path
```

**Restart after copying a new build of `web/`.** The engine lists a mod's
files when it mounts it, so a rebuilt panel's new asset names answer with
the stub page and the panel loads blank (`Unable to open
'web/assets/index-<hash>.js'` in the log). A changed file under an
existing name is served at once.

**Restore the rig afterwards**: `MapCycle.json` (unmounts the mod and
restores ranking), `BannedPlayers.json`, `ReservedSlotsConfig.json` if the
slot count changed, the item's own `ServerWebInterface.lua`, and delete
what tests leave in `config/`: `log-Server.txt` and `dumps/` from a
`-logdir` test, `ConsistencyConfig.json` (written on a boot with a mod
mounted), and `improved-webadmin/`.

**The published item.** To test the upload rather than the working tree,
put `e3742516` in `MapCycle.json`'s `mods` instead of the Combat Fix
overlay. The server downloads the item into `mods/content/4920/3816039702/`.
Restore as above and remove the download: `mods/content/4920/3816039702/`,
`mods/SparkCache/3816039702/`, and its entries in
`mods/appworkshop_4920.acf` (restore a copy taken before the boot).

**The default layout** (neither `-config_path` nor `-logdir`): set
`XDG_CONFIG_HOME` to an empty directory of its own, so the config
directory becomes `$XDG_CONFIG_HOME/Natural Selection 2/` instead of the
shared `~/.config/Natural Selection 2/`. Put a `MapCycle.json` and a
`ProgressionConfig.json` with `"enabled": false` in it first. Keep
`-modstorage`. Delete the directory afterwards.

### Probes, harnesses and the benchmark

A **probe** is a copy of `lua/ServerWebInterface.lua` with an extra
request type that returns what you want to inspect, read over HTTP on the
rig. Errors in the handler come back as an empty `200`, so a probe that
returns nothing usually did not compile. A `make-*-probe.sh` splices a
`*-branch.lua` into the shipped file, so the probe runs the shipped code.

A **harness** (`*-harness.lua`) runs the shipped file under LuaJIT with
the engine calls stubbed, no rig needed. It checks the mod's logic, not
what the engine's hooks really do.

| Probe (`tools/spikes/`) | Request | What it answers |
| --- | --- | --- |
| `console-output-probe.lua`, `logdir-probe.lua`, `unban-probe.lua` | various | Command capture, the log through `config://`, the unban fixes (REQUIREMENTS items 5, 7; CONSTRAINTS items 7-10) |
| `make-engine0926-probe.sh` | `engine0926-branch.lua` | 09-26 engine checks: hook arguments, `config://` writes (CONSTRAINTS item 6, REQUIREMENTS item 6) |
| `make-recent-players-probe.sh` | `[recent-probe]` log lines | Connect and disconnect hooks, file load, saves (REQUIREMENTS item 6). Logged to the file because it survives a map change |
| `make-mods-probe.sh` | `modsprobe` | Installed and active mod ids, the cycle's mods, `Server`'s mod functions (REQUIREMENTS item 3) |
| `make-workshop-probe.sh` | `workshopprobe` | `SearchWorshop` and `InstallMod` results and timing, Steam getters (REQUIREMENTS item 4) |
| `make-perf-probe.sh` | `perfprobe` | Per-tick timing on two clocks and every `ServerPerformanceData` getter (REQUIREMENTS item 10). It logs each getter's name before calling it, which is how the `Accumulate()` crash was found |
| `make-log-probe.sh` | `logprobe` | Reply sizes, odd bytes through `Shared.Message`, the log's header, read costs (REQUIREMENTS item 7). Needs `-logdir` equal to the config path |
| `make-tickstat-probe.sh` | `tickprobe[&from=N]` | `Server.GetBwLimit()`, rate getters, a timed log scan with the last `TICKSTAT\|`, rate-step and `perfmon:` lines (REQUIREMENTS item 10). Needs the log in the config directory and a `-consolefifo` |
| `make-whitelist-probe.sh` | -- | What `Shared.SendHTTPRequest` hands its callback (CONSTRAINTS item 17) |
| `make-maps-probe.sh` | `mapsprobe` | The in-memory cycle's id types, the file, dkjson round trips, Shine's mapvote (CONSTRAINTS items 12, 13) |

Harnesses: `maps-harness.lua` (the map cycle request types and
`getinstalledmodslist`), `recent-players-harness.lua`,
`workshop-harness.lua`, `perf-harness.lua`, `tickstat-harness.lua` (over
the real lines in `tickstat-rig-20260928.txt`), `log-harness.lua` (with a
fake `io.open` that, like Spark's, serves the file as it was when opened),
`chat-harness.lua`, `console-harness.lua`, `state-harness.lua` and
`whitelist-harness.lua`.

`server-cost-bench.lua` is a benchmark under the same stubs; see
[SERVER-COST.md](SERVER-COST.md).

Every harness and the benchmark take `--core <rig>/serverfiles/core/lua`,
for the game's own dkjson and `RingBuffer.lua`.

## Traps

- **The engine's Lua preprocessor can drop the end of a file.** The 09-xx
  engines pass each script through a preprocessor that adds `PROFILE`
  zones by matching `function`/`do`/`if`/`repeat` against `end`/`until`.
  A probe with its code nested inside `OnWebRequest` loaded only up to the
  end of that function: the log said `WARNING: File was not completely
  preprocessed! Here is where it stopped. File:
  lua/ServerWebInterface.lua:2632, Remaining Bytes: 1433`, every later
  `Event.Hook` was lost, and every request answered `with error:`. Size is
  not the cause (the shipped file padded to 100 KB loads whole); the
  trigger was not pinned down. Moving the code into top-level functions
  fixed it. After booting with changed Lua, `grep -A2 "not completely
  preprocessed" logs/log-Server.txt` must print nothing.
- **A log left in `config/` is served as live.** A later boot with
  `-logdir` elsewhere still opens `config://log-Server.txt`. The mod
  reports it `stale`, but delete it when you restore the rig.
- **The mod's `web/` is indexed at map load.** A new build copied in while
  the server runs serves the new `index.html` without its new hashed
  assets: a blank page. `sv_changemap` picks them up.
- **`pkill -f server_linux` kills your own shell**, whose command line
  contains the string, leaving the rig half-restored. Use `pkill -x
  server_linux`, or kill by PID from `pgrep -f "server_lin[u]x"` in a
  command that does nothing else.
- **An install leaves state behind**: the download under
  `mods/content/4920/<id>/` and `mods/SparkCache/<id>/`, and its two
  entries in `mods/appworkshop_4920.acf`. Remove all of them. Install
  something tiny: `crosshair` finds mods under 2 KB.
- **No network:** a Workshop search's failure case needs Steam
  unreachable. Without root, `unshare -rn` runs a script with loopback
  only (bring `lo` up first). Boot the rig and drive it from that same
  script. Steam logs `Failed Steam error NoConnection`.
- **Console commands as an operator types them:** add `-consolefifo
  <path>` and `echo cmd > <path>`.

## Testing on Shine

Shine is the normal case ([CONSTRAINTS.md](CONSTRAINTS.md#shine)). Give the
Shine rig its own `-config_path` and `-modstorage` (say `config-shine/`
and `mods-shine/`), with Shine (`117887554`) and the plugins and mods to
test in the cycle. To run this repo's Lua on it:

1. Back up its `MapCycle.json`.
2. **Turn progression off.** A config the UWE Hotfix mod has seen is
   enrolled with UWE's progression service, and a test server must not
   submit rounds: `jq .enabled config-shine/ProgressionConfig.json` must
   print `false`.
3. Copy the mount mod (`mods/SparkCache/509780686/`) into the Shine rig's
   `SparkCache/`, put our `ServerWebInterface.lua` in its
   `1441020960/lua/`, and append `509780686` to the cycle's `mods`
   (numbers there, not hex).
4. Boot, wait for `Shine started up successfully`, then a few seconds
   more: requests during the map load return empty.

**Joining from a local client** needs the join password with the address
(not the web admin's password), and the same mods as the client. A Shine
plugin only one side has fails `Shine_PluginSync` (`Network message
'Shine_PluginSync' check sum doesn't match the Servers`, then `Invalid
data`). A workshop folder copied from an older server can hold files a
later version dropped, so compare `du -sb` of each mod with the client's
`steamapps/workshop/content/4920/<id>`.

**A copy of a production config is production data.** Report counts and
shapes, not command output: `sh_listbans` and `sv_listbans` print every
banned player's name, id and reason.

Afterwards restore `MapCycle.json`, `shine/temp/lastmaps.json` and
`shuffle_friend_groups.json` (Shine rewrites both), remove the mount mod's
copy, and delete what the boot creates in the config directory:
`ConsistencyConfig.json`, a default `shine/plugins/LifeformPicker.json`,
that day's log in `shine/logs/`, and `improved-webadmin/`, which holds a
joined player's real name, IP and Steam id.

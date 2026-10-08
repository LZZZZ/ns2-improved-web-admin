# Testing on a real server

A real NS2 dedicated server on your own machine -- "the rig" in these
docs -- used to capture fixtures and to validate the panel and the mod's
Lua against the engine they have to live with. It is not the day-to-day
development loop: that is the [mock server](../mock/README.md). Boot the
rig when a question can only be answered by the real thing.

Keep it **outside this repository**. It is about 3.5 GB; keeping it out
of the tree means there is nothing to gitignore, no way to commit it by
accident, and no 3.5 GB directory slowing down `rg`, `find` and editor
indexing.

## Building one

`app_update 4940` works with **`+login anonymous`** -- no Steam account
needed. The wiki's `+login username password` is out of date on that
point. One gotcha it does not mention: a bare `+app_update 4940` fails
with

```
ERROR! Failed to install app '4940' (Missing configuration)
```

until you prefix `+app_info_update 1`. With that it pulls 3.6 GB and
installs in about three minutes.

```bash
steamcmd.sh +force_install_dir <rig>/serverfiles +login anonymous \
            +app_info_update 1 +app_update 4940 validate +quit
<rig>/serverfiles/steam-runtime/setup.sh --host=amd64 --target=amd64 --release --auto-update
```

A clean install is worth it over copying a production server's tree: it
carries no mods, no Shine and no production config, and its `ns2/web/` and
`lua/ServerWebInterface.lua` are stock, which is what [API.md](API.md) and
[CURRENT-UI.md](CURRENT-UI.md) were read from.

Give the rig its own directories for `-config_path`, `-logdir` and
`-modstorage`, inside its tree, so nothing it writes lands elsewhere.

### Engine version

What these docs measured ran on the 2026-09-03 engine drop and later ones
(09-26 hotfix, 09-27, 09-28), applied over the install's `x64/`. The
fixtures in `fixtures/` were captured against **26-09-03**; a 09-26
recapture validated against the spec with no shape change, so they were
kept. Docs name the drop a measurement was taken on.

- **A Steam validate reverts the engine.** `app_update ... validate`
  restores the stock binaries, so an engine drop must be re-applied after
  every validate. Getting this wrong leaves a stock server running while
  you believe you are testing a newer drop, which silently invalidates any
  capture taken against it. Check the boot log's `Build:` line.
- Zips drop the Unix executable bit: `chmod +x` `server_linux` and
  `x64/*.so` after extracting one.
- **The 09-03 drop's `libcurl.so`** (8.21 / mbedTLS 3.6.7) aborts the
  server on concurrent HTTPS. `getmods` is a workshop search, exactly that
  path, so if the rig aborts mid-capture on 09-03, that is the likely
  cause. Later drops need a libcurl of 7.66 or newer
  (`libSpark_Core.so` imports `curl_multi_poll`), so an older libcurl
  will not boot them.

Retail 4940 binaries ship **with `debug_info`, not stripped**
(`server_linux` 16 MB, `libSpark_Core.so` 41 MB), where the 09-03 drop is
stripped to 1.5 MB / 6.5 MB.

## Running it

A launch that matches what these docs assume:

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

The web admin refuses to start unless it is localhost-restricted or has
a login (`-webuser`/`-webpassword`, `-webusers`, `-webreqip` or
`-webtoken`). Keep the credentials in a file of their own and source it;
the repo's tools read `WEBUSER`, `WEBPASS` and `WEBPORT` from the
environment.

Web admin on `http://127.0.0.1:8080`, game on `27015` with a join
password. To join from a client on the same machine, pass the password
with the address: `connect 127.0.0.1:27015 localtest`. Without it the
server answers `Incorrect password`, and the client then retries by
itself against the last server it knew. Stop the rig with
`pkill -x server_linux` -- **not** `pkill -f`; see below.

The web server binds at boot; if the port is still held by a previous
instance it logs `Couldn't start web server at 127.0.0.1:8080` and the
game server keeps running without it. Always wait for
`Web server running at 127.0.0.1:8080` before capturing.

`-modstorage` is honoured, but the engine force-downloads two hotfix mods
(UWE Hotfix 344, NSL Badges) regardless. Neither ships a
`ServerWebInterface.lua`, so the API surface is stock -- but they do
appear in `getinstalledmodslist`, so that fixture is not what a truly
bare server returns.

**Headless bots do not work.** `addbots 8 1` creates the virtual clients,
but `BotTeamController` deletes every bot whenever no human is on a
playing team, so `listbots` comes back empty and `sv_maxbots 0` does not
stop it. One human has to join; then `sv_maxbots 12` fills the teams, and
`addbot 3` holds.

## Capturing fixtures

```bash
tools/capture-fixtures.sh --env webadmin.env              # read-only
tools/capture-fixtures.sh --env webadmin.env --mutating   # also the write request types
tools/capture-fixtures.sh --env webadmin.env --mod        # also runcommand and getconsole,
                                                          # which need our lua/ mounted
tools/redact-fixtures.py --path <rig>=/srv/ns2            # fixtures/live/ -> fixtures/
```

`--env` names the credentials file (the `webadmin.env` above).

A log line names the server's directories (`Passed '<rig>/mods/' as
mod-storage directory`), so give `redact-fixtures.py` a `--path` for each
directory the rig uses outside its own tree, such as a `-consolefifo`
path. Any home directory left after that becomes `/home/user`.

`redact-fixtures.py` rewrites **everything** in `fixtures/live/`, so a
capture run taken with the mod mounted will overwrite the stock-server
fixtures with modded ones -- `serverstate.json` picks up `mod_version`
and stops representing a stock server. Capture the two sets separately
and `git checkout` the ones you did not mean to replace.

Raw captures land in `fixtures/live/`, which is gitignored because they
carry player names, SteamIDs and IP addresses. `redact-fixtures.py`
rewrites them into `fixtures/` with stable fakes, so one real player maps
to one fake identity across every fixture and cross-references survive.
It redacts a `name` only inside a record that carries a `steamid` or a
`reason`, so map names and mod titles are left alone.

Some fixtures need a human in the server: a populated `player_list`, a
real `getchatlist` entry, a successful kick, a ban. Bots are not enough --
they report `"steamid": 0` and cannot be kicked or banned.

## Running *this repo's* Lua on the rig

The mock covers day-to-day work. Boot the real thing when the question is
about the engine: whether a global can be wrapped, whether a file can be
read, whether a fix actually takes effect. Every Lua claim in
[CONSTRAINTS.md](CONSTRAINTS.md) and [REQUIREMENTS.md](REQUIREMENTS.md)
was settled this way.

The mod mounts by dropping files into an already-installed workshop
item's directory and putting that item in the map cycle. These docs used
Combat Fix (`509780686`, hex `1e62a2ce`). Back up what you overwrite --
all of it is rig state that other captures depend on.

```bash
cd <rig>

# 1. back up what this touches
cp config/MapCycle.json config/BannedPlayers.json /tmp/

# 2. mount our Lua over the installed mod's directory
cp <repo>/lua/ServerWebInterface.lua \
   mods/SparkCache/509780686/1441020960/lua/

# 3. put the mod in the cycle -- it is mounted at map load, not at boot
#    (add "mods": ["1e62a2ce"] to config/MapCycle.json)

# 4. boot, and wait for the web server line; with -logdir equal to
#    -config_path when testing the server log (REQUIREMENTS item 7),
#    since Lua cannot read a log written anywhere else
```

Then drive it with `curl --digest -u "$WEBUSER:$WEBPASS"`, sourcing the
credentials file rather than typing them.

**Put the rig back afterwards**, or the next capture inherits your test
state: restore `MapCycle.json` (so the mod is unmounted and the server is
ranked again), restore `BannedPlayers.json`, restore
`ReservedSlotsConfig.json` if you changed the slot count, put the
installed mod's own `ServerWebInterface.lua` back, and delete any
`log-Server.txt` or `dumps/` left in `config/` by a `-logdir` test. A
boot with a mod mounted also writes a default `ConsistencyConfig.json`
into `config/` (seen on 09-26); delete it too.

### The default layout

To boot the rig with neither `-config_path` nor `-logdir`, as many
operators do, set `XDG_CONFIG_HOME` to an empty directory of its own: the
engine honours it, so the default config directory becomes
`$XDG_CONFIG_HOME/Natural Selection 2/` instead of the
`~/.config/Natural Selection 2/` other runs share. Put a `MapCycle.json`
and a `ProgressionConfig.json` with `"enabled": false` in it before the
first boot. Keep `-modstorage`. Delete the directory afterwards.

### Mounting the published item

To test what operators get rather than this repo's working tree, put the
Workshop item's hex id, `e3742516`, in `MapCycle.json`'s `mods` instead
of the Combat Fix overlay, and boot: the server downloads the item into
`mods/content/4920/3816039702/` and mounts it from there. The local
overlay is for changes not yet uploaded; this is for an upload.

Put the rig back the same way, and also remove the download:
`mods/content/4920/3816039702/`, `mods/SparkCache/3816039702/`, and its
entries in `mods/appworkshop_4920.acf` (restore a copy taken before the
boot), plus `config/improved-webadmin/`, which the mod creates.

### Probes and harnesses

A probe is easier than a print statement: generate a copy of
`lua/ServerWebInterface.lua` with an extra request type that returns
whatever you want to inspect as JSON, and read it over HTTP.
`tools/spikes/` holds the ones written so far --
`console-output-probe.lua`, `logdir-probe.lua` and `unban-probe.lua`,
each the vanilla or shipped handler plus a branch or two, and
`engine0926-branch.lua`, a branch that
`make-engine0926-probe.sh` splices into the current
`lua/ServerWebInterface.lua`, so the probe runs on the shipped code.
Errors inside the handler surface as an empty `200`, so a probe that
returns nothing usually means the file did not compile.

`make-recent-players-probe.sh` builds `recent-players-probe.lua`, the
shipped file with `[recent-probe]` lines in `log-Server.txt` for the
connect and disconnect hooks, the file load and each save. They go to
the log rather than the console buffer because the log survives a map
change.

`make-mods-probe.sh` builds `mods-probe.lua` from `mods-branch.lua`:
the shipped file plus `request=modsprobe`, which lists installed and
active mod ids with their types, the file's global mods and the `Server`
functions whose names mention mods, workshop or ranking (REQUIREMENTS
item 3). `maps-harness.lua` checks `getinstalledmodslist`'s `active`
flag off the rig.

`make-workshop-probe.sh` builds `workshop-probe.lua` from
`workshop-branch.lua`: the shipped file plus `request=workshopprobe`, which
calls `Server.SearchWorshop` and `Server.InstallMod` directly and reports
what they return and when, how `json.encode` writes an empty table, and
which Steam or network getters exist (REQUIREMENTS item 4).
`workshop-harness.lua` runs `getmods` and `installmod` off the rig.

`make-perf-probe.sh` builds `perf-probe.lua` from `perf-branch.lua` and
`perf-sampler.lua`: the shipped file plus a second `UpdateServer` hook
that times every tick on two clocks and reads every getter of
`Shared.GetServerPerformanceData()` as each sample completes, and
`request=perfprobe` to read it all (REQUIREMENTS item 10). It logs each
getter's name before calling it on the first reads: that is how the
SIGFPE in `Accumulate()` of an empty sample was pinned down, and how to
find the next one. `perf-harness.lua` runs `getperf` off the rig, with a
fake accumulator that fails where the engine crashes.

`make-log-probe.sh` builds `log-probe.lua` from `log-branch.lua`: the
shipped file plus `request=logprobe`, which serves a reply of any size,
writes odd bytes through `Shared.Message` and reads them back, reports
the log's header and last bytes, and times reads of 64 KB to 1 MB
(REQUIREMENTS item 7). Boot with `-logdir` set to the config directory
for it, and for `getlog`. `log-harness.lua` runs `getlog` off the rig,
with a fake `io.open` that serves the file as it was at the open, as
Spark's does.

`make-tickstat-probe.sh` builds `tickstat-probe.lua` from
`tickstat-branch.lua`: the shipped file plus `request=tickprobe[&from=N]`,
which reports `Server.GetBwLimit()`, the clocks, the `Server` functions
about rates and limits, and times a scan of the log from byte `from`,
returning the last `TICKSTAT|`, `snapshot rate` and `perfmon:` lines raw
(REQUIREMENTS item 10). Boot with `-logdir` set to the config directory
and a `-consolefifo` to drive `tickstat`, `perfmon` and `bwlimit`.
`tickstat-harness.lua` runs `getperf`'s engine part off the rig, over the
real lines the probe run kept in `tickstat-rig-20260928.txt`, with the
same fake `io.open` as `log-harness.lua`. Both check `getperf`'s pages of
60.

`make-whitelist-probe.sh` builds `whitelist-probe.lua` from
`whitelist-branch.lua` and `whitelist-helpers.lua`: what
`Shared.SendHTTPRequest` hands its callback, on success and on failure
([CONSTRAINTS.md](CONSTRAINTS.md) item 17). `whitelist-harness.lua` runs
`getwhitelist` off the rig.

`make-maps-probe.sh` builds `maps-probe.lua` from `maps-branch.lua`: the
shipped file plus `request=mapsprobe`, which reports the in-memory cycle's
id types, the file, dkjson round trips and Shine's mapvote state
(CONSTRAINTS items 12 and 13). `maps-harness.lua` runs the map-cycle
request types off the rig.

`recent-players-harness.lua`, like every `*-harness.lua`, needs no rig:
it runs the shipped file under LuaJIT with the engine calls stubbed, to
check the recent-players store's logic (map change, torn slot, capacity,
window) and the wrapper that names Shine bans of absent players. A
harness says nothing about what the engine's hooks really do.

`server-cost-bench.lua` is not a harness but a benchmark: the shipped file
under the same kind of stubs, an hour on one map, then the CPU time of the
per-tick hook and of each heavier request, with the game's dkjson. Its
numbers and how to read them are in [SERVER-COST.md](SERVER-COST.md).
`--mod` points it at another copy of the file, for a before and after.

Every harness and the benchmark take `--core <rig>/serverfiles/core/lua`:
they load the game's own dkjson (and `RingBuffer.lua`) from there.

## Traps

**The engine's Lua preprocessor can drop the end of a file** *(found
2026-10-08)*. A probe with its code nested inside `OnWebRequest` loaded
only up to the end of that function: the log said `WARNING: File was not
completely preprocessed!` with the line and the bytes left, every later
`Event.Hook` was lost, and every request answered `with error:`. Moving the
code to top-level functions fixed it; the exact trigger is unknown
([CONSTRAINTS.md](CONSTRAINTS.md) item 17). After booting with changed Lua,
`grep -A2 "not completely preprocessed" logs/log-Server.txt` should print
nothing.

**A log left in `config/` is a trap**, not just clutter: the next boot
with `-logdir` elsewhere still opens `config://log-Server.txt` and would
serve that frozen copy as the live log. The mod catches it (`stale`), but
delete it when you restore the rig. To run a console command the way an
operator types it rather than through the web admin, add
`-consolefifo <path>` and `echo cmd > <path>`: that is how `clearconsole`
was shown to leave the server's log alone.

**The mod's `web/` is indexed at map load.** Copying a new build into the
mount directory while the server runs serves the new `index.html` but
not its new hashed assets, which fall through to the JSON handler as
unknown paths: a blank page. `sv_changemap` picks them up.

**Testing a server with no network.** The failure case of a workshop
search needs Steam unreachable. Without root, a user namespace does it:
`unshare -rn` runs a script with loopback only (bring `lo` up inside it
first), so boot the rig *and* drive it from that same script -- nothing
outside the namespace can reach its web port. Steam then logs
`Failed Steam error NoConnection` and the server otherwise runs.

**An install leaves state behind** the restore steps above do not cover:
the download under `mods/content/4920/<id>/` and `mods/SparkCache/<id>/`,
and its two entries in `mods/appworkshop_4920.acf` (whose `SizeOnDisk` is
the sum of the items' sizes). Remove all of them. Install something tiny:
`crosshair` finds mods under 2 KB.

**`pkill -f server_linux` kills your own shell.** `pkill -x server_linux`
is safe. `-f` matches the whole command line, and your own shell's command
line contains that string -- so it kills the shell running it, mid-script,
leaving the rig half-restored. If a command both stops the server and
starts one, the start half is enough to make the kill match itself. Kill
by PID from `pgrep -f "server_lin[u]x"`, in a command that does nothing
else.

## Testing on Shine *(2026-09-27)*

Shine is the normal case (see [CONSTRAINTS.md](CONSTRAINTS.md#shine-2026-09-27)),
so the mod and the panel are tested on it too. Give the Shine rig its own
`-config_path` and `-modstorage` (for example `config-shine/` and
`mods-shine/`), with Shine (`117887554`) and whatever plugins and mods
you want to test against in the map cycle. To run this repo's Lua on it:

1. Back up its `MapCycle.json`.
2. **Turn progression off.** A config the UWE Hotfix mod has seen holds an
   enrollment with UWE's progression service; a test server must not
   submit rounds. `ProgressionConfig.json` must carry `"enabled": false`:

   ```bash
   jq .enabled config-shine/ProgressionConfig.json   # false
   ```
3. Copy the mount mod (`mods/SparkCache/509780686/`) into the Shine rig's
   `SparkCache/`, put our `lua/ServerWebInterface.lua` in its
   `1441020960/lua/`, and append `509780686` to the `mods` list in its
   `MapCycle.json` (numbers there, not hex).
4. Boot, wait for `Shine started up successfully`, then a few seconds
   more: requests made while the map is still loading return empty.

**Joining it from a client on the same machine** *(2026-10-06)*. Two
things stand in the way:

- **The join password.** Pass it with the address, as on the vanilla rig.
  Do not use the web admin's password as the join password.
- **The mods must match the client's.** A mounted Shine plugin that only
  one side has changes `Shine_PluginSync`. The client logs `Network message
  'Shine_PluginSync' check sum doesn't match the Servers`, and the server
  drops it with `Invalid data`. A workshop folder copied from an older
  server can keep files a later version of a mod dropped (one held a
  second plugin folder and twice its manifest size), so compare `du -sb`
  of each mod against the client's `steamapps/workshop/content/4920/<id>`.

**A copy of a production config is production data.** Its ban list and
Shine config are real. Report counts and shapes, not command output:
`sh_listbans` or `sv_listbans` prints every banned player's name, id and
reason.

Afterwards restore `MapCycle.json`, remove the mount mod's copy, and
delete what the boot creates in the config directory:
`ConsistencyConfig.json`, a default `shine/plugins/LifeformPicker.json`,
and that day's Shine log in `shine/logs/`. With a human joined, also
delete `improved-webadmin/` there (the mod's recent-players file, with the
player's real name, IP and Steam id). Restore `shine/temp/lastmaps.json`
and `shuffle_friend_groups.json` too, which Shine rewrites. The engine
also refreshes the mod cache; that can stay.

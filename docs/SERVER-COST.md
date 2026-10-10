# What the mod's Lua costs the server

*Measured 2026-10-08, off the rig, with `tools/spikes/server-cost-bench.lua`.*

The mod's `lua/ServerWebInterface.lua` runs in the server's Lua VM. This
page measures what it adds: what runs every tick whether or not a panel is
open, and what each request costs. In short, a steady panel costs well
under a millisecond of server time a second, and no single tick gets more
than about 2 ms.

## How big the change is

| | Vanilla (344, 09-03) | The mod |
| --- | --- | --- |
| Lines | 304 | 2,693 |
| Code lines | 211 | 1,697 |
| Comment lines | 23 | 583 |

All vanilla code is still there, with about 79 lines edited (`getmods`
rewritten, `getmapcycle` and `setmapcycle` hardened, booleans in the state
blob, the `setreservedslotamount` call). The rest is new:

- **Wrappers on game functions** (`Shared.Message`, `ServerAdminPrint`,
  `Server.AddChatToHistory`, `UnbanUser`, Shine's `Plugin:AddBan`) and
  replacements of `GetIsUserBanned` and `GetIsUserBannedPermanently`. Only
  these change what the game itself does (CONSTRAINTS items 7-11).
- **New request types**, run only when a client asks.
- **Per-tick work** in the `UpdateServer` hook vanilla already had.

## Method

The benchmark loads the shipped file under LuaJIT with the engine calls
stubbed, as the harnesses do, and plays an hour on one map: 18 players, a
perf window every 10 s, a `TICKSTAT` line every 10 s appended to a real
4.4 MB `log-Server.txt` (about 3 hours of an 80-tick server with players),
and the engine scan every 2 s. It then times the handlers through the
`WebRequest` and `UpdateServer` hooks, with the game's dkjson 2.5.

```bash
luajit tools/spikes/server-cost-bench.lua --core <server>/core/lua <log-Server.txt>
# an older copy of the file, for a before and after:
git show <rev>:lua/ServerWebInterface.lua > /tmp/old.lua
luajit tools/spikes/server-cost-bench.lua --core <server>/core/lua --mod /tmp/old.lua <log>
```

What the numbers are:

- **CPU time on a desktop** (Ryzen 9 9950X3D). A server vCPU is slower per
  thread; 1.5-2x is a guess, not a measurement.
- **Lua and dkjson only.** The engine's side of each call is extra, and
  small beside dkjson.
- **JIT on and off agree** within about 20 %: dkjson is string building.
- **Inside a tick**, by inference: the `WebRequest` handler runs in the
  game's Lua VM (it calls `GetGamerules()` and walks entities), so its time
  comes out of a tick. Not yet confirmed on the rig.

At 80 tick a tick is 12.5 ms. An empty 80-tick server on the 09-28 engine
logs `busy 29.0%`.

## Every tick

| What | Cost |
| --- | --- |
| The whole `UpdateServer` hook, averaged over the hour | 0.001 ms |
| A tick that does not scan the log | under 0.001 ms |
| A tick that scans 1 KB of new log (2 s on a busy server) | 0.020 ms |
| A scan of 256 KB of real log, the cap, after a flood | 1.8 ms |
| 256 KB of nothing but `TICKSTAT` lines, the worst case | 6.7 ms |

The log grew about 400 bytes a second, so a scan normally meets about
1 KB, and 256 KB only once after something floods the log. A line that is
neither `TICKSTAT|` nor `perfmon: ` fails three anchored patterns on its
first characters; only `TICKSTAT` lines are parsed in full, one every N
seconds, so the 6.7 ms row is a bound. The scan keeps its 256 KB limit
(`kEngineScanMaxBytes`) because a smaller one could lose a `TICKSTAT`
line.

Not benchmarked, and small:

- **Wrapper checks:** three comparisons and one `pcall` into Shine per
  tick, to re-install wrappers Shine replaces.
- **The perf window:** a read of `Shared.GetServerPerformanceData()` and
  the clock per tick, an accumulate per second, a window per 10 s.
- **The recent-players file:** checked every 10 s, rewritten every 60 s
  while someone is on and on the tick after a disconnect: a JSON encode
  (0.3 ms for 100 players) and a 20 KB write.
- **The console copy:** every line the game prints goes into a 500-line
  buffer, microseconds.
- **The ban check:** a connection scans the ban list instead of a hash
  lookup (CONSTRAINTS item 10). Under Shine, `GetBannedPlayersList()`
  rebuilds about 120 entries, twice per connection attempt.

## Per request

The panel polls the state blob, chat and the log every 2 s by default,
`getperf` every window (10 s), the lists every 10 s and the catalogues
every 60 s. The state blob is polled on every tab, the rest only while
their tab is open, and nothing while the browser tab is hidden.

| Request | Cost |
| --- | --- |
| `request=json`, the state blob, 18 players | 0.13 ms |
| `getperf`, a routine poll: one window, one line | 0.05 ms |
| `getperf` from 0, one page: 60 windows + 60 lines, 59 KB | 1.4 ms (slowest page 2.1 ms) |
| `getperf` from 0 until caught up: 6 pages | 8.4 ms in total, over 6 requests |
| `getlog`, a routine poll: about 2 KB | 0.04 ms |
| `getlog`, the first tail: 64 KB | 1.1 ms |
| `getlog` from an old cursor, one 64 KB reply | 1.0 ms |
| `getlog` 1 MB behind until caught up: 17 replies | 18 ms in total (slowest 2.2 ms) |
| `getrecentplayers`, 18 connected | 0.02 ms |

**Why replies are paged.** Unpaged, an hour of `getperf` was one 360 KB
reply costing 8.4-9.9 ms to encode (perhaps 12-17 ms on a server vCPU), a
late tick or two at 80 each time an admin opened the Performance tab. A
256 KB `getlog` catch-up cost 4.2-4.4 ms, a third of a tick. Now `getperf`
returns at most 60 windows and 60 engine records per reply and `getlog`
at most 64 KB, each with `more` until caught up. The panel sends the next
request only after the last reply, so each page lands in a later tick: the
total is unchanged, but no tick gets more than about 2 ms.

**`getwhitelist`** is a stability concern, not a cost: it uses
`Shared.SendHTTPRequest`, the libcurl path that aborts the 09-03 drop on
concurrent HTTPS. The mod reads one page at a time, at most once an hour,
only when a panel asks (CONSTRAINTS item 17).

## Still to check on the rig

- A Tracy capture, or `tickstat 10`, while someone opens each tab
  (Performance first, late in a map): it would confirm the handler runs in
  the tick and replace the 1.5-2x guess.
- A paged `getperf` reply from the real engine as a fixture; the current
  fixtures predate paging and carry no `more`.

# What the mod's Lua costs the server

*Measured 2026-10-08, and again 2026-10-12 for the 10-12 engine's
functions, off the rig, with `tools/spikes/server-cost-bench.lua`.*

The mod's `lua/ServerWebInterface.lua` runs in the server's Lua VM. This
page measures what it adds: what runs every tick whether or not a panel is
open, and what each request costs. In short, a steady panel costs well
under a millisecond of server time a second, and no single tick gets more
than about 2 ms.

## How big the change is

| | Vanilla (344, 09-03) | The mod, 10-08 | The mod, 10-12 |
| --- | --- | --- | --- |
| Lines | 304 | 2,387 | 1,994 |
| Code lines (not blank, not a whole-line comment) | 211 | 1,706 | 1,413 |

The 10-12 engine's functions (CONSTRAINTS item 18) took out about 400
lines: the console tee, the log's layout check, the `TICKSTAT|` parser and
the whitelist reader.

Of the 2012 file, `getmods` is rewritten and `getmapcycle` and
`setmapcycle` hardened; its other requests stay for scripts that use
them. The rest is new:

- **Wrappers on game functions** (the nil-client branch of
  `ServerAdminPrint`, Shine's `Plugin:AddBan`). Only these change what the
  game itself does (CONSTRAINTS, Shine).
- **New request types**, run only when a client asks.
- **Per-tick work** in the `UpdateServer` hook vanilla already had.

## Method

The benchmark loads the shipped file under LuaJIT with the engine calls
stubbed, as the harnesses do, and plays an hour on one map: 18 players, a
perf window every 10 s, a tickstat window every 10 s (its `TICKSTAT` line
appended to a real 4.9 MB `log-Server.txt`, about 5 hours of the 8v8 on
2026-10-09, read through a `Shared.ReadLog` stub over the file), and the
log scan every 2 s. It then times the handlers through the `WebRequest`
and `UpdateServer` hooks, with the game's dkjson 2.5 standing in for
`Shared.JsonEncode`.

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
  small beside dkjson. The real server encodes with `Shared.JsonEncode`,
  which took 1.2 ms where dkjson took 5.2 ms for 2,000 rows on the rig
  (2026-10-12), so the per-request rows below, mostly encoding, overstate
  it: by up to about 4x for the large replies.
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
| A tick that scans 1 KB of new log (2 s on a busy server) | 0.007 ms |
| A scan of 256 KB of real log, the cap, after a flood | 0.24 ms |
| 256 KB of nothing but `TICKSTAT` lines | 0.15 ms |

The log grew about 400 bytes a second, so a scan normally meets about
1 KB, and 256 KB only once after something floods the log. Since 10-12 the
scan parses no `TICKSTAT` line: the windows come from
`Server.GetTickStat()`, read once a second. A line that is not
`perfmon: `, a rate step, the bwlimit warning or `tickstat: on|off` fails
a few anchored patterns on its first characters. Before 10-12 the worst
case, 256 KB of `TICKSTAT` lines parsed in full, cost 6.7 ms.

Not benchmarked, and small:

- **Wrapper checks:** three comparisons and one `pcall` into Shine per
  tick, to re-install wrappers Shine replaces.
- **`Server.GetTickStat()`** once a second: a table of 40 numbers, kept
  only when its window is new.
- **The perf window:** a read of `Shared.GetServerPerformanceData()` and
  the clock per tick, an accumulate per second, a window per 10 s.
- **The recent-players file:** checked every 10 s, rewritten every 60 s
  while someone is on and on the tick after a disconnect: a JSON encode
  (0.3 ms for 100 players) and a 20 KB write.
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
| `request=json`, the state blob, 18 players | 0.16 ms |
| `getperf`, a routine poll: one window, one tickstat window | 0.04 ms |
| `getperf` from 0, one page: 60 windows + 60 tickstat windows, 60 KB | 1.4 ms (slowest page 2.9 ms) |
| `getperf` from 0 until caught up: 6 pages | 8.6 ms in total, over 6 requests |
| `getlog`, a routine poll: about 2 KB | 0.04 ms |
| `getlog`, the first tail: 64 KB | 1.1 ms |
| `getlog` from an old cursor, one 64 KB reply | 1.0 ms |
| `getlog` 1 MB behind until caught up: 17 replies | 17 ms in total (slowest 2.5 ms) |
| `getrecentplayers`, 18 connected | 0.02 ms |

With dkjson standing in for `Shared.JsonEncode` (see Method).

**Why replies are paged.** Unpaged, an hour of `getperf` was one 360 KB
reply costing 8.4-9.9 ms to encode (perhaps 12-17 ms on a server vCPU), a
late tick or two at 80 each time an admin opened the Performance tab. A
256 KB `getlog` catch-up cost 4.2-4.4 ms, a third of a tick. Now `getperf`
returns at most 60 windows and 60 engine records per reply and `getlog`
at most 64 KB, each with `more` until caught up. The panel sends the next
request only after the last reply, so each page lands in a later tick: the
total is unchanged, but no tick gets more than about 2 ms.

The mod makes no HTTP request of its own since 10-12: the whitelist comes
from the engine (CONSTRAINTS item 17).

## Still to check on the rig

- A Tracy capture, or `tickstat 10`, while someone opens each tab
  (Performance first, late in a map): it would confirm the handler runs in
  the tick, replace the 1.5-2x guess, and time `Shared.JsonEncode` and
  `Shared.ReadLog` inside real replies.
- A paged `getperf` reply from the real engine as a fixture; the current
  fixtures predate paging and carry no `more`.

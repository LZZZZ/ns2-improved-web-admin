# What the mod's Lua costs the server

*Measured 2026-10-08, off the rig, at the commit that added this file; `getlog`'s cap measured again after it changed, the same day.*

Our `lua/ServerWebInterface.lua` replaces the game's copy wholesale, and
the game runs it in the server's Lua VM. This page gathers what that
replacement adds to the server's work: how much of it runs every tick
whether or not anyone has the panel open, how much runs per request, and
which of it could cost a tick. Two findings have been fixed: the first
`getperf` reply of a long map, and `getlog`'s 256 KB catch-up replies.
The rest is small.

## How big the change is

| | Vanilla (344, 26-09-03) | The mod |
| --- | --- | --- |
| Lines | 304 | 2,693 |
| Code lines | 211 | 1,697 |
| Comment lines | 23 | 583 |

About eight times the code. The vanilla code is still all there, and
about 79 of its lines are edited: `getmods` rewritten, `getmapcycle` and
`setmapcycle` hardened, real booleans in the state blob, and the
`setreservedslotamount` call fixed. Everything else is new, in three kinds:

- **Wrappers on the game's own functions.** `Shared.Message`,
  `ServerAdminPrint`, `Server.AddChatToHistory`, `UnbanUser` and Shine's
  `Plugin:AddBan` are wrapped, and `GetIsUserBanned` and
  `GetIsUserBannedPermanently` are replaced. These are the only parts that
  change what the game itself does. See CONSTRAINTS.md items 7 to 11.
- **New request types:** `runcommand`, `getconsole`, `getbans`,
  `getrecentplayers`, `getlog`, `getperf`, `getmapvote` and `getwhitelist`.
  They run only when a client asks.
- **Per-tick work** in the `UpdateServer` hook vanilla already had.

## How it was measured

`tools/spikes/server-cost-bench.lua` loads the shipped file under LuaJIT
with the engine calls stubbed, the way the harnesses do. It then plays an
hour on one map:

- 18 players;
- a perf window every 10 s;
- a TICKSTAT line every 10 s, appended to a real log: a 4.4 MB
  `log-Server.txt` from about 3 hours of an 80-tick server with players;
- the engine scan every 2 s.

After that hour it times the mod's own handlers through the `WebRequest`
and `UpdateServer` hooks. JSON is the game's own dkjson 2.5
(`core/lua/dkjson.lua`).

```bash
luajit tools/spikes/server-cost-bench.lua --core <server>/core/lua <log-Server.txt>
# the same, for an older copy of the file:
git show <rev>:lua/ServerWebInterface.lua > /tmp/old.lua
luajit tools/spikes/server-cost-bench.lua --core <server>/core/lua --mod /tmp/old.lua <log>
```

What the numbers are, and are not:

- **CPU time on a desktop** (Ryzen 9 9950X3D). A typical server vCPU is
  slower per thread. Expect perhaps 1.5-2x these figures there; that
  factor is a guess, not a measurement.
- **The Lua and dkjson only.** The stubs answer at once, so the engine's
  side of each call (`GetServerPerformanceData`, `GetOwner`, the file
  reads) is extra. Beside dkjson, those calls are small.
- **JIT on and off agree** to within about 20 %. dkjson is mostly string
  building, which the JIT does not speed up much.
- **In the tick.** The `WebRequest` handler runs in the game's Lua VM: it
  calls `GetGamerules()` and walks entities. So its time is taken out of a
  tick, the same as `UpdateServer`'s. This is inferred, not measured; a
  Tracy capture on the rig would show it.

At 80 tick a tick is 12.5 ms. For scale, an empty 80-tick server on the
09-28 engine logs `busy 29.0%` in its tickstat lines (the log above).

## Every tick, with or without a panel

| What | Cost |
| --- | --- |
| The whole `UpdateServer` hook, averaged over the hour | 0.001 ms |
| A tick that does not scan the log | under 0.001 ms |
| A tick that scans the log: 1 KB new, about 2 s on a busy server | 0.020 ms |
| A tick that scans 256 KB of real log, the cap, after a hitch | 1.8 ms |
| The same 256 KB, all TICKSTAT lines, the worst a scan can meet | 6.7 ms |

The log above grew about 400 bytes a second (4.4 MB in about 3 h), so a
scan normally meets about 1 KB. A scan meets 256 KB only after something
floods the log, such as a script error storm, and then once. Ordinary log
lines cost little to parse: a line that is neither `TICKSTAT|` nor
`perfmon: ` meets three anchored patterns that fail on their first
characters. Only TICKSTAT lines are parsed in full, and the engine writes one
every N seconds, so the 6.7 ms row is a bound, not a case.

What the benchmark does not cover, and why it is small:

- **Re-installing the wrappers.** Every tick the mod checks that its
  wrappers on `ServerAdminPrint`, `Server.AddChatToHistory` and Shine's
  `AddBan` are still in place, because Shine replaces them. That is three
  comparisons and one `pcall` into Shine.
- **The perf window.** Every tick reads `Shared.GetServerPerformanceData()`
  and the real clock. Once a second the mod accumulates the engine's
  sample, and every 10 s it closes a window.
- **The recent-players file.** It is checked every 10 s and rewritten
  every 60 s while someone is on, and on the tick after a disconnect, once
  however many players left: a JSON encode (0.3 ms for 100 players) and a
  20 KB write.
- **The `Shared.Message` copy.** Every line the game prints is also copied
  into a 500-line buffer for the console: a table and a pattern match,
  microseconds.
- **The ban check.** A connection attempt now scans the ban list instead
  of a hash lookup (CONSTRAINTS item 10). Under Shine,
  `GetBannedPlayersList()` also rebuilds about 120 entries on every call,
  twice per attempt. That is microseconds, and only when someone connects.

## Per request, only while a panel polls

The panel polls the state blob, chat and the log every 2 s, `getperf`
every window (10 s), the lists every 10 s and the catalogues every 60 s.
The state blob is polled on every tab, the rest only while a tab that
shows it is open, and nothing while the browser tab is hidden.

| Request | Cost |
| --- | --- |
| `request=json`, the state blob, 18 players | 0.13 ms |
| `getperf`, a routine poll: one window, one line | 0.05 ms |
| `getperf` from 0, one page: 60 windows + 60 lines, 59 KB | 1.4 ms (slowest page 2.1 ms) |
| `getperf` from 0 until caught up: 6 pages, summed | 8.4 ms, over 6 requests |
| `getlog`, a routine poll: about 2 KB new | 0.04 ms |
| `getlog`, the first tail: 64 KB | 1.1 ms |
| `getlog` since an old cursor, one reply: 64 KB (the cap) | 1.0 ms |
| `getlog` 1 MB behind until caught up: 17 replies, summed | 18 ms, over 17 requests (slowest 2.2 ms) |
| `getrecentplayers`, 18 connected | 0.02 ms |

A steady panel costs well under a millisecond of server time a second.
A first poll, or a catch-up, costs a little over a millisecond per reply.

### Fixed: the first `getperf` of a long map

Before 2026-10-08 a `getperf` from 0 sent everything the mod held. After
an hour on one map that was 360 windows and 360 tickstat lines in one
360 KB reply. It cost 8.4 ms to encode, its slowest run 9.9 ms, and on a
server vCPU perhaps 12-17 ms: a late tick or two at 80, each time an admin
opened or reloaded the Performance tab.

Now a reply holds at most 60 windows and 60 engine records, oldest first,
and says `more` until the cursor has caught up (API.md, *Performance
data*). The panel asks again at once, page after page. Each page is its
own request, sent only once the last one has come back, so it is served
in a later tick. The total work is about the same, 8.4 ms, but no tick
gets more than about 2 ms of it. A client that ignores `more`, such as an
older panel build, still gets everything, 60 per poll.

### Fixed: `getlog` after time away

`getlog` read forward up to 256 KB per reply, against 64 KB for the first
tail and for Load earlier. A 256 KB reply cost 4.2-4.4 ms to split into
lines and encode, a third of a tick at 80. The Console tab asks for one
when it is reopened after the log has grown, or when the browser tab comes
back from being hidden: at 400 B/s, that means about 10 minutes away. The panel catches up to 1 MB that way before it jumps to the
latest tail instead, so one return could cost 4 replies of 4-6 ms.

Since 2026-10-08 every `getlog` reply is capped at 64 KB, so the forward
read matches the others. The panel follows `more` for up to 16 replies per
poll, still 1 MB. Catching up 1 MB costs the same in total, about 18 ms,
but over 17 requests of 1.0-2.2 ms each instead of 5 of up to 6.2 ms. The
engine-log scan keeps its own 256 KB limit
(`kEngineScanMaxBytes`): it runs once, after a log flood, and a smaller
one could lose a TICKSTAT line.

### What is left, and is acceptable

- **The 256 KB scan after a log flood**, 1.8 ms, once. See above.
- **`getwhitelist` is a stability point, not a performance one.** It calls
  `Shared.SendHTTPRequest`, the libcurl path that aborts the 09-03 drop on
  concurrent HTTPS. The mod reads one page at a time, at most once an
  hour, and only when a panel asks (CONSTRAINTS item 17).

## Still to check on the rig

- A Tracy capture, or `tickstat 10`, while someone opens each tab,
  Performance first and late in a map. It would confirm that the handler
  runs in the tick, and give a server's own numbers in place of the
  1.5-2x guess.
- A paged `getperf` reply from the real engine, as a fixture. The fixtures
  in `fixtures/` predate paging and carry no `more`.

// The Performance tab's history.
//
// Two sources, one shape (PerfPoint):
//
//   * the mod's getperf: 10 s windows with ids, read with a cursor. The server
//     keeps an hour of them since the map loaded; a map change rebuilds the Lua
//     VM, so `loadedAt` moves and the ids restart from 1. This store keeps what
//     it has already read across those restarts -- one segment per map load --
//     for as long as the page is open, up to kHistoryMs. Windows the server
//     dropped before we read them (a map change mid-interval, or more than an
//     hour away from the tab) are a gap, never interpolated.
//   * a stock server's getperfdata: the last 30 readings a minute apart, the
//     whole window in every reply. It is replaced on each poll, never appended
//     to -- appending is the 2012 panel's defect (CURRENT-UI defect 2).
//
// The mod's reply also carries `engine`: what the engine prints only to its
// log (tickstat lines, rate steps, the perfmon: block), read with a cursor of
// its own and kept in the same segments, so a map change restarts both.
//
// It polls only while the tab is open, at the server's own window length (a
// faster poll returns nothing new), and not while the page is hidden. The
// history outlives the tab being closed and reopened: the cursor catches up.
//
// The server answers in pages of at most 60 windows and 60 engine records,
// with `more` until the cursor has caught up: an hour in one reply cost most
// of a server tick to encode (docs/SERVER-COST.md). So a poll that gets
// `more` asks again at once, page after page, each one its own request.

import { useEffect, useState } from "preact/hooks";
import { ApiError, getPerf, getPerfData, runCommand } from "../api/client";
import type {
  EngineEvent, PerfConfig, PerfEngine, PerfmonBlock, PerfPoint, Tickstat,
} from "../api/types";
import { record } from "../ui/activity";

/** What the page keeps. The server keeps an hour, and only since map load. */
export const kHistoryMs = 2 * 60 * 60 * 1000;
export const kStockIntervalMs = 60_000;

export interface PerfSegment {
  /** Milliseconds; null for a stock server, which does not say. */
  loadedAt: number | null;
  map: string | null;
  points: PerfPoint[];
  tickstats: Tickstat[];
  perfmon: PerfmonBlock[];
  events: EngineEvent[];
}

/** What the server says about its log, from the latest reply; the records are in the segments. */
export type EngineStatus = Omit<PerfEngine, "tickstats" | "perfmon" | "events">;

export interface PerfState {
  source: "mod" | "stock" | null;
  segments: PerfSegment[];
  config: PerfConfig | null;
  windowSeconds: number | null;
  capacity: number | null;
  /** The oldest point this page still holds, in milliseconds. */
  keptSince: number | null;
  /** Null on stock, or from a mod that predates it. */
  engine: EngineStatus | null;
  error: Error | null;
  loading: boolean;
  updatedAt: number | null;
}

/** Pages one poll follows: an hour is 6 of windows, up to 11 of engine records. */
const kMaxPages = 20;

const empty: PerfState = {
  source: null, segments: [], config: null, windowSeconds: null, capacity: null,
  keptSince: null, engine: null, error: null, loading: true, updatedAt: null,
};

let state: PerfState = empty;
let cursor = 0;
let engineCursor = 0;
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setTimeout> | null = null;
let inFlight: Promise<void> | null = null;

function emit(next: Partial<PerfState>) {
  state = { ...state, ...next };
  for (const l of listeners) l();
}

/** Drop what is older than kHistoryMs, and segments left with nothing. */
function trim(segments: PerfSegment[]): PerfSegment[] {
  const cutoff = Date.now() - kHistoryMs;
  const keep = <T extends { at: number }>(list: T[]): T[] =>
    list.length && list[0]!.at < cutoff ? list.filter((r) => r.at >= cutoff) : list;
  return segments
    .map((s) => ({ ...s, points: keep(s.points), tickstats: keep(s.tickstats),
                   perfmon: keep(s.perfmon), events: keep(s.events) }))
    .filter((s, i, all) => s.points.length + s.tickstats.length + s.perfmon.length
      + s.events.length > 0 || i === all.length - 1);
}

const newSegment = (loadedAt: number | null, map: string | null): PerfSegment =>
  ({ loadedAt, map, points: [], tickstats: [], perfmon: [], events: [] });

/** Records newer than the newest held, by id: a reply can never add one twice. */
function fresh<T extends { id: number | null }>(held: T[], incoming: T[]): T[] {
  const seen = held.length ? held[held.length - 1]!.id ?? 0 : 0;
  const add = incoming.filter((r) => (r.id ?? 0) > seen);
  return add.length ? [...held, ...add] : held;
}

/** One page. True when the server holds more past the cursors it moved. */
async function pollMod(): Promise<boolean> {
  let report = await getPerf(cursor, engineCursor);
  const current = state.segments[state.segments.length - 1];
  const restarted = current !== undefined && current.loadedAt !== report.loadedAt;
  if (restarted && (cursor > 0 || engineCursor > 0)) {
    // A new map load: its ids restart at 1, so the old cursors would hide them.
    report = await getPerf(0, 0);
  }
  let segments = state.segments;
  if (current === undefined || restarted) {
    segments = [...segments, newSegment(report.loadedAt, report.map)];
  }
  const last = segments[segments.length - 1]!;
  const engine = report.engine;
  const next: PerfSegment = {
    ...last,
    points: fresh(last.points, report.points),
    tickstats: engine ? fresh(last.tickstats, engine.tickstats) : last.tickstats,
    perfmon: engine ? fresh(last.perfmon, engine.perfmon) : last.perfmon,
    events: engine ? fresh(last.events, engine.events) : last.events,
  };
  segments = [...segments.slice(0, -1), next];
  cursor = report.lastId;
  engineCursor = engine?.lastId ?? 0;
  segments = trim(segments);
  const first = segments[0]?.points[0];
  let status: EngineStatus | null = null;
  if (engine) {
    const { tickstats: _t, perfmon: _p, events: _e, ...rest } = engine;
    status = rest;
  }
  emit({
    source: "mod", segments, config: report.config,
    windowSeconds: report.windowSeconds, capacity: report.capacity,
    keptSince: first?.at ?? null, engine: status,
  });
  return report.more || (engine?.more ?? false);
}

async function pollStock(): Promise<void> {
  const points = await getPerfData();
  emit({
    source: "stock",
    segments: [{ ...newSegment(null, null), points }],
    config: null, windowSeconds: 60, capacity: 30,
    keptSince: points[0]?.at ?? null,
  });
}

let hasMod = false;

function poll(): Promise<void> {
  if (inFlight) return inFlight;
  inFlight = (async () => {
    try {
      if (hasMod) {
        let page = 1;
        while ((await pollMod()) && page < kMaxPages) page++;
      } else {
        await pollStock();
      }
      emit({ error: null, loading: false, updatedAt: Date.now() });
    } catch (e) {
      const busy = e instanceof ApiError && e.retryable;
      emit({ error: busy && state.segments.length ? null : (e as Error), loading: false });
    } finally {
      inFlight = null;
    }
  })();
  return inFlight;
}

function intervalMs(): number {
  if (!hasMod) return kStockIntervalMs;
  return (state.windowSeconds ?? 10) * 1000;
}

function schedule() {
  if (timer !== null) clearTimeout(timer);
  timer = null;
  if (listeners.size === 0) return;
  timer = setTimeout(async () => {
    if (!document.hidden) await poll();
    schedule();
  }, intervalMs());
}

function onVisibility() {
  if (document.hidden) return;
  void poll().then(schedule);
}

/** Switch source. A server that gained or lost the mod starts a new history. */
function setSource(mod: boolean) {
  if (mod === hasMod && state.source !== null) return;
  hasMod = mod;
  cursor = 0;
  engineCursor = 0;
  state = { ...empty };
}

export function refreshPerf(): Promise<void> {
  return poll();
}

export interface TickstatOutcome {
  /** "confirmed": the server's log said so; "unconfirmed": sent, not yet seen. */
  kind: "confirmed" | "unconfirmed" | "error";
  note: string;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Turn the engine's tickstat on at `seconds` (0 turns it off). The command
 * prints only to the server's log, never through Lua, so runcommand comes
 * back with no lines whether it worked or not. What proves it is the
 * `tickstat: on|off` the engine then logs, which the mod's scan of the log
 * picks up within `scan_s`: so read until that reply changes, a few scans'
 * worth, and say which it was.
 */
export async function setTickstat(seconds: number): Promise<TickstatOutcome> {
  const command = `tickstat ${Math.max(0, Math.round(seconds))}`;
  const want = seconds > 0 ? "on" : "off";
  const before = state.engine?.tickstatSaid ?? null;
  try {
    await runCommand(command);
  } catch (e) {
    const note = `could not be sent: ${(e as Error).message}`;
    record(command, note, "error");
    return { kind: "error", note };
  }
  const scan = (state.engine?.scanSeconds ?? 2) * 1000;
  for (let i = 0; i < 3; i++) {
    await sleep(scan + 500);
    await poll();
    const said = state.engine?.tickstatSaid ?? null;
    if (said && said.text === want
        && (before === null || said.at !== before.at || said.text !== before.text)) {
      const note = `the server's log says tickstat is ${want}.`;
      record(command, note, "sent");
      return { kind: "confirmed", note };
    }
  }
  const note = `sent, but the server's log has not said tickstat is ${want} yet.`;
  record(command, note, "sent");
  return { kind: "unconfirmed", note };
}

export function usePerf(mod: boolean): PerfState {
  const [, force] = useState(0);
  useEffect(() => {
    setSource(mod);
    const listener = () => force((n) => n + 1);
    listeners.add(listener);
    if (listeners.size === 1) {
      document.addEventListener("visibilitychange", onVisibility);
      void poll().then(schedule);
    }
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) {
        document.removeEventListener("visibilitychange", onVisibility);
        if (timer !== null) clearTimeout(timer);
        timer = null;
      }
    };
  }, [mod]);
  return state;
}

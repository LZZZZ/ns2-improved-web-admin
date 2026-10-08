// The Log tab's copy of log-Server.txt.
//
// The mod's getlog serves the engine's log by byte offset, whole lines only,
// each carrying its offset. So the state here is a byte cursor, the file it
// belongs to, and the lines read so far, merged by offset -- a line can never
// arrive twice. What this has to get right, all of it from how the file and
// the Lua behave (docs/REQUIREMENTS.md item 7):
//
//   * The file outlives a map change: unlike the console buffer, nothing
//     restarts when the map does, and the cursor stays good.
//   * A restart moves the file to log-Server.old.txt and starts a new one
//     with a new Date/Time header. The server notices from `file` and answers
//     with a fresh tail marked `reset`; so does a file shorter than the cursor.
//   * One reply carries at most 64 KB: more cost the server a third of a tick
//     to encode (docs/SERVER-COST.md). `more` means ask again at once, which a
//     poll does up to kSkipBytes' worth, one reply after the other; a tab that
//     was away while megabytes were written takes the latest tail instead of
//     replaying them, and says so.
//
// It polls only while the tab is open, and not while the page is hidden. What
// it has read outlives the tab being closed and reopened: the cursor catches up.

import { useEffect, useState } from "preact/hooks";
import { ApiError, getLog } from "../api/client";
import type { LogLine, LogPage } from "../api/types";

/** Lines kept in the page. About 2 MB of log; the oldest go first. */
const kMaxLines = 20000;
/** Replies read back to back in one poll when the server says `more`: 1 MB of 64 KB ones. */
const kCatchUpReplies = 16;
/** Further behind than this, take the latest tail rather than catching up. */
const kSkipBytes = 1024 * 1024;

export type LogReset = "new_file" | "truncated" | "skipped";

export interface LogState {
  /** What the server said: its log, none reachable, or not asked yet. */
  source: "file" | "none" | null;
  /** When `source` is "none": the path it tried, what it found, and whether
   *  the file opened but is not the one being written. */
  unavailable: { path: string; error: string; stale: boolean } | null;
  fileId: string | null;
  /** The file's size at the last read, in bytes. */
  size: number;
  lines: LogLine[];
  /** The first line held is the file's first. */
  atStart: boolean;
  /** Set when the lines were replaced rather than added to; the tab says why. */
  reset: LogReset | null;
  /** Bytes passed over for a `skipped` reset. */
  skippedBytes: number;
  loadingEarlier: boolean;
  error: Error | null;
  loading: boolean;
  updatedAt: number | null;
}

const empty: LogState = {
  source: null, unavailable: null, fileId: null, size: 0, lines: [],
  atStart: false, reset: null, skippedBytes: 0, loadingEarlier: false,
  error: null, loading: true, updatedAt: null,
};

let state: LogState = empty;
let cursor = 0;
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setTimeout> | null = null;
let inFlight: Promise<void> | null = null;
let intervalMs = 2000;

function emit(next: Partial<LogState>) {
  state = { ...state, ...next };
  for (const l of listeners) l();
}

/** Merge by offset, keep sorted, trim the oldest. */
function merge(existing: LogLine[], incoming: LogLine[], trimOldest: boolean): LogLine[] {
  if (incoming.length === 0) return existing;
  const last = existing[existing.length - 1];
  let merged: LogLine[];
  if (last === undefined || incoming[0]!.off > last.off) {
    merged = existing.concat(incoming);              // the usual case: appended
  } else {
    const seen = new Set(existing.map((l) => l.off));
    merged = existing.concat(incoming.filter((l) => !seen.has(l.off)));
    merged.sort((a, b) => a.off - b.off);
  }
  return trimOldest && merged.length > kMaxLines ? merged.slice(-kMaxLines) : merged;
}

type FilePage = Extract<LogPage, { source: "file" }>;

/** Start over from a tail: the first read, or a reset of any kind. */
function replaceWith(page: FilePage, reset: LogReset | null, skippedBytes = 0) {
  cursor = page.to;
  emit({
    source: "file", unavailable: null, fileId: page.fileId, size: page.size,
    lines: page.lines, atStart: page.atStart, reset, skippedBytes,
  });
}

async function pollOnce(): Promise<void> {
  if (state.fileId === null) {
    const page = await getLog({});
    if (page.source === "none") {
      emit({ source: "none", unavailable: { path: page.path, error: page.error, stale: page.stale } });
      return;
    }
    replaceWith(page, null);
    return;
  }

  for (let i = 0; i < kCatchUpReplies; i++) {
    const page = await getLog({ since: cursor, file: state.fileId });
    if (page.source === "none") {
      // It was readable and is not now: say so, and start over when it is.
      cursor = 0;
      emit({ ...empty, loading: false,
             source: "none", unavailable: { path: page.path, error: page.error, stale: page.stale } });
      return;
    }
    if (page.reset) {
      replaceWith(page, page.reset);
      return;
    }
    if (page.size - page.to > kSkipBytes && i === 0) {
      // Far behind (the tab was closed, or the page hidden, while a lot was
      // written): take the end instead of replaying megabytes.
      const tail = await getLog({});
      if (tail.source === "file") {
        replaceWith(tail, "skipped", Math.max(0, tail.from - cursor));
        return;
      }
    }
    cursor = page.to;
    const atStart = state.lines.length === 0 ? page.atStart : state.atStart;
    const lines = merge(state.lines, page.lines, true);
    emit({
      size: page.size, lines,
      // Trimming the oldest leaves the start of the file behind.
      atStart: atStart && lines[0]?.off === 0,
    });
    if (!page.more) return;
  }
}

function poll(): Promise<void> {
  if (inFlight) return inFlight;
  inFlight = (async () => {
    try {
      await pollOnce();
      emit({ error: null, loading: false, updatedAt: Date.now() });
    } catch (e) {
      const busy = e instanceof ApiError && e.retryable;
      emit({ error: busy && state.source !== null ? state.error : (e as Error),
             loading: false });
    } finally {
      inFlight = null;
    }
  })();
  return inFlight;
}

function schedule() {
  if (timer !== null) clearTimeout(timer);
  timer = null;
  if (intervalMs <= 0 || listeners.size === 0) return;
  timer = setTimeout(async () => {
    if (!document.hidden) await poll();
    schedule();
  }, intervalMs);
}

function onVisibility() {
  if (document.hidden || intervalMs <= 0) return;
  void poll().then(schedule);
}

/** The page before the first line held, prepended. */
export async function loadEarlier(): Promise<void> {
  const first = state.lines[0];
  if (state.source !== "file" || state.fileId === null || first === undefined
      || state.atStart || state.loadingEarlier) return;
  emit({ loadingEarlier: true });
  try {
    const page = await getLog({ before: first.off, file: state.fileId });
    if (page.source === "none") {
      emit({ source: "none", unavailable: { path: page.path, error: page.error, stale: page.stale } });
    } else if (page.reset) {
      replaceWith(page, page.reset);
    } else {
      emit({ lines: merge(state.lines, page.lines, false), atStart: page.atStart,
             error: null });
    }
  } catch (e) {
    emit({ error: e as Error });
  } finally {
    emit({ loadingEarlier: false });
  }
}

export function acknowledgeReset() {
  emit({ reset: null, skippedBytes: 0 });
}

/** Read now, outside the schedule: what the tab offers while refresh is off. */
export function refreshLog(): Promise<void> {
  return poll();
}

export function setLogIntervalMs(ms: number) {
  intervalMs = ms;
  schedule();
}

export function useLog(): LogState {
  const [, force] = useState(0);
  useEffect(() => {
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
  }, []);
  return state;
}

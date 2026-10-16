// The chat stream, for the Chat tab.
//
// A stream read with a cursor (the Console tab's was the same until it
// merged into the log): entries carry increasing ids, ids restart from 1 when the map
// changes (the buffer is Lua state), and entries can fall out of the ring
// before anyone reads them.
//
// The server keeps 200 entries and answers `since`, so a poll carries only
// what is new.

import { useEffect, useState } from "preact/hooks";
import { ApiError, getChat } from "../api/client";
import type { ChatEntry } from "../api/types";

/** Kept client-side. The server's ring is 200; holding more costs nothing. */
const kMaxEntries = 1000;

export interface ChatState {
  entries: ChatEntry[];
  cursor: number;
  /** Entries the server dropped before we read them. */
  dropped: number;
  /** The server's ring size. */
  bufferSize: number | null;
  error: Error | null;
  loading: boolean;
}

let state: ChatState = {
  entries: [], cursor: 0, dropped: 0, bufferSize: null, error: null, loading: true,
};
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setTimeout> | null = null;
let inFlight = false;
let intervalMs = 2000;

function emit(next: Partial<ChatState>) {
  state = { ...state, ...next };
  for (const l of listeners) l();
}

/** Merge by id, keep sorted, trim. Ids are unique per map. */
function merge(existing: ChatEntry[], incoming: ChatEntry[]): ChatEntry[] {
  if (incoming.length === 0) return existing;
  const seen = new Set(existing.map((e) => e.id));
  const merged = existing.concat(incoming.filter((e) => !seen.has(e.id)));
  merged.sort((a, b) => a.id - b.id);
  return merged.length > kMaxEntries ? merged.slice(-kMaxEntries) : merged;
}

async function poll(): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    let page = await getChat(state.cursor);
    if (page.lastId < state.cursor) {
      // Ids went backwards: the Lua state was rebuilt, so the map changed.
      // That reply was cut at the old cursor, so read the new map's from 0.
      page = await getChat(0);
      emit({
        entries: page.entries, cursor: page.lastId,
        dropped: page.dropped, bufferSize: page.bufferSize,
        error: null, loading: false,
      });
      return;
    }
    emit({
      entries: merge(state.entries, page.entries),
      cursor: Math.max(state.cursor, page.lastId),
      dropped: page.dropped,
      bufferSize: page.bufferSize,
      error: null,
      loading: false,
    });
  } catch (e) {
    const busy = e instanceof ApiError && e.retryable;
    emit({ error: busy ? state.error : (e as Error), loading: false });
  } finally {
    inFlight = false;
  }
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

/** The current state, outside a component: for checking what a send did. */
export function getChatState(): ChatState {
  return state;
}

/** Read now, outside the schedule: after a send, or while refresh is off. */
export function refreshChat(): Promise<void> {
  return poll();
}

export function setChatIntervalMs(ms: number) {
  intervalMs = ms;
  schedule();
}

export function useChat(): ChatState {
  const [, force] = useState(0);
  useEffect(() => {
    const listener = () => force((n) => n + 1);
    listeners.add(listener);
    if (listeners.size === 1) {
      void poll();
      schedule();
    }
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0 && timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
    };
  }, []);
  return state;
}

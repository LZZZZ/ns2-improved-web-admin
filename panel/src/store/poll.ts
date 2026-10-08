// Polling, in one place.
//
// The panel is a poller -- there is no push side to this API -- so the rules
// that keep polling honest live here rather than in each tab:
//
//   * single flight. One request per resource in the air at a time; a slow
//     reply never stacks up behind the next tick.
//   * pause when the tab is hidden, and fetch immediately on return, so a
//     backgrounded panel is not still costing the server a request a second.
//   * a busy server (503) keeps the last good data and is not an error state.
//   * subscribers are ref-counted: the last one to leave stops the timer.

import { useEffect, useState } from "preact/hooks";
import { ApiError } from "../api/client";

export interface ResourceState<T> {
  data: T | null;
  error: Error | null;
  /** True only for the first load; a refresh keeps the old data visible. */
  loading: boolean;
  updatedAt: number | null;
}

export interface Resource<T> {
  get(): ResourceState<T>;
  subscribe(listener: () => void): () => void;
  /** Fetch now, outside the schedule. Returns when the fetch settles. */
  refresh(): Promise<void>;
  setIntervalMs(ms: number): void;
}

export function createResource<T>(
  fetcher: (signal: AbortSignal) => Promise<T>,
  intervalMs: number,
): Resource<T> {
  let state: ResourceState<T> = {
    data: null, error: null, loading: true, updatedAt: null,
  };
  const listeners = new Set<() => void>();
  let timer: ReturnType<typeof setTimeout> | null = null;
  let inFlight: Promise<void> | null = null;
  let controller: AbortController | null = null;
  let interval = intervalMs;

  const emit = (next: Partial<ResourceState<T>>) => {
    state = { ...state, ...next };
    for (const l of listeners) l();
  };

  async function fetchOnce(): Promise<void> {
    if (inFlight) return inFlight;          // single flight
    controller = new AbortController();
    inFlight = (async () => {
      try {
        const data = await fetcher(controller!.signal);
        emit({ data, error: null, loading: false, updatedAt: Date.now() });
      } catch (e) {
        if ((e as Error).name === "AbortError") return;
        const busy = e instanceof ApiError && e.retryable;
        // A busy server is a state the panel rides out, not one it reports.
        emit({
          error: busy && state.data ? null : (e as Error),
          loading: false,
        });
      } finally {
        inFlight = null;
        controller = null;
      }
    })();
    return inFlight;
  }

  function schedule() {
    if (timer !== null) clearTimeout(timer);
    if (interval <= 0) { timer = null; return; }
    timer = setTimeout(tick, interval);
  }

  async function tick() {
    if (!document.hidden) await fetchOnce();
    if (listeners.size > 0) schedule();
  }

  function onVisibility() {
    if (document.hidden) return;
    void fetchOnce();
    schedule();
  }

  return {
    get: () => state,
    subscribe(listener) {
      listeners.add(listener);
      if (listeners.size === 1) {
        document.addEventListener("visibilitychange", onVisibility);
        void fetchOnce();
        schedule();
      }
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0) {
          document.removeEventListener("visibilitychange", onVisibility);
          if (timer !== null) clearTimeout(timer);
          timer = null;
          controller?.abort();
        }
      };
    },
    refresh: () => fetchOnce(),
    setIntervalMs(ms) {
      interval = ms;
      if (listeners.size > 0) schedule();
    },
  };
}

export function useResource<T>(resource: Resource<T>): ResourceState<T> {
  const [, force] = useState(0);
  useEffect(() => resource.subscribe(() => force((n) => n + 1)), [resource]);
  return resource.get();
}

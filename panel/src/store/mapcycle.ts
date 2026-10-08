// The map cycle, edited in place and written on every change.
//
// `setmapcycle` replaces the whole document, so every edit is a read-modify-
// write, and three things keep that honest:
//
//   * the cycle is never rebuilt from the panel's own fields. Each edit is a
//     function applied to a copy of what the server last said, so keys this
//     panel does not know (Shine's per-map options, map groups) survive. The
//     2012 panel dropped them on every save.
//   * before each write the cycle is read again, and if it changed since the
//     panel last saw it -- another admin, or a hand edit of the file -- the
//     write is not made. The operator reloads and redoes the change.
//   * what the server holds afterwards is what the panel shows, and the
//     activity strip says how that was established: the mod returns the file
//     read back, a stock server returns nothing, so there the cycle is read
//     again and the note says it is the server's copy, not the file.
//
// Writes are one at a time. Edits made while one is in flight are applied on
// top of it and go out together in the next.

import { useEffect, useState } from "preact/hooks";
import { getMapCycle, setMapCycle } from "../api/client";
import type { RawMapCycle } from "../api/types";
import { record } from "../ui/activity";

export type Edit = (cycle: RawMapCycle) => RawMapCycle;

export interface MapCycleState {
  /** What the server last said the cycle is. */
  base: RawMapCycle | null;
  /** `base` with the edits not yet confirmed applied: what the tab shows. */
  shown: RawMapCycle | null;
  loading: boolean;
  error: string | null;
  saving: boolean;
  /**
   * The cycle changed on the server since it was loaded, so writing is
   * stopped until a reload. Holds what the server has now.
   */
  conflict: RawMapCycle | null;
  /** The cycle before the last write that landed; Undo writes it back. */
  undo: RawMapCycle | null;
  /** How the last write went, for the tab's own status line. */
  last: { note: string; tone: "sent" | "error" } | null;
}

let state: MapCycleState = {
  base: null, shown: null, loading: false, error: null, saving: false,
  conflict: null, undo: null, last: null,
};
const listeners = new Set<() => void>();

function emit(next: Partial<MapCycleState>) {
  state = { ...state, ...next };
  for (const l of listeners) l();
}

const copy = (c: RawMapCycle): RawMapCycle => JSON.parse(JSON.stringify(c));

/** JSON with object keys sorted: the server re-orders keys on every write. */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const o = value as Record<string, unknown>;
    return `{${Object.keys(o).sort()
      .filter((k) => o[k] !== undefined)
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export const sameCycle = (a: RawMapCycle, b: RawMapCycle) =>
  canonical(a) === canonical(b);

let pending: { edit: Edit; label: string }[] = [];
let inFlight: RawMapCycle | null = null;

function reshow() {
  const start = inFlight ?? state.base;
  emit({ shown: start ? pending.reduce((c, p) => p.edit(copy(c)), start) : null });
}

/** Read the cycle, dropping any conflict and unsent edits. */
export async function loadMapCycle(): Promise<void> {
  if (state.saving) return;
  emit({ loading: true });
  try {
    const cycle = await getMapCycle();
    pending = [];
    emit({ base: cycle, loading: false, error: null, conflict: null });
    reshow();
  } catch (e) {
    emit({ loading: false, error: (e as Error).message });
  }
}

/**
 * Apply an edit and write the result. `label` says what the edit was, in the
 * activity strip.
 */
export function commitMapCycle(edit: Edit, label: string, hasMod: boolean) {
  if (!state.base || state.conflict) return;
  pending.push({ edit, label });
  reshow();
  if (!state.saving) void flush(hasMod);
}

/** Write back the cycle as it was before the last write that landed. */
export function undoMapCycle(hasMod: boolean) {
  const before = state.undo;
  if (!before) return;
  commitMapCycle(() => copy(before), "undo the last change", hasMod);
}

async function flush(hasMod: boolean): Promise<void> {
  const base = state.base;
  if (!base || pending.length === 0) return;
  const batch = pending;
  pending = [];
  const next = batch.reduce((c, p) => p.edit(copy(c)), base);
  const label = batch.map((p) => p.label).join("; ");
  const what = `setmapcycle (${label})`;
  inFlight = next;
  emit({ saving: true });
  reshow();

  const fail = (note: string) => {
    record(what, note, "error");
    pending = [];
    emit({ last: { note, tone: "error" } });
  };

  try {
    const now = await getMapCycle();
    if (!sameCycle(now, base)) {
      fail("not written: the cycle changed on the server since this panel "
        + "read it. Reload to see it, then make the change again.");
      emit({ conflict: now });
      return;
    }

    const result = await setMapCycle(next, hasMod);
    if (result.kind === "refused") {
      fail(`refused, nothing written: ${result.error}`);
      return;
    }

    let after: RawMapCycle;
    let note: string;
    let tone: "sent" | "error" = "sent";
    if (result.kind === "written") {
      after = result.cycle;
      note = sameCycle(after, next)
        ? "written; MapCycle.json reads back as sent."
        : "written, but MapCycle.json reads back differently. Showing the file.";
    } else {
      // A stock server's reply is empty whatever happened, and its
      // getmapcycle answers from memory, not from the file.
      after = await getMapCycle();
      note = sameCycle(after, next)
        ? "sent. The server's copy now matches; this server cannot say "
          + "whether MapCycle.json was written."
        : "sent, but the server's copy does not match what was sent. Showing "
          + "the server's copy.";
    }
    if (!sameCycle(after, next)) tone = "error";
    record(what, note, tone);
    emit({ base: after, undo: base, last: { note, tone } });
  } catch (e) {
    fail(`could not be sent: ${(e as Error).message}`);
  } finally {
    inFlight = null;
    emit({ saving: false });
    reshow();
    if (pending.length > 0 && !state.conflict) void flush(hasMod);
    else pending = [];
  }
}

export function useMapCycle(): MapCycleState {
  const [, force] = useState(0);
  useEffect(() => {
    const listener = () => force((n) => n + 1);
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  }, []);
  return state;
}

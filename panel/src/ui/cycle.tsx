// The parts of a map cycle editor that the Maps and Mods tabs share. Both
// write through store/mapcycle.ts, so both stop on the same conflict, undo the
// same last write and report it the same way.

import { loadMapCycle, undoMapCycle, type MapCycleState } from "../store/mapcycle";

/** The cycle could not be read, or changed on the server since it was. */
export function CycleBanners({ cycle }: { cycle: MapCycleState }) {
  return (
    <>
      {cycle.error && (
        <div class="banner">
          <h2>Cannot read the map cycle</h2>
          <p>{cycle.error}</p>
        </div>
      )}
      {cycle.conflict && (
        <div class="banner conflict-banner">
          <h2>The cycle changed on the server</h2>
          <p>
            Someone else, or a hand edit of MapCycle.json, changed it after
            this panel read it, so the last change was not written.{" "}
            <button class="btn btn-sm" onClick={() => void loadMapCycle()}>
              Reload the cycle
            </button>
          </p>
        </div>
      )}
    </>
  );
}

/** Undo the last write, and read the cycle again. */
export function UndoReload({ cycle, hasMod }: { cycle: MapCycleState; hasMod: boolean }) {
  return (
    <>
      <button class="btn"
              disabled={cycle.undo === null || cycle.saving || cycle.conflict !== null}
              onClick={() => undoMapCycle(hasMod)}
              title="Write back the cycle as it was before the last change">
        Undo last change
      </button>
      <button class="btn" disabled={cycle.saving} onClick={() => void loadMapCycle()}>
        Reload
      </button>
    </>
  );
}

/** How the last write went, or `idle` when nothing has been written yet. */
export function CycleNote({ cycle, idle }: { cycle: MapCycleState; idle: string }) {
  return (
    <p class={`muted form-hint${cycle.last?.tone === "error" ? " tone-error" : ""}`}
       aria-live="polite">
      {cycle.saving ? "Writing..." : cycle.last ? cycle.last.note : idle}
    </p>
  );
}

import {
  ArrowDown, ArrowUp, Copy, GripVertical, PackagePlus, Play, Plus, SlidersHorizontal,
  TriangleAlert, X,
} from "lucide-preact";
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type {
  InstalledMod, MapInfo, MapVote, RawMapCycle, RawMapCycleEntry, ServerState,
} from "../api/types";
import { sendCommand } from "../store/commands";
import { commitMapCycle, loadMapCycle, useMapCycle } from "../store/mapcycle";
import { useResource } from "../store/poll";
import { installedMods, mapList, mapVote } from "../store/resources";
import { CycleBanners, UndoReload } from "../ui/cycle";
import { IconButton, StatusIcon } from "../ui/Icon";
import { MapName } from "../ui/Minimap";
import { consoleArg } from "../ui/format";

// ------------------------------------------------------------ cycle helpers

const entryName = (e: RawMapCycleEntry): string =>
  typeof e === "string" ? e : String(e.map ?? "");

const entryMods = (e: RawMapCycleEntry): string[] =>
  typeof e === "string" || !Array.isArray(e.mods) ? [] : e.mods.map(String);

/** Keys on an entry that the game ignores and Shine's mapvote reads. */
function entryExtras(e: RawMapCycleEntry): [string, unknown][] {
  if (typeof e === "string") return [];
  return Object.entries(e).filter(([k]) => k !== "map" && k !== "mods");
}

/** What is being dragged, and where it would land now. */
type DragItem = { from: "cycle"; index: number } | { from: "available"; map: MapInfo };
type Drop = { list: "cycle"; at: number } | { list: "available" };
interface Drag { item: DragItem; over: Drop | null }

function move<T>(list: T[], from: number, to: number): T[] {
  const next = list.slice();
  const [item] = next.splice(from, 1);
  next.splice(to, 0, item as T);
  return next;
}

/**
 * The next map as core/lua/MapCycle.lua picks it with no vote in the way:
 * after the *last* entry naming the current map, wrapping round.
 */
function vanillaNextMap(cycle: RawMapCycle, current: string): string | null {
  const names = cycle.maps.map(entryName);
  if (names.length === 0) return null;
  const at = names.lastIndexOf(current);
  return names[(at + 1) % names.length] ?? null;
}

const SHINE_MODE_REASON =
  "Shine's mapvote picks the next map, by vote or else in list order; the mode is not used.";

export function Maps({ state }: { state: ServerState }) {
  const hasMod = state.modVersion !== null;
  const cycle = useMapCycle();
  const maps = useResource(mapList);
  const mods = useResource(installedMods);

  useEffect(() => {
    void loadMapCycle();
    void mapList.refresh();
    void installedMods.refresh();
  }, []);

  return (
    <section class="wrap maps-tab">
      {!hasMod && (
        <div class="banner">
          <h2>Stock server Lua</h2>
          <p>
            A stock server answers every cycle write with an empty reply, and
            shows the cycle it loaded with the map rather than MapCycle.json. A
            hand edit of the file does not show here until the map changes,
            and a change made here writes over it. The mod reads and confirms
            the file.
          </p>
        </div>
      )}
      <CycleBanners cycle={cycle} />
      {cycle.shown ? (
        <Editor
          state={state}
          hasMod={hasMod}
          cycle={cycle.shown}
          saving={cycle.saving}
          locked={cycle.conflict !== null}
          last={cycle.last}
          maps={maps.data}
          mods={mods.data}
        />
      ) : (
        <p class="muted">{cycle.loading ? "Loading the map cycle..." : ""}</p>
      )}
    </section>
  );
}

// ------------------------------------------------------------ editor

interface EditorProps {
  state: ServerState;
  hasMod: boolean;
  cycle: RawMapCycle;
  saving: boolean;
  locked: boolean;
  last: { note: string; tone: "sent" | "error" } | null;
  maps: MapInfo[] | null;
  mods: InstalledMod[] | null;
}

function Editor(p: EditorProps) {
  const { state, hasMod, cycle, locked } = p;
  const store = useMapCycle();
  const shineVote = hasMod && state.shine?.mapVote === true;
  const vote = shineVote ? <VoteNext /> : null;

  const commit = (label: string, edit: (c: RawMapCycle) => RawMapCycle) =>
    commitMapCycle(edit, label, hasMod);

  const modName = useMemo(() => {
    const byId = new Map((p.mods ?? []).map((m) => [m.id.toLowerCase(), m.name]));
    return (id: string) => byId.get(id.toLowerCase()) ?? null;
  }, [p.mods]);
  const mapById = useMemo(
    () => new Map((p.maps ?? []).map((m) => [m.name, m])), [p.maps]);
  // The mods every map loads are the Mods tab's to edit; here they only decide
  // whether a mod map still needs its own.
  const globalSet = new Set((cycle.mods ?? []).map((m) => String(m).toLowerCase()));

  const names = cycle.maps.map(entryName);
  const topExtras = Object.keys(cycle)
    .filter((k) => !["maps", "time", "mode", "mods"].includes(k));
  const counts = new Map<string, number>();
  for (const n of names) counts.set(n, (counts.get(n) ?? 0) + 1);

  // --------------------------------------------------------------- time
  const [time, setTime] = useState(String(cycle.time ?? ""));
  useEffect(() => { setTime(String(cycle.time ?? "")); }, [cycle.time]);
  const validTime = (text: string) =>
    text.trim() !== "" && Number.isFinite(Number(text)) && Number(text) >= 0;
  const timeValid = validTime(time);
  // Read from the input itself: a change can arrive before the render that
  // follows the last keystroke.
  const setCycleTime = (e: Event) => {
    const text = (e.currentTarget as HTMLInputElement).value;
    const value = Number(text);
    if (!validTime(text) || value === cycle.time) return;
    commit(`time ${value}`, (c) => ({ ...c, time: value }));
  };

  // --------------------------------------------------------------- rows
  const edit = (label: string, fn: (list: RawMapCycleEntry[]) => RawMapCycleEntry[]) =>
    commit(label, (c) => ({ ...c, maps: fn(c.maps) }));

  const moveEntry = (from: number, to: number) => {
    if (to < 0 || to >= cycle.maps.length || from === to) return;
    edit(`move ${names[from]} to ${to + 1}`, (l) => move(l, from, to));
  };

  const remove = (i: number) => {
    if (cycle.maps.length === 1) return;
    edit(`remove ${names[i]}`, (l) => l.filter((_, j) => j !== i));
  };

  /**
   * A mod map joins the cycle naming its mod, unless every map loads it. At
   * the end, or at `at` when it was dropped there.
   */
  const add = (m: MapInfo, at?: number) => {
    const entry: RawMapCycleEntry = m.modId && !globalSet.has(m.modId.toLowerCase())
      ? { map: m.name, mods: [m.modId] }
      : m.name;
    if (at === undefined || at >= cycle.maps.length) {
      edit(`add ${m.name}`, (l) => [...l, entry]);
    } else {
      edit(`add ${m.name} at ${at + 1}`, (l) => [...l.slice(0, at), entry, ...l.slice(at)]);
    }
  };

  const loadModWith = (i: number, modId: string) =>
    edit(`load ${names[i]}'s mod with it`, (l) => l.map((e, j) => {
      if (j !== i) return e;
      if (typeof e === "string") return { map: e, mods: [modId] };
      return { ...e, mods: [...entryMods(e), modId] };
    }));

  const changeTo = (map: string) => {
    const players = state.playersOnline;
    if (!confirm(`Change map to ${map} now?`
      + (players > 0 ? ` ${players} player${players === 1 ? "" : "s"} will go with it.` : ""))) return;
    void sendCommand(`sv_changemap ${consoleArg(map)}`, hasMod,
      shineVote ? [mapVote] : []);
  };

  // --------------------------------------------------------------- drag
  // Pointer events on the handles, so mouse, pen and touch all work without a
  // library. A cycle map dragged within the cycle moves, dragged onto the
  // available maps leaves the cycle; an available map dragged into the cycle
  // joins it where it is dropped. Over a row, its upper half drops before it
  // and its lower half after it. Each drop is one write, with Undo.
  const [drag, setDrag] = useState<Drag | null>(null);
  const dragRef = useRef(drag);
  dragRef.current = drag;
  const targetAt = (x: number, y: number): Drop | null => {
    const el = document.elementFromPoint(x, y);
    const row = el?.closest(".cycle-table tr[data-index]") as HTMLElement | null;
    if (row) {
      const box = row.getBoundingClientRect();
      const i = Number(row.dataset["index"]);
      return { list: "cycle", at: y < box.top + box.height / 2 ? i : i + 1 };
    }
    if (el?.closest(".cycle-pane")) return { list: "cycle", at: cycle.maps.length };
    if (el?.closest(".available-pane")) return { list: "available" };
    return null;
  };
  const onDragStart = (item: Drag["item"]) => (e: PointerEvent) => {
    if (locked) return;
    e.preventDefault();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    setDrag({ item, over: null });
  };
  const onDragMove = (e: PointerEvent) => {
    const d = dragRef.current;
    if (!d) return;
    const over = targetAt(e.clientX, e.clientY);
    if (JSON.stringify(over) !== JSON.stringify(d.over)) setDrag({ ...d, over });
  };
  const onDragEnd = () => {
    const d = dragRef.current;
    setDrag(null);
    if (!d?.over) return;
    const { item, over } = d;
    if (item.from === "cycle" && over.list === "cycle") {
      moveEntry(item.index, over.at > item.index ? over.at - 1 : over.at);
    } else if (item.from === "cycle" && over.list === "available") {
      remove(item.index);
    } else if (item.from === "available" && over.list === "cycle") {
      add(item.map, over.at);
    }
  };
  // Where the line shows: before a row, or after the last one. None where the
  // drop would change nothing.
  const dropLine = (i: number): string => {
    const over = drag?.over;
    if (!drag || over?.list !== "cycle") return "";
    if (drag.item.from === "cycle"
      && (over.at === drag.item.index || over.at === drag.item.index + 1)) return "";
    if (over.at === i) return "drop-before";
    if (over.at === cycle.maps.length && i === cycle.maps.length - 1) return "drop-after";
    return "";
  };
  const dropOut = drag?.item.from === "cycle" && drag.over?.list === "available"
    && cycle.maps.length > 1;

  // --------------------------------------------------------------- available
  // Only maps the cycle does not have: adding one twice is a hand edit's job.
  // No filter: a server has a few dozen maps, and the two tables' headers
  // line up without one.
  const available = useMemo(
    () => (p.maps ?? []).filter((m) => !counts.has(m.name)), [p.maps, cycle]);

  const nextMap = shineVote ? null
    : cycle.mode === "random" ? "random" : vanillaNextMap(cycle, state.map);

  return (
    <>
      <div class="form-card cycle-settings">
        <div class="form-row">
          <span class="next-map">
            <span class="muted">next map </span>
            {shineVote ? vote : <b>{nextMap === "random"
              ? "random (never the current map)" : nextMap ?? "--"}</b>}
          </span>
          <form class="inline-form" onSubmit={(e) => {
            // Enter commits through the input's change event; blurring fires
            // it if it has not fired yet, and never twice.
            e.preventDefault();
            (e.currentTarget as HTMLFormElement).querySelector("input")?.blur();
          }}>
            <label>
              Minutes per map
              <input
                type="text"
                name="cycletime"
                inputMode="decimal"
                value={time}
                disabled={locked}
                onInput={(e) => setTime((e.target as HTMLInputElement).value)}
                onChange={setCycleTime}
              />
            </label>
          </form>
          <label>
            Order
            <select
              name="cyclemode"
              value={cycle.mode === "random" ? "random" : "order"}
              disabled={locked || shineVote}
              title={shineVote ? SHINE_MODE_REASON : undefined}
              onChange={(e) => {
                const mode = (e.target as HTMLSelectElement).value;
                commit(`mode ${mode}`, (c) => ({ ...c, mode }));
              }}
            >
              <option value="order">In order</option>
              <option value="random">Random</option>
            </select>
          </label>
          <span class="spacer" />
          <UndoReload cycle={store} hasMod={hasMod} />
        </div>
        <p class={`muted form-hint${p.last?.tone === "error" ? " tone-error" : ""}`}
           aria-live="polite">
          {p.saving ? "Writing..."
            : time.trim() !== "" && !timeValid ? "Minutes: a number, 0 or more (0 never changes map by time)."
            : p.last ? p.last.note
            : "Every change is written at once, as the whole cycle."}
        </p>
      </div>

      <div class={`maps-columns${drag ? " dragging-map" : ""}`}
           onPointerMove={onDragMove} onPointerUp={onDragEnd} onPointerCancel={onDragEnd}>
        <div class="cycle-pane">
          <h2 class="section-title">Cycle <span class="muted">{cycle.maps.length} maps</span>
            {topExtras.length > 0 && (
              <span class="tag" title="Kept as they are; edit them in MapCycle.json">
                Shine settings kept: {topExtras.join(", ")}
              </span>
            )}
          </h2>
          <div class={`table-wrap${locked ? " read-only" : ""}`}>
            <table class="cycle-table">
              <thead>
                <tr>
                  <th class="static num">#</th>
                  <th class="static" aria-label="Drag to reorder" />
                  <th class="static">Map</th>
                  <th class="static">Actions</th>
                </tr>
              </thead>
              <tbody>
                {cycle.maps.map((entry, i) => {
                  const name = names[i] as string;
                  const info = mapById.get(name);
                  const own = entryMods(entry);
                  const needs = info?.modId ?? null;
                  const missing = needs !== null && !globalSet.has(needs.toLowerCase())
                    && !own.some((m) => m.toLowerCase() === needs.toLowerCase());
                  const extras = entryExtras(entry);
                  const dup = (counts.get(name) ?? 0) > 1;
                  const cls = [
                    drag?.item.from === "cycle" && drag.item.index === i ? "dragging" : "",
                    dropLine(i),
                    name === state.map ? "current-map" : "",
                  ].filter(Boolean).join(" ");
                  return (
                    <tr key={`${i}:${name}`} data-index={i} data-map={name} class={cls}>
                      <td class="num muted">{i + 1}</td>
                      <td>
                        <span class="drag-handle" title="Drag to reorder, or onto the available maps to remove"
                              onPointerDown={onDragStart({ from: "cycle", index: i })}>
                          <GripVertical size={15} aria-hidden="true" />
                        </span>
                      </td>
                      <td class="name-cell">
                        <span class="icon-row">
                          <MapName name={name} />
                          {name === state.map && <span class="tag">playing</span>}
                          <span class="row-notes icon-row">
                            {p.maps && !info && own.length === 0 && (
                              <StatusIcon icon={TriangleAlert} tone="warn"
                                          label="Not among the server's maps: changing to it will fail, and the server moves on." />
                            )}
                            {missing && (
                              <>
                                <StatusIcon icon={TriangleAlert} tone="warn"
                                            label={`Needs ${modName(needs!) ?? needs}, which neither every map nor this entry loads.`} />
                                <IconButton icon={PackagePlus} label="Load its mod with this map"
                                            disabled={locked} onClick={() => loadModWith(i, needs!)} />
                              </>
                            )}
                            {dup && (
                              <StatusIcon icon={Copy} tone="warn"
                                          label={`Listed ${counts.get(name)} times. In order, rotation carries on from its last place, so the maps between are skipped.`} />
                            )}
                            {extras.length > 0 && (
                              <StatusIcon icon={SlidersHorizontal}
                                          label={`Shine options kept: ${extras.map(([k, v]) =>
                                            `${k} ${typeof v === "object" ? JSON.stringify(v) : String(v)}`)
                                            .join(", ")}`}
                                          title="Kept as they are; edit them in MapCycle.json" />
                            )}
                          </span>
                        </span>
                      </td>
                      <td>
                        <div class="actions">
                          <IconButton icon={ArrowUp} label={`Move ${name} up`}
                                      disabled={locked || i === 0}
                                      onClick={() => moveEntry(i, i - 1)} />
                          <IconButton icon={ArrowDown} label={`Move ${name} down`}
                                      disabled={locked || i === cycle.maps.length - 1}
                                      onClick={() => moveEntry(i, i + 1)} />
                          <IconButton icon={X} label="Remove from the cycle" danger
                                      disabled={locked || cycle.maps.length === 1}
                                      reason={cycle.maps.length === 1
                                        ? "A cycle needs at least one map." : undefined}
                                      onClick={() => remove(i)} />
                          <IconButton icon={Play} label={`Change to ${name} now`}
                                      onClick={() => changeTo(name)} />
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>

        <div class={`available-pane${dropOut ? " drop-target" : ""}`}>
          <h2 class="section-title">Available maps
            <span class="muted"> {p.maps
              ? `${available.length} not in the cycle, of ${p.maps.length} on the server`
              : "loading..."}</span>
          </h2>
          <div class="table-wrap">
            <table class="available-table">
              <thead>
                <tr>
                  <th class="static" aria-label="Drag into the cycle" />
                  <th class="static">Map</th>
                  <th class="static">From</th>
                  <th class="static">Actions</th>
                </tr>
              </thead>
              <tbody>
                {available.map((m) => (
                  <tr key={m.name} data-map={m.name}
                      class={drag?.item.from === "available" && drag.item.map.name === m.name
                        ? "dragging" : undefined}>
                    <td>
                      <span class="drag-handle" title="Drag into the cycle"
                            onPointerDown={onDragStart({ from: "available", map: m })}>
                        <GripVertical size={15} aria-hidden="true" />
                      </span>
                    </td>
                    <td class="name-cell"><MapName name={m.name} /></td>
                    <td>{m.modId === null ? <span class="muted">stock</span>
                      : <span class="mod-chip" title={m.modId}>{modName(m.modId) ?? m.modId}</span>}</td>
                    <td>
                      <div class="actions">
                        <IconButton icon={Plus} label="Add to the cycle" disabled={locked}
                                    onClick={() => add(m)} />
                        <IconButton icon={Play} label={`Change to ${m.name} now`}
                                    onClick={() => changeTo(m.name)} />
                      </div>
                    </td>
                  </tr>
                ))}
                {p.maps && available.length === 0 && (
                  <tr><td colSpan={4} class="muted">
                    Every map on the server is in the cycle.
                  </td></tr>
                )}
              </tbody>
            </table>
          </div>
          {dropOut && <p class="drop-hint">Drop to remove it from the cycle.</p>}
        </div>
      </div>
    </>
  );
}

function VoteNext() {
  const vote: MapVote | null = useResource(mapVote).data;
  if (!vote) return <b>--</b>;
  return <b title="Shine's GetNextMap: the vote's winner, or else the next in the list">
    {vote.nextMap ?? "not known"}</b>;
}

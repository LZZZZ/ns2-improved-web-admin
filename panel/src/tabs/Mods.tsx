import {
  CircleCheck, CircleMinus, CirclePlus, ClockArrowDown, ClockArrowUp, Globe, Map as MapIcon,
  Server, TriangleAlert,
} from "lucide-preact";
import { useEffect, useMemo, useState } from "preact/hooks";
import type {
  InstalledMod, MapInfo, RawMapCycle, RawMapCycleEntry, ServerState,
} from "../api/types";
import { commitMapCycle, loadMapCycle, useMapCycle } from "../store/mapcycle";
import { useResource } from "../store/poll";
import { installedMods, mapList } from "../store/resources";
import { CycleBanners, CycleNote, UndoReload } from "../ui/cycle";
import { IconButton, StatusIcon, type LucideIcon } from "../ui/Icon";
import {
  useWhitelist, WhitelistIcon, WhitelistSource, type Whitelist,
} from "../ui/whitelist";

// The installed mods, and the cycle's global `mods`: the list mounted with
// every map. Three things are easy to conflate here and the tab keeps them
// apart, because the 2012 panel did not:
//
//   * installed is not loaded. `installmod` downloads a mod; nothing mounts it
//     until the cycle names it and the map changes.
//   * a cycle edit is not a load either. It takes effect at the next map
//     change, and `active` (the mod's Lua) is what is mounted now.
//   * the cycle is not all that is mounted. The engine mounts two hotfix mods
//     with no cycle entry, and a map's own mods only with that map.
//
// The table is in mount order as far as it is known: the engine's two first,
// then the cycle's global mods in their order, numbered, then the rest. The
// rig's log shows that order (ModMounter::Mount, 2026-09-28): NSL Badges and
// UWE Hotfix 344, then the cycle's mods as listed, then the map's own.
//
// Measured on the 09-26 rig with Shine and 23 mods (REQUIREMENTS item 3).
// Nothing can uninstall a mod (item 2), so the installed list only grows.
// Finding and downloading mods is the Workshop tab's: this tab makes no
// workshop request at all.
//
// Each mod says whether it is whitelisted, from Steam's list as the server
// last read it, or from the copy the panel ships (ui/whitelist.tsx).

/**
 * Mounted by the engine whatever the cycle says, and before it, in this order:
 * NSL Badges, UWE Hotfix 344.
 */
const ENGINE_MOUNTED = new Set(["acd4ecf3", "d41d68cd"]);

const key = (id: unknown) => String(id).toLowerCase();

const entryName = (e: RawMapCycleEntry): string =>
  typeof e === "string" ? e : String(e.map ?? "");

const entryMods = (e: RawMapCycleEntry): string[] =>
  typeof e === "string" || !Array.isArray(e.mods) ? [] : e.mods.map(key);

/** The decimal workshop id, the one in a Steam URL. Null if not plain hex. */
export function workshopId(hexId: string): string | null {
  if (!/^[0-9a-f]{1,16}$/i.test(hexId)) return null;
  return BigInt(`0x${hexId}`).toString();
}

interface Row {
  mod: InstalledMod;
  id: string;
  /** Place in the mount order, from 1; null for what is not mounted with every map. */
  order: number | null;
  /** A cycle id the server has not installed: listed so it can be removed. */
  missing: boolean;
  global: boolean;
  /** Cycle maps whose entry loads it. */
  withMaps: string[];
  /** Maps on the server that come from it. */
  provides: string[];
  /** Cycle maps that come from it and get it only from the global list. */
  dependents: string[];
  /** The loaded map's own entry names it. */
  withThisMap: boolean;
}

/** After the numbered ones: loaded, then what the cycle names, map mods, the rest. */
function rank(r: Row): number {
  if (r.mod.active) return 0;
  if (r.withMaps.length > 0) return 1;
  if (r.provides.length > 0) return 2;
  return 3;
}

export function Mods(
  { state, initialFilter = "" }: { state: ServerState; initialFilter?: string },
) {
  const hasMod = state.modVersion !== null;
  const store = useMapCycle();
  const mods = useResource(installedMods);
  const maps = useResource(mapList);
  const whitelist = useWhitelist(hasMod);

  useEffect(() => {
    void loadMapCycle();
    void mapList.refresh();
  }, []);

  // What is mounted changes only at a map change, so read it again then.
  useEffect(() => { void installedMods.refresh(); }, [state.map]);

  return (
    <section class="wrap mods-tab">
      {!hasMod && (
        <div class="banner">
          <h2>Stock server Lua</h2>
          <p>
            A stock server does not say which mods are loaded, so this list is
            what is installed, nothing more. A cycle change is reported as the
            server's copy; the mod reads MapCycle.json back.
          </p>
        </div>
      )}
      <CycleBanners cycle={store} />
      <ModsView
        state={state}
        hasMod={hasMod}
        cycle={store.shown}
        store={store}
        mods={mods.data}
        modsError={mods.error?.message ?? null}
        maps={maps.data}
        whitelist={whitelist}
        initialFilter={initialFilter}
      />
    </section>
  );
}

interface ViewProps {
  state: ServerState;
  hasMod: boolean;
  cycle: RawMapCycle | null;
  store: ReturnType<typeof useMapCycle>;
  mods: InstalledMod[] | null;
  modsError: string | null;
  maps: MapInfo[] | null;
  whitelist: Whitelist;
  initialFilter: string;
}

function ModsView(p: ViewProps) {
  const { state, hasMod, cycle, store } = p;
  const locked = !cycle || store.conflict !== null;
  const [filter, setFilter] = useState(p.initialFilter);

  const globalIds = (cycle?.mods ?? []).map(key);
  const globalSet = new Set(globalIds);

  const rows = useMemo((): Row[] => {
    const entries = cycle?.maps ?? [];
    const cycleNames = new Set(entries.map(entryName));
    const make = (mod: InstalledMod, missing: boolean): Row => {
      const id = key(mod.id);
      const withMaps = entries.filter((e) => entryMods(e).includes(id)).map(entryName);
      const provides = (p.maps ?? []).filter((m) => m.modId && key(m.modId) === id)
        .map((m) => m.name);
      const dependents = provides.filter((name) => cycleNames.has(name)
        && !entries.some((e) => entryName(e) === name && entryMods(e).includes(id)));
      return {
        mod, id, order: null, missing,
        global: globalSet.has(id),
        withMaps, provides, dependents,
        withThisMap: withMaps.includes(state.map),
      };
    };
    if (!p.mods) return [];
    const byId = new Map(p.mods.map((m) => [key(m.id), make(m, false)]));

    // Mount order: the engine's own, then the cycle's global list as it is.
    const ordered: Row[] = [];
    const place = (r: Row) => { r.order = ordered.length + 1; ordered.push(r); };
    for (const id of ENGINE_MOUNTED) {
      const r = byId.get(id);
      if (r) { place(r); byId.delete(id); }
    }
    for (const id of globalIds) {
      const r = byId.get(id);
      if (r) { place(r); byId.delete(id); continue; }
      // Listed twice, or engine-mounted anyway: already placed.
      if (ordered.some((o) => o.id === id)) continue;
      place(make({ id, name: id, active: null }, true));
    }
    const rest = [...byId.values()].sort((a, b) => rank(a) - rank(b)
      || a.mod.name.localeCompare(b.mod.name, undefined, { sensitivity: "base" }));
    return [...ordered, ...rest];
  }, [p.mods, p.maps, cycle, state.map]);

  const shown = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    if (!needle) return rows;
    return rows.filter((r) => r.mod.name.toLowerCase().includes(needle)
      || r.id.includes(needle) || (workshopId(r.id) ?? "").includes(needle));
  }, [rows, filter]);

  const installedCount = rows.filter((r) => !r.missing).length;
  const loaded = rows.filter((r) => r.mod.active).length;

  const commit = (label: string, edit: (mods: string[]) => string[]) =>
    commitMapCycle((c) => ({ ...c, mods: edit(c.mods ?? []) }), label, hasMod);

  // Appends: the order is the mount order, and the rest of it stays as it is.
  const addGlobal = (r: Row) =>
    commit(`load ${r.mod.name} with every map`, (list) => [...list, r.mod.id]);

  const removeGlobal = (id: string, name: string, dependents: string[] = []) => {
    if (dependents.length > 0 && !confirm(
      `${dependents.join(", ")} ${dependents.length === 1 ? "gets" : "get"} ${name} only `
      + "from this list. Without it, changing to "
      + `${dependents.length === 1 ? "that map" : "those maps"} fails. Stop loading it anyway?`)) {
      return;
    }
    commit(`stop loading ${name} with every map`,
      (list) => list.filter((m) => key(m) !== id));
  };

  return (
    <>
      <div class="form-card cycle-settings">
        <div class="form-row">
          <span class="mod-counts">
            {p.mods ? (
              <>
                <b>{installedCount}</b> installed
                {hasMod && <>, <b>{loaded}</b> loaded now</>}
                , <b>{globalIds.length}</b> with every map
              </>
            ) : p.modsError ? <span class="tone-error">{p.modsError}</span> : "Loading..."}
          </span>
          <span class="spacer" />
          <UndoReload cycle={store} hasMod={hasMod} />
        </div>
        {/* How a write went stays by Undo; the standing notes are below the table. */}
        {(store.saving || store.last) && <CycleNote cycle={store} idle="" />}
      </div>

      <div class="toolbar">
        <input type="search" placeholder="Filter by name or id" value={filter}
               onInput={(e) => setFilter((e.target as HTMLInputElement).value)} />
      </div>
      <div class={`table-wrap${store.conflict ? " read-only" : ""}`}>
        <table class="mods-table">
          <thead>
            <tr>
              <th class="static num" title={"Mount order: the server's own two mods, then "
                + "the cycle's, as listed. A map's own mods mount after these, with the map."}>
                #
              </th>
              <th class="static">Mod</th>
              <th class="static">Id</th>
              <th class="static">Workshop</th>
              <th class="static">Status</th>
              <th class="static">Actions</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => (
              <ModRow key={r.id} r={r} hasMod={hasMod} locked={locked} whitelist={p.whitelist}
                      onAdd={() => addGlobal(r)}
                      onRemove={() => removeGlobal(r.id, r.mod.name, r.dependents)} />
            ))}
            {p.mods && shown.length === 0 && (
              <tr><td colSpan={6} class="muted">
                {rows.length === 0 ? "No mods installed." : "No mod matches the filter."}
              </td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div class="mods-notes">
        <p class="muted form-hint">
          Changes require a map change. Mods are listed in loading order.
        </p>
        <WhitelistSource list={p.whitelist} hasMod={hasMod} />
      </div>
    </>
  );
}

interface RowProps {
  r: Row;
  hasMod: boolean;
  locked: boolean;
  whitelist: Whitelist;
  onAdd: () => void;
  onRemove: () => void;
}

function ModRow({ r, hasMod, locked, whitelist, onAdd, onRemove }: RowProps) {
  const ws = workshopId(r.id);
  if (r.missing) return <MissingRow r={r} ws={ws} locked={locked} onRemove={onRemove} />;
  const engine = ENGINE_MOUNTED.has(r.id);
  const active = r.mod.active;

  // What differs between now and after the next map change.
  let pending: { icon: LucideIcon; label: string; tone: "warn" | "dim" } | null = null;
  if (hasMod && active !== null) {
    if (engine && active) {
      pending = { icon: Server, label: "Mounted by the server itself, not by the cycle.",
                  tone: "dim" };
    } else if (r.global && !active) {
      pending = { icon: ClockArrowUp, label: "Not loaded yet: loads at the next map change.",
                  tone: "warn" };
    } else if (active && !r.global && !r.withThisMap) {
      pending = { icon: ClockArrowDown,
                  label: "The cycle no longer names it: unloads at the next map change.",
                  tone: "warn" };
    }
  }

  const uses: { text: string; title?: string | undefined }[] = [];
  if (r.withMaps.length > 0) {
    uses.push(r.withMaps.length === 1 ? { text: `with ${r.withMaps[0]}` }
      : { text: `with ${r.withMaps.length} maps`, title: r.withMaps.join(", ") });
  }
  if (r.provides.length > 0) {
    uses.push(r.provides.length <= 3 ? { text: `provides ${r.provides.join(", ")}` }
      : { text: `provides ${r.provides.slice(0, 2).join(", ")} and ${r.provides.length - 2} more`,
          title: r.provides.join(", ") });
  }
  const nothing = active !== true && !r.global && uses.length === 0 && !pending;

  return (
    <tr data-mod={r.id} data-active={active === null ? "" : String(active)}
        data-order={r.order ?? ""}>
      <td class="num muted">{r.order ?? ""}</td>
      <td class="name-cell">{r.mod.name}</td>
      <td><span class="mono selectable" title="Click to select">{r.mod.id}</span></td>
      <td>
        {ws ? (
          <a class="mono" href={`https://steamcommunity.com/sharedfiles/filedetails/?id=${ws}`}
             target="_blank" rel="noreferrer noopener"
             title="Open the workshop page (leaves this panel)">{ws}</a>
        ) : <span class="muted">--</span>}
      </td>
      <td class="status-cell">
        <span class="icon-row">
          <WhitelistIcon list={whitelist} hexId={r.id} />
          {active === true && <StatusIcon icon={CircleCheck} label="loaded now" tone="ok" />}
          {r.global && <StatusIcon icon={Globe} label="every map"
                                   title="The cycle loads it with every map" />}
          {pending && <StatusIcon icon={pending.icon} label={pending.label} tone={pending.tone} />}
          {uses.map((u) => (
            <span key={u.text} class="tag" title={u.title}>{u.text}</span>
          ))}
          {nothing && (
            <span class="muted">{active === null ? "not in the cycle" : "not used"}</span>
          )}
        </span>
      </td>
      <td>
        <div class="actions">
          {r.global ? (
            <IconButton icon={CircleMinus} label="Stop loading with every map" danger
                        disabled={locked} onClick={onRemove} />
          ) : engine ? (
            <StatusIcon icon={Server} label="The server mounts it anyway." />
          ) : r.provides.length > 0 ? (
            <StatusIcon icon={MapIcon} label="A map mod: the Maps tab loads it with its maps." />
          ) : (
            <IconButton icon={CirclePlus} label="Load with every map"
                        disabled={locked} onClick={onAdd} />
          )}
        </div>
      </td>
    </tr>
  );
}

/** A cycle id the server has not installed: it cannot be mounted, only removed. */
function MissingRow({ r, ws, locked, onRemove }: {
  r: Row; ws: string | null; locked: boolean; onRemove: () => void;
}) {
  return (
    <tr data-mod={r.id} data-active="" data-missing="true" data-order={r.order ?? ""}>
      <td class="num muted">{r.order}</td>
      <td class="name-cell"><span class="muted">not installed</span></td>
      <td><span class="mono selectable" title="Click to select">{r.mod.id}</span></td>
      <td>
        {ws ? (
          <a class="mono" href={`https://steamcommunity.com/sharedfiles/filedetails/?id=${ws}`}
             target="_blank" rel="noreferrer noopener"
             title="Open the workshop page (leaves this panel)">{ws}</a>
        ) : <span class="muted">--</span>}
      </td>
      <td class="status-cell">
        <StatusIcon icon={TriangleAlert} label="not installed" tone="danger"
                    title="The cycle names it, but the server cannot mount it" />
      </td>
      <td>
        <div class="actions">
          <IconButton icon={CircleMinus} label="Remove" danger disabled={locked}
                      onClick={onRemove} />
        </div>
      </td>
    </tr>
  );
}

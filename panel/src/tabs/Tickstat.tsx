import type { EngineEvent, PerfConfig, Tickstat } from "../api/types";
import { useState } from "preact/hooks";
import { setTickstat, usePerf } from "../store/perf";
import type { EngineStatus, PerfSegment, TickstatOutcome } from "../store/perf";
import { clock } from "../ui/format";
import { PerfChart } from "../ui/PerfChart";
import type { ChartMarker, ChartSeries } from "../ui/PerfChart";

/**
 * The engine's own reports: `tickstat` windows (tick spacing, snapshot sizes,
 * choke) from Server.GetTickStat(), and from the server's log, players' rate
 * steps, the bwlimit warning and the `perfmon:` block (docs/REQUIREMENTS.md
 * item 10). Since 2026-10-07 they are not a section of their own:
 * the charts join the tab's grid, the latest window its summary, and the
 * switch leads the summary strip. The table view, with rate steps and perfmon blocks,
 * went in the Performance review (2026-10-08).
 *
 * A tickstat window carries the time it closed. Log lines carry none: each is
 * placed at the scan that found it, every couple of seconds.
 */
/** How often the switch asks tickstat to log: the getperf window length. */
export const kTickstatSeconds = 10;

export type Logging = "on" | "starting" | "off" | "quiet" | "none";

/** Whether tickstat is running, from its windows and what the server has said. */
export function loggingState(e: EngineStatus, latest: Tickstat | null): Logging {
  const win = latest?.window ?? kTickstatSeconds;
  const said = e.tickstatSaid;
  const last = e.tickstatLastAt;
  if (said?.text === "off" && (last === null || said.at >= last)) return "off";
  if (last !== null && e.now - last <= (3 * win + e.scanSeconds) * 1000) return "on";
  if (said?.text === "on" && (last === null || said.at >= last)) {
    return e.now - said.at <= (3 * kTickstatSeconds + e.scanSeconds) * 1000 ? "starting" : "quiet";
  }
  return last !== null ? "quiet" : "none";
}

export const isRunning = (l: Logging) => l === "on" || l === "starting";

/** The largest snapshot bwlimit allows at this sendrate, in bytes; null if unknown. */
function budget(config: PerfConfig | null): number | null {
  if (!config?.bw_limit || !config.sendrate) return null;
  return Math.floor(config.bw_limit / config.sendrate);
}

/** The engine's records, across every map this page has seen. */
export function engineRecords(segments: PerfSegment[]) {
  const tickstats = segments.flatMap((s) => s.tickstats);
  return {
    tickstats,
    events: segments.flatMap((s) => s.events),
    latest: tickstats[tickstats.length - 1] ?? null,
  };
}

/**
 * tickstat on or off, with where it stands. Not a setting this browser keeps:
 * it is the server's, so it shows what the server last said (another admin
 * may have changed it) and a change applies to every admin. Off after every
 * restart; the panel never turns it on by itself.
 */
export function TickstatSwitch() {
  const perf = usePerf();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState<TickstatOutcome | null>(null);
  const engine = perf.engine;
  if (engine === null) return null;
  const logging = loggingState(engine, engineRecords(perf.segments).latest);

  const toggle = async (on: boolean) => {
    if (!on && !confirm("Stop tickstat? It stops for every admin of this server.")) return;
    setBusy(true);
    setOutcome(null);
    try {
      setOutcome(await setTickstat(on ? kTickstatSeconds : 0));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="perf-stat tickstat-switch" data-tickstat-state={logging}>
      <label class="check" title={`Log tickstat every ${kTickstatSeconds} s: the server's setting, for every admin`}>
        <input type="checkbox" name="tickstat" checked={isRunning(logging)} disabled={busy}
               onChange={(e) => void toggle((e.target as HTMLInputElement).checked)} />
        <span class="label">tickstat</span>
      </label>
      {outcome && (
        <span class={outcome.kind === "confirmed" ? "sr-only" : "tone-warn"}
              data-tickstat-outcome={outcome.kind}>
          {" "}{outcome.note}
        </span>
      )}
    </div>
  );
}

/** The engine's warning, while bwlimit is still the value it warned about. */
export function BwlimitWarning({ events, config }: { events: EngineEvent[]; config: PerfConfig | null }) {
  const warning = [...events].reverse().find((e) => e.kind === "bwlimit_low");
  if (!warning || warning.kind !== "bwlimit_low") return null;
  if (config?.bw_limit !== undefined && config.bw_limit !== warning.bwlimit) return null;
  return (
    <div class="banner banner-error" data-bwlimit-warning={warning.bwlimit}>
      <h2>bwlimit {warning.bwlimit} is too small for a full game</h2>
      <p>
        At sendrate {warning.sendrate} it leaves {warning.per_snapshot} bytes per
        update, below the {warning.needed} the engine says a full game needs, so
        updates will be held back and arrive late. The engine suggests
        bwlimit {warning.suggested} or more (warned at {clock(warning.at)}).
      </p>
    </div>
  );
}

/**
 * What a snapshot p99 over bwlimit needs: p99 x sendrate, the engine's own
 * rule for sizing bwlimit -- or, when its warning has named one, its floor
 * for a full game, if higher. Measured on the rig: p99 832 B at sendrate 40
 * asks for 33280 while the engine's warning asks for 81920; offering the
 * lower one would be wrong.
 */
function snapshotFit(t: Tickstat, config: PerfConfig | null, events: EngineEvent[]) {
  const limit = budget(config);
  const p99 = t.snapBytesP99;
  const over = limit !== null && p99 !== undefined && p99 > limit;
  const p99Need = over && config ? Math.ceil(p99! * config.sendrate) : null;
  const warned = [...events].reverse().find((e) => e.kind === "bwlimit_low");
  const floor = warned && warned.kind === "bwlimit_low" && config
    ? { perUpdate: warned.needed, total: warned.needed * config.sendrate } : null;
  const need = p99Need === null ? null
    : floor && floor.total > p99Need ? floor.total : p99Need;
  return { limit, p99, over, p99Need, floor, need };
}

/** The latest tickstat line's stats, for the tab's summary; only those it carries. */
export function TickstatStats({ t, config, events, players }: {
  t: Tickstat; config: PerfConfig | null; events: EngineEvent[];
  /** Whether to show its player count: the summary's window has its own. */
  players: boolean;
}) {
  const { limit, p99, over } = snapshotFit(t, config, events);
  const slow = t.hz !== undefined && t.target !== undefined && t.hz < t.target * 0.98;
  const choked = t.chokedPct;
  return (
    <>
      {t.hz !== undefined && (
        <div class="perf-stat">
          <span class="label">delivered</span>
          <b class={slow ? "tone-warn" : ""}>{t.hz.toFixed(2)}</b>
          <span class="muted">{t.target !== undefined ? ` / ${t.target}` : ""} Hz</span>
        </div>
      )}
      {t.intervalP99 !== undefined && (
        <div class="perf-stat">
          <span class="label">tick spacing p99</span>
          <b>{t.intervalP99.toFixed(1)} ms</b>
          {t.target ? <span class="muted"> ({(1000 / t.target).toFixed(1)} on time)</span> : null}
        </div>
      )}
      {p99 !== undefined && (
        <div class="perf-stat" data-snap-over={over ? "1" : "0"}>
          <span class="label">snapshot p99</span>
          <b class={over ? "tone-error" : ""}>{p99} B</b>
          {limit !== null && <span class="muted"> / {limit} B bwlimit allows</span>}
        </div>
      )}
      {choked !== undefined && (
        <div class="perf-stat" data-choked={choked}>
          <span class="label">choked</span>
          <b class={choked > 0 ? "tone-warn" : ""}>{choked.toFixed(2)}%</b>
        </div>
      )}
      {t.busyPct !== undefined && (
        <div class="perf-stat">
          <span class="label">busy</span>
          <b>{t.busyPct.toFixed(0)}%</b>
        </div>
      )}
      {players && t.humans !== undefined && (
        <div class="perf-stat">
          <span class="label">players</span>
          <b>{t.humans}</b>
          {t.bots ? <span class="muted"> + {t.bots} bots</span> : null}
        </div>
      )}
    </>
  );
}

/** What the latest line asks of an admin, as full-width notes under the stats. */
export function TickstatNotes({ t, config, events }: {
  t: Tickstat; config: PerfConfig | null; events: EngineEvent[];
}) {
  const { p99, over, p99Need, floor, need } = snapshotFit(t, config, events);
  return (
    <>
      {over && need !== null && (
        <p class="tone-error strip-note" data-bwlimit-fix={need}>
          Snapshots are larger than bwlimit {config!.bw_limit} allows at sendrate
          {" "}{config!.sendrate}: set bwlimit to at least {need}
          {need === p99Need
            ? ` (p99 ${p99} B x sendrate ${config!.sendrate}).`
            : ` (the ${floor!.perUpdate} B per update the engine says a full game needs, `
              + `x sendrate ${config!.sendrate}; p99 alone, ${p99} B, would ask for ${p99Need}).`}
        </p>
      )}
      {(t.rateStepped ?? 0) > 0 && (
        <p class="tone-warn strip-note">
          {t.rateStepped} player{t.rateStepped === 1 ? "" : "s"} had their update rate
          lowered to fit bwlimit
          {t.slowestSendrate !== undefined ? `, to ${t.slowestSendrate.toFixed(1)}/s at the slowest.` : "."}
        </p>
      )}
      {(t.sendBufDrops ?? 0) > 0 && (
        <p class="tone-error strip-note">
          {t.sendBufDrops} packet{t.sendBufDrops === 1 ? "" : "s"} dropped: the server's send buffer was full.
        </p>
      )}
      {(t.creationsDeferred ?? 0) > 0 && (
        <p class="muted strip-note">
          {t.creationsDeferred} new object{t.creationsDeferred === 1 ? "" : "s"} held back
          to a later update to stay within bwlimit.
        </p>
      )}
    </>
  );
}

interface Row { x: number; t: Tickstat | null }

/** Records in time order, with a break where the lines stop: a map change or a pause. */
function withGaps(segments: PerfSegment[]): Row[] {
  const rows: Row[] = [];
  let prev: Tickstat | null = null;
  for (const segment of segments) {
    for (const t of segment.tickstats) {
      const win = (t.window ?? kTickstatSeconds) * 1000;
      if (prev && (t.at - prev.at > win * 2 + 5000 || t === segment.tickstats[0])) {
        rows.push({ x: (prev.at + t.at) / 2000, t: null });
      }
      rows.push({ x: t.at / 1000, t });
      prev = t;
    }
  }
  return rows;
}

export interface TickstatChartsProps {
  segments: PerfSegment[];
  config: PerfConfig | null;
  markers: ChartMarker[];
  /** The time range every chart shows: the zoom, or all there is. */
  range: [number, number] | null;
  onZoom: (range: [number, number]) => void;
  theme: string;
  clock: string;
}

/** The engine's charts, as cells of the tab's grid. */
export function TickstatCharts(props: TickstatChartsProps & { tickstats: Tickstat[] }) {
  const rows = withGaps(props.segments);
  const x = rows.map((r) => r.x);
  const pick = (f: (t: Tickstat) => number | undefined) =>
    rows.map((r) => r.t ? f(r.t) ?? null : null);
  const common = { x, markers: props.markers, zoom: props.range, onZoom: props.onZoom,
                   theme: props.theme, clock: props.clock };
  const config = props.config;
  const latest = props.tickstats[props.tickstats.length - 1]!;
  const target = latest.target ?? config?.tickrate ?? 0;
  const onTime = target > 0 ? 1000 / target : null;
  const limit = budget(config);
  const most = (vs: (number | null)[]) => Math.max(0, ...vs.filter((v): v is number => v !== null));
  const ms = (v: number) => `${v.toFixed(v >= 100 ? 0 : 1)} ms`;
  const series = (list: [string, (t: Tickstat) => number | undefined, boolean?][]): ChartSeries[] =>
    list.map(([label, f, stepped], i) => ({ label, slot: (i + 1) as 1 | 2 | 3,
                                            values: pick(f), stepped }));

  const spacing = series([["p50", (t) => t.intervalP50], ["p99", (t) => t.intervalP99],
                          ["max", (t) => t.intervalMax]]);
  const sizes = series([["p50", (t) => t.snapBytesP50], ["p99", (t) => t.snapBytesP99],
                        ["max", (t) => t.snapBytesMax]]);
  const perSecond = series([["snapshots", (t) => t.snapPerSecPerHuman],
                            ["moves", (t) => t.movesPerSecPerHuman]]);

  return (
    <>
      <PerfChart {...common} title="Tick spacing (ms between ticks)" series={spacing}
        format={ms} axisFormat={(v) => v.toFixed(0)}
        yRange={() => [0, Math.max((onTime ?? 0) * 2.5, most(spacing[1]!.values) * 1.2, 1)]}
        refLines={onTime ? [{ value: onTime, label: `on time ${onTime.toFixed(1)}` }] : []} />
      <PerfChart {...common} title="Snapshot size (bytes per update to a player)" series={sizes}
        format={(v) => `${v.toFixed(0)} B`} axisFormat={(v) => v.toFixed(0)}
        yRange={(_min, max) => [0, Math.max((limit ?? 0) * 1.15, max * 1.1, 100)]}
        refLines={limit !== null ? [{ value: limit, label: `bwlimit allows ${limit}` }] : []} />
      <PerfChart {...common} title="Updates held back by bwlimit (%)"
        series={series([["choked", (t) => t.chokedPct]])}
        format={(v) => `${v.toFixed(2)}%`} axisFormat={(v) => v.toFixed(0)}
        yRange={(_min, max) => [0, Math.max(5, max * 1.2)]} />
      <PerfChart {...common} title="Throttling (per line)"
        series={series([["rate lowered", (t) => t.rateStepped, true],
                         ["buffer drops", (t) => t.sendBufDrops, true],
                         ["creations held", (t) => t.creationsDeferred, true]])}
        format={(v) => v.toFixed(0)}
        yRange={(_min, max) => [0, Math.max(4, Math.ceil(max * 1.2))]} />
      <PerfChart {...common} title="Server load (%)"
        series={series([["busy", (t) => t.busyPct], ["ticks stretched", (t) => t.stretchPct]])}
        format={(v) => `${v.toFixed(1)}%`} axisFormat={(v) => v.toFixed(0)}
        yRange={() => [0, 100]} />
      <PerfChart {...common} title="Per human player, per second" series={perSecond}
        format={(v) => v.toFixed(1)} axisFormat={(v) => v.toFixed(0)}
        yRange={(_min, max) => [0, Math.max((config?.sendrate ?? 0), (config?.moverate ?? 0), max, 1) * 1.2]}
        refLines={config ? [{ value: config.sendrate, label: `sendrate ${config.sendrate}` },
                            ...(config.moverate !== config.sendrate
                              ? [{ value: config.moverate, label: `moverate ${config.moverate}` }] : [])]
          : []} />
      <PerfChart {...common} title="Move cost (ms per tick)"
        series={series([["humans", (t) => t.humanMoveMsPerTick], ["all", (t) => t.moveMsPerTick],
                         ["spectators", (t) => t.specMoveMsPerTick]])}
        format={(v) => `${v.toFixed(3)} ms`} axisFormat={(v) => v.toFixed(2)} />
    </>
  );
}

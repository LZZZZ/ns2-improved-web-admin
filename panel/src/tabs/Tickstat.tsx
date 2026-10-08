import type { EngineEvent, PerfConfig, Tickstat } from "../api/types";
import type { EngineStatus, PerfSegment } from "../store/perf";
import { clock, span } from "../ui/format";
import { PerfChart } from "../ui/PerfChart";
import type { ChartMarker, ChartSeries } from "../ui/PerfChart";

/**
 * The engine's own reports, from the server's log: `tickstat` lines (tick
 * spacing, snapshot sizes, choke), players' rate steps, the bwlimit warning,
 * and the `perfmon:` block (docs/REQUIREMENTS.md item 10). Mod only. Since
 * 2026-10-07 they are not a section of their own: the charts join the
 * tab's grid, the latest line its summary, and the switch is in Settings.
 * The table view, with rate steps and perfmon blocks, went in the
 * Performance review (2026-10-08).
 *
 * The lines carry no time of their own: each is placed at the scan that found
 * it, every couple of seconds, so a point can sit up to that much late.
 */
/** How often the Settings switch asks tickstat to log: the getperf window length. */
export const kTickstatSeconds = 10;

export type Logging = "on" | "starting" | "off" | "quiet" | "none";

/** Whether tickstat is running, from what the server's log has said. */
export function loggingState(e: EngineStatus, latest: Tickstat | null): Logging {
  const win = latest?.win_s ?? kTickstatSeconds;
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
 * Where tickstat stands, in one line: the switch is in
 * Settings, because it is the server's, not this page's. Also what a server
 * without a readable log, or an older mod, cannot show. Mod only.
 */
export function EngineStatusLine({ engine, segments, onOpenSettings }: {
  engine: EngineStatus | null;
  segments: PerfSegment[];
  onOpenSettings: () => void;
}) {
  if (engine === null) {
    return (
      <p class="perf-engine muted" data-engine="absent">
        This server's mod predates reading the engine's log: update it for
        tickstat, rate steps and perfmon blocks.
      </p>
    );
  }
  if (engine.source === "none") {
    return (
      <p class="perf-engine muted" data-engine="none" data-engine-error>
        {engine.stale
          ? `${engine.path} is not the log this server is writing (${engine.error ?? "stale"}), `
          : `The server's log is not readable here (${engine.error ?? engine.path}), `}
        so tickstat, players' rate steps and perfmon blocks cannot be shown:
        the engine writes them only to that log. The mod reads it when the
        server logs into its config directory, as a default install does.
      </p>
    );
  }
  const { latest } = engineRecords(segments);
  const logging = loggingState(engine, latest);
  // Logging, the charts and the summary say so; Settings has the rest.
  if (logging === "on") return null;
  return (
    <p class="perf-engine tickstat-status" data-engine="log" data-tickstat-state={logging}>
      {statusText(logging, engine, latest)}{" "}
      <button class="link-button" onClick={onOpenSettings}>
        {isRunning(logging) ? "Settings turns it off." : "Settings turns it on."}
      </button>
    </p>
  );
}

export function statusText(logging: Logging, e: EngineStatus, latest: Tickstat | null): string {
  const win = latest?.win_s ?? kTickstatSeconds;
  switch (logging) {
    case "on":
      return `tickstat is logging every ${win} s, for every admin. It stays on through map changes; a restart turns it off.`;
    case "starting":
      return `tickstat was turned on at ${clock(e.tickstatSaid!.at)}; its first line is due within its interval.`;
    case "off":
      return `tickstat is off: the server said so at ${clock(e.tickstatSaid!.at)}.`;
    case "quiet":
      return `No tickstat line for ${span((e.now - (e.tickstatLastAt ?? e.tickstatSaid!.at)) / 1000)}: `
        + "it was probably turned off, or the server restarted.";
    case "none":
      return "No tickstat line since the map loaded: tickstat is off after every restart. "
        + "On, it adds tick spacing, snapshot size and choke to the charts.";
  }
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
  const p99 = t.snap_p99_bytes;
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
  const choked = t.choked_pct;
  return (
    <>
      {t.hz !== undefined && (
        <div class="perf-stat">
          <span class="label">delivered</span>
          <b class={slow ? "tone-warn" : ""}>{t.hz.toFixed(2)}</b>
          <span class="muted">{t.target !== undefined ? ` / ${t.target}` : ""} Hz</span>
        </div>
      )}
      {t.int_p99_ms !== undefined && (
        <div class="perf-stat">
          <span class="label">tick spacing p99</span>
          <b>{t.int_p99_ms.toFixed(1)} ms</b>
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
      {t.busy_pct !== undefined && (
        <div class="perf-stat">
          <span class="label">busy</span>
          <b>{t.busy_pct.toFixed(0)}%</b>
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
      {(t.rate_stepped ?? 0) > 0 && (
        <p class="tone-warn strip-note">
          {t.rate_stepped} player{t.rate_stepped === 1 ? "" : "s"} had their update rate
          lowered to fit bwlimit
          {t.slowest_rate !== undefined ? `, to ${t.slowest_rate.toFixed(1)}/s at the slowest.` : "."}
        </p>
      )}
      {(t.sendbuf_drops ?? 0) > 0 && (
        <p class="tone-error strip-note">
          {t.sendbuf_drops} packet{t.sendbuf_drops === 1 ? "" : "s"} dropped: the server's send buffer was full.
        </p>
      )}
      {(t.creations_deferred ?? 0) > 0 && (
        <p class="muted strip-note">
          {t.creations_deferred} new object{t.creations_deferred === 1 ? "" : "s"} held back
          to a later update to stay within bwlimit.
        </p>
      )}
      {t.unparsed > 0 && (
        <p class="muted strip-note">
          {t.unparsed} part{t.unparsed === 1 ? "" : "s"} of the line this panel does not know: a newer engine.
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
      const win = (t.win_s ?? kTickstatSeconds) * 1000;
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

  const spacing = series([["p50", (t) => t.int_p50_ms], ["p99", (t) => t.int_p99_ms],
                          ["max", (t) => t.int_max_ms]]);
  const sizes = series([["p50", (t) => t.snap_p50_bytes], ["p99", (t) => t.snap_p99_bytes],
                        ["max", (t) => t.snap_max_bytes]]);
  const perSecond = series([["snapshots", (t) => t.snaps_per_s_human],
                            ["moves", (t) => t.moves_per_s_human]]);

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
        series={series([["choked", (t) => t.choked_pct]])}
        format={(v) => `${v.toFixed(2)}%`} axisFormat={(v) => v.toFixed(0)}
        yRange={(_min, max) => [0, Math.max(5, max * 1.2)]} />
      <PerfChart {...common} title="Throttling (per line)"
        series={series([["rate lowered", (t) => t.rate_stepped, true],
                         ["send buffer drops", (t) => t.sendbuf_drops, true],
                         ["creations held back", (t) => t.creations_deferred, true]])}
        format={(v) => v.toFixed(0)}
        yRange={(_min, max) => [0, Math.max(4, Math.ceil(max * 1.2))]} />
      <PerfChart {...common} title="Server load (%)"
        series={series([["busy", (t) => t.busy_pct], ["ticks stretched", (t) => t.stretch_pct]])}
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
        series={series([["humans", (t) => t.human_move_ms_tick], ["all", (t) => t.move_ms_tick],
                         ["spectators", (t) => t.spec_move_ms_tick]])}
        format={(v) => `${v.toFixed(3)} ms`} axisFormat={(v) => v.toFixed(2)} />
    </>
  );
}

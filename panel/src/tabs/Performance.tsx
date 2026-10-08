import { useState } from "preact/hooks";
import type { EngineEvent, PerfConfig, PerfPoint, ServerState, Tickstat } from "../api/types";
import { refreshPerf, usePerf } from "../store/perf";
import type { PerfSegment } from "../store/perf";
import { useResolvedTheme, useSettings } from "../store/settings";
import { clock } from "../ui/format";
import { PerfChart } from "../ui/PerfChart";
import type { ChartMarker, ChartSeries } from "../ui/PerfChart";
import {
  BwlimitWarning, EngineStatusLine, TickstatCharts, TickstatNotes, TickstatStats, engineRecords,
} from "./Tickstat";

/**
 * What perfmon logs, drawn.
 *
 * On the mod: 10 s windows of the engine's own ServerPerformanceData, with the
 * tickrate counted per tick and the slowest tick, since the map loaded -- and
 * whatever this page has already read from earlier maps. On a stock server:
 * the vanilla getperfdata, three numbers a minute, as the server holds them.
 */
export function Performance({ state, onOpenSettings }: {
  state: ServerState;
  onOpenSettings: () => void;
}) {
  const hasMod = state.modVersion !== null;
  const perf = usePerf(hasMod);
  const settings = useSettings();
  const theme = useResolvedTheme();
  const [zoom, setZoom] = useState<[number, number] | null>(null);

  const windowS = perf.windowSeconds ?? (hasMod ? 10 : 60);
  const rows = withGaps(perf.segments, windowS);
  const x = rows.map((r) => r.x);
  const pick = (f: (p: PerfPoint) => number | null) => rows.map((r) => r.p ? f(r.p) : null);
  const markers: ChartMarker[] = perf.segments
    .filter((s) => s.loadedAt !== null)
    .map((s) => ({ at: s.loadedAt! / 1000, label: s.map ?? "map load" }));
  const current = perf.segments[perf.segments.length - 1];
  const latest = current?.points[current.points.length - 1] ?? null;
  const config = perf.config;
  // One time range for every chart, the windows' and the engine lines' alike,
  // so they line up and a lone point does not collapse its axis. A zoom
  // replaces it.
  const tickAt = perf.segments.flatMap((s) => s.tickstats.map((t) => t.at / 1000));
  const ends = [x[0], x[x.length - 1], tickAt[0], tickAt[tickAt.length - 1]]
    .filter((v): v is number => v !== undefined);
  const range: [number, number] | null = zoom ?? (ends.length === 0 ? null
    : Math.max(...ends) > Math.min(...ends) ? [Math.min(...ends), Math.max(...ends)]
    : [ends[0]! - 30, ends[0]! + 30]);
  const common = { x, markers, zoom: range, onZoom: setZoom, theme, clock: settings.clock };
  const mod = perf.source === "mod";

  // One plot, one axis, numbers without a unit; each line names its own.
  // Fixed slots, whatever the server has: slowest tick dashed, players stepped.
  const hz = (v: number) => `${v.toFixed(1)} Hz`;
  const headline: ChartSeries[] = [
    { label: mod ? "tickrate" : "tickrate (reading)", slot: 1, format: hz,
      values: pick((p) => p.tickrate) },
    ...(mod ? [
      { label: "slowest tick", slot: 2 as const, dash: true, format: hz,
        values: pick((p) => p.worstTickMs ? 1000 / p.worstTickMs : null) },
      { label: "score", slot: 3 as const,
        values: pick((p) => p.players > 0 ? p.score : null) },
    ] : []),
    { label: "players", slot: 4, stepped: true, values: pick((p) => p.players) },
  ];
  const engine = engineRecords(perf.segments);
  const showEngine = mod && perf.engine?.source === "log";

  return (
    <section class="wrap perf-tab">
      {!hasMod && (
        <div class="banner">
          <h2>Stock server: one reading a minute</h2>
          <p>
            The game's own web interface keeps the last 30 readings, a minute
            apart, of the tickrate, players and entities -- half an hour, lost
            at every map change. With this panel's mod the tab shows what
            perfmon logs, every 10 seconds: the performance score, where each
            tick's time goes, late updates to players, the slowest tick, the
            configured rates and the Lua heap -- and, from the engine's own
            log, tickstat's tick spacing, snapshot sizes and choke.
          </p>
        </div>
      )}

      {mod && config && (
        <p class="perf-rates">
          <span>tick <b>{config.tickrate}</b></span>
          <span>move <b>{config.moverate}</b></span>
          <span>send <b>{config.sendrate}</b></span>
          <span>interp <b>{config.interp_ms} ms</b></span>
          <span>max <b>{config.max_players}</b> players</span>
          <span class="muted">as the server runs now</span>
        </p>
      )}

      {showEngine && <BwlimitWarning events={engine.events} config={config} />}
      {(latest || (showEngine && engine.latest)) && (
        <Strip latest={latest} t={showEngine ? engine.latest : null} config={config}
               mod={mod} windowS={windowS} events={engine.events} />
      )}
      {mod && <EngineStatusLine engine={perf.engine} segments={perf.segments}
                                onOpenSettings={onOpenSettings} />}

      <div class="toolbar">
        <span class="spacer" />
        {perf.error && <span class="tone-error">{perf.error.message}</span>}
        {zoom
          ? <button class="btn btn-sm" onClick={() => setZoom(null)}>Reset zoom</button>
          : rows.length > 1 && <span class="muted">drag across a chart to zoom</span>}
        <button class="btn btn-sm" onClick={() => void refreshPerf()}>Refresh</button>
      </div>

      {perf.loading && rows.length === 0 && <p class="muted">Loading performance data...</p>}
      {!perf.loading && rows.length === 0 && !perf.error && (
        <p class="muted">
          {mod
            ? `No window yet: the first closes ${windowS} s after the map loads.`
            : "No reading yet: the first is taken a minute after the map loads."}
        </p>
      )}

      {rows.length > 0 && (
        <div class="perf-grid">
          {/* As settled on the rig (2026-10-07): the four
              lines on one plot. Their values share a range of about 0 to 100,
              so the axis carries numbers only, and the legend the units. */}
          <PerfChart {...common} wide height={220}
            title={mod ? "Tickrate, slowest tick, score and players" : "Tickrate and players"}
            series={headline}
            format={(v) => v.toFixed(0)}
            axisFormat={(v) => v.toFixed(0)}
            yRange={(min, max) => [Math.min(0, min - 5),
              Math.max((config?.tickrate ?? 0) * 1.15, config?.max_players ?? state.maxPlayers ?? 0,
                       max * 1.1, 1)]}
            refLines={config ? [{ value: config.tickrate, label: `tickrate set ${config.tickrate}` }] : []} />
          {mod && (
            <PerfChart {...common} title="Frame time (% of each window)"
              series={[
                { label: "idle", slot: 1, values: pick((p) => p.idlePct) },
                { label: "player moves", slot: 2, values: pick((p) => p.movesPct) },
                { label: "entities", slot: 3, values: pick((p) => p.entitiesPct) },
              ]}
              format={(v) => `${v.toFixed(0)}%`}
              yRange={() => [0, 100]} />
          )}
          {mod && (
            <PerfChart {...common} title="Late updates to players (per window)"
              series={[
                { label: "warn", slot: 1, stepped: true, values: pick((p) => p.interpWarns) },
                { label: "fail", slot: 2, stepped: true, values: pick((p) => p.interpFails) },
              ]}
              format={(v) => v.toFixed(0)}
              yRange={(_min, max) => [0, Math.max(4, Math.ceil(max * 1.2))]} />
          )}
          <PerfChart {...common} title="Entities"
            series={[{ label: "entities", slot: 1, values: pick((p) => p.entities) }]}
            format={(v) => v.toFixed(0)} />
          {mod && (
            <PerfChart {...common} title="Lua heap (MB)"
              series={[{ label: "heap", slot: 1,
                values: pick((p) => p.luaKb === null ? null : p.luaKb / 1024) }]}
              format={(v) => v.toFixed(v >= 10 ? 0 : 1)}
              axisFormat={(v) => v.toFixed(0)} />
          )}
          {showEngine && engine.tickstats.length > 0 && (
            <TickstatCharts segments={perf.segments} config={config} markers={markers}
              range={range} onZoom={setZoom} theme={theme} clock={settings.clock}
              tickstats={engine.tickstats} />
          )}
        </div>
      )}
    </section>
  );
}

// perfmon's colours for a score (ServerPerformanceData.lua, GetScoreColor), and
// the words the server browser uses for them (SERVER_PERF_*).
function scoreLevel(score: number): { word: string; tone: string } {
  if (score >= 10) return { word: "good", tone: "tone-ok" };
  if (score >= 0) return { word: "ok", tone: "tone-warn" };
  if (score >= -10) return { word: "loaded", tone: "tone-serious" };
  return { word: "bad", tone: "tone-error" };
}

/**
 * The latest perfmon window and the latest tickstat line, as one summary:
 * only what the server has given, so a stat with no value is left out.
 */
function Strip({ latest, t, config, mod, windowS, events }: {
  latest: PerfPoint | null; t: Tickstat | null; config: PerfConfig | null;
  mod: boolean; windowS: number; events: EngineEvent[];
}) {
  const level = latest && latest.score !== null && latest.players > 0 ? scoreLevel(latest.score) : null;
  const fails = latest?.interpFails ?? 0;
  const when = [
    latest && (mod ? `the ${windowS} s to ${clock(latest.at)}` : `read at ${clock(latest.at)}`),
    t && (t.win_s !== undefined ? `tickstat's ${t.win_s} s to about ${clock(t.at)}`
                                : `tickstat to about ${clock(t.at)}`),
  ].filter(Boolean).join("; ");
  return (
    <div class="perf-strip" aria-label="Latest window and tickstat line">
      {latest && (
        <div class="perf-stat">
          <span class="label">tickrate</span>
          <b>{latest.tickrate.toFixed(1)}</b>
          {config && <span class="muted"> / {config.tickrate}</span>}
        </div>
      )}
      {mod && latest && latest.worstTickMs !== null && (
        <div class="perf-stat">
          <span class="label">slowest tick</span>
          <b>{latest.worstTickMs.toFixed(1)} ms</b>
        </div>
      )}
      {mod && latest && latest.score !== null && (
        <div class="perf-stat" data-score={level?.word ?? "none"}>
          <span class="label">score</span>
          {level
            ? <b class={level.tone}>{"●"} {latest.score} {level.word}</b>
            : <b class="muted">no players</b>}
        </div>
      )}
      {mod && latest && latest.idlePct !== null && (
        <div class="perf-stat">
          <span class="label">idle</span>
          <b>{latest.idlePct.toFixed(0)}%</b>
        </div>
      )}
      {mod && latest && (latest.interpWarns !== null || latest.interpFails !== null) && (
        <div class="perf-stat" data-interp-fails={fails}>
          <span class="label">late updates</span>
          <b>{latest.interpWarns ?? 0} warn, <span class={fails > 0 ? "tone-error" : ""}>
            {fails} fail</span></b>
          {fails > 0 && (
            <span class="tone-error" title={
              `An update reached a player later than interp (${config?.interp_ms ?? "?"} ms), ` +
              "so they saw a stall. One-offs at joins and map loads are normal; " +
              "steady ones mean interp is too tight or the server is overloaded."}>
              {" ▲ past interp"}
            </span>
          )}
        </div>
      )}
      {t && <TickstatStats t={t} config={config} events={events} players={!latest} />}
      {latest && (
        <div class="perf-stat">
          <span class="label">players</span>
          <b>{latest.players}</b>
          {(config || t?.bots) && (
            <span class="muted">
              {config ? ` / ${config.max_players}` : ""}
              {t?.bots ? `, ${t.bots} bot${t.bots === 1 ? "" : "s"}` : ""}
            </span>
          )}
        </div>
      )}
      {latest && (
        <div class="perf-stat">
          <span class="label">entities</span>
          <b>{latest.entities}</b>
        </div>
      )}
      {mod && latest && latest.luaKb !== null && (
        <div class="perf-stat">
          <span class="label">Lua heap</span>
          <b>{(latest.luaKb / 1024).toFixed(0)} MB</b>
        </div>
      )}
      <div class="perf-stat muted">{when}</div>
      {t && <TickstatNotes t={t} config={config} events={events} />}
    </div>
  );
}

interface Row { x: number; p: PerfPoint | null }

/**
 * Points in time order, with a null row wherever the server's data stops: a
 * map change, or windows it dropped before we read them. uPlot draws the null
 * as a break in the line rather than joining across it.
 */
function withGaps(segments: PerfSegment[], windowS: number): Row[] {
  const rows: Row[] = [];
  let prev: PerfPoint | null = null;
  for (const segment of segments) {
    for (const p of segment.points) {
      if (prev && (p.at - prev.at > windowS * 2000 || p === segment.points[0])) {
        rows.push({ x: (prev.at + p.at) / 2000, p: null });
      }
      rows.push({ x: p.at / 1000, p });
      prev = p;
    }
  }
  return rows;
}

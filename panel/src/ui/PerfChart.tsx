// A thin wrapper over uPlot for the Performance tab.
//
// uPlot draws on a canvas and takes its colours as strings when it is built,
// so the colours come from the stylesheet's custom properties at build time
// and the chart is rebuilt when the theme changes. Everything else -- new
// data, a resize, a zoom -- updates the chart it already has.
//
// All the tab's charts share one cursor (hovering one shows the same moment in
// every other) and one zoom: dragging across any chart selects a time range,
// which the tab hands back to all of them.

import { useEffect, useRef } from "preact/hooks";
import uPlot from "uplot";
import "uplot/dist/uPlot.min.css";
import { axisClock, clock } from "./format";

export interface ChartSeries {
  label: string;
  values: (number | null)[];
  /** 1-4: the categorical slot, in fixed order. */
  slot: 1 | 2 | 3 | 4;
  /** This series' readout, when it differs from the chart's. */
  format?: (v: number) => string;
  dash?: boolean;
  /** Stepped: a count that holds until the next reading. */
  stepped?: boolean;
}

export interface ChartMarker {
  /** Seconds. */
  at: number;
  label: string;
}

export interface ChartRefLine {
  value: number;
  label: string;
}

export interface PerfChartProps {
  title: string;
  /** Seconds, ascending. */
  x: number[];
  series: ChartSeries[];
  format: (v: number) => string;
  /** Axis ticks, when they want fewer digits than the readout. */
  axisFormat?: (v: number) => string;
  /** Fixed y range, or a function of the data's own. */
  yRange?: (min: number, max: number) => [number, number];
  refLines?: ChartRefLine[];
  markers?: ChartMarker[];
  /** The shared zoom, seconds; null for everything. */
  zoom: [number, number] | null;
  onZoom: (range: [number, number]) => void;
  /** Changes when the theme does, to rebuild with the new colours. */
  theme: string;
  /** Changes with the clock setting, to rebuild the time labels. */
  clock: string;
  height?: number;
  /** Wider than a grid cell: the full row (F1). */
  wide?: boolean;
}

const kSyncKey = "perf";

function cssVar(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

export function PerfChart(props: PerfChartProps) {
  const host = useRef<HTMLDivElement>(null);
  const plot = useRef<uPlot | null>(null);
  // The latest props, for hooks registered when the chart was built.
  const latest = useRef(props);
  latest.current = props;
  // The time axis's labels as last drawn, published with the rest below.
  const xTicks = useRef<string[]>([]);

  const data = (): uPlot.AlignedData =>
    [props.x, ...props.series.map((s) => s.values)] as uPlot.AlignedData;

  // Build, and rebuild when the theme or the set of series changes.
  const shape = props.series.map((s) => s.label).join("|");
  useEffect(() => {
    const el = host.current;
    if (!el) return;
    const text = cssVar("--text-dim");
    const grid = cssVar("--chart-grid");
    const axis = cssVar("--chart-axis");
    const series: uPlot.Series[] = [
      { value: (_u, v) => v == null ? "--" : clock(v * 1000) },
      ...props.series.map((s) => ({
        label: s.label,
        stroke: cssVar(`--series-${s.slot}`),
        width: 2,
        dash: s.dash ? [6, 4] : undefined,
        spanGaps: false,
        points: { show: false },
        paths: s.stepped ? uPlot.paths.stepped!({ align: 1 }) : undefined,
        value: (_u: uPlot, v: number | null) => v == null ? "--"
          : (s.format ?? latest.current.format)(v),
      })),
    ];
    const opts: uPlot.Options = {
      width: el.clientWidth || 400,
      height: props.height ?? 170,
      series,
      // Room on the right for the last time label, centred on the plot's edge.
      padding: [null, 36, null, null],
      legend: { show: true, live: true },
      cursor: {
        sync: { key: kSyncKey },
        drag: { x: true, y: false, setScale: false },
        points: { size: 8 },
      },
      scales: {
        x: { time: true },
        y: {
          range: (_u, min, max) => {
            const r = latest.current.yRange;
            if (r) return r(min ?? 0, max ?? 0);
            const hi = Math.max(max ?? 0, 1);
            return [Math.min(0, min ?? 0), hi * 1.1];
          },
        },
      },
      axes: [
        // Time ticks as the rest of the panel writes times; uPlot's own are
        // 12-hour am/pm whatever the locale.
        {
          stroke: text, grid: { stroke: grid, width: 1 }, ticks: { stroke: axis, width: 1 },
          // Room for the longest label, "07:38:50 AM": uPlot's default 50 px
          // packs 10 s ticks so close that they run together.
          space: 90,
          values: (_u, vals, _axis, _space, incr) =>
            (xTicks.current = vals.map((v) => axisClock(v * 1000, incr < 60))),
        },
        {
          stroke: text, size: 54,
          grid: { stroke: grid, width: 1 }, ticks: { stroke: axis, width: 1 },
          values: (_u, vals) => vals.map((v) =>
            (latest.current.axisFormat ?? latest.current.format)(v)),
        },
      ],
      hooks: {
        setSelect: [(u) => {
          if (u.select.width < 4) return;
          const min = u.posToVal(u.select.left, "x");
          const max = u.posToVal(u.select.left + u.select.width, "x");
          u.setSelect({ left: 0, top: 0, width: 0, height: 0 }, false);
          latest.current.onZoom([min, max]);
        }],
        draw: [(u) => {
          drawOverlays(u, latest.current, text);
          // What was drawn, where a test can read it: the canvas cannot be.
          const fig = u.root.parentElement?.parentElement;
          if (fig) {
            fig.dataset["yMin"] = String(u.scales["y"]?.min ?? "");
            fig.dataset["yMax"] = String(u.scales["y"]?.max ?? "");
            fig.dataset["xMin"] = String(u.scales["x"]?.min ?? "");
            fig.dataset["xMax"] = String(u.scales["x"]?.max ?? "");
            fig.dataset["xTicks"] = xTicks.current.join("|");
            fig.dataset["points"] = String(latest.current.series[0]?.values
              .filter((v) => v !== null).length ?? 0);
          }
        }],
      },
    };
    const chart = new uPlot(opts, data(), el);
    plot.current = chart;
    if (props.zoom) chart.setScale("x", { min: props.zoom[0], max: props.zoom[1] });
    const resize = new ResizeObserver(() => {
      chart.setSize({ width: el.clientWidth, height: props.height ?? 170 });
    });
    resize.observe(el);
    return () => {
      resize.disconnect();
      chart.destroy();
      plot.current = null;
    };
    // Rebuilt only for colours, clock or series; data and zoom update in place.
  }, [props.theme, props.clock, shape]);

  useEffect(() => {
    const chart = plot.current;
    if (!chart) return;
    chart.setData(data(), props.zoom === null);
    if (props.zoom) chart.setScale("x", { min: props.zoom[0], max: props.zoom[1] });
  });

  return (
    <figure class={props.wide ? "perf-chart perf-wide" : "perf-chart"}>
      <figcaption>{props.title}</figcaption>
      <div ref={host} />
    </figure>
  );
}

/** Map changes as labelled vertical lines, reference values as dashed ones. */
function drawOverlays(u: uPlot, props: PerfChartProps, color: string) {
  const ctx = u.ctx;
  const { left, top, width, height } = u.bbox;
  const px = devicePixelRatio;
  ctx.save();
  ctx.beginPath();
  ctx.rect(left, top, width, height);
  ctx.clip();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = px;
  ctx.font = `${11 * px}px system-ui, sans-serif`;
  ctx.setLineDash([4 * px, 4 * px]);
  // Map-change labels sit at the top of their own line; where each one's text
  // lands, so a reference label can keep clear of it.
  const markerBoxes: [number, number, number, number][] = [];
  for (const m of props.markers ?? []) {
    const x = u.valToPos(m.at, "x", true);
    if (x < left || x > left + width) continue;
    markerBoxes.push([x + 4 * px, top, x + 4 * px + ctx.measureText(m.label).width, top + 16 * px]);
  }
  for (const r of props.refLines ?? []) {
    const y = u.valToPos(r.value, "y", true);
    if (y < top || y > top + height) continue;
    ctx.beginPath();
    ctx.moveTo(left, y);
    ctx.lineTo(left + width, y);
    ctx.stroke();
    // At the left end, where a map-change label usually is not; at the right
    // end when one is (a map load at the start of the data).
    const w = ctx.measureText(r.label).width;
    const box: [number, number, number, number] =
      [left + 4 * px, y - 16 * px, left + 4 * px + w, y];
    const hit = markerBoxes.some(([x1, y1, x2, y2]) =>
      box[0] < x2 && x1 < box[2] && box[1] < y2 && y1 < box[3]);
    ctx.textAlign = hit ? "right" : "left";
    ctx.fillText(r.label, hit ? left + width - 4 * px : left + 4 * px, y - 4 * px);
  }
  for (const m of props.markers ?? []) {
    const x = u.valToPos(m.at, "x", true);
    if (x < left || x > left + width) continue;
    ctx.beginPath();
    ctx.moveTo(x, top);
    ctx.lineTo(x, top + height);
    ctx.stroke();
    ctx.textAlign = "left";
    ctx.fillText(m.label, x + 4 * px, top + 12 * px);
  }
  ctx.restore();
}

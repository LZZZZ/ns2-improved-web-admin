// The header's tickrate over the last few minutes, from the state polls the
// header already makes: no request of its own. Kept for the page's life; a
// map change does not clear it, so its dip shows.

import { useEffect, useState } from "preact/hooks";

const kSamples = 90;
const kWidth = 64;
const kHeight = 18;

let samples: number[] = [];
let lastAt: number | null = null;

/** One reading per poll: `at` is the poll's time, so a re-render adds nothing. */
function add(at: number, value: number): number[] {
  if (at === lastAt || !Number.isFinite(value)) return samples;
  lastAt = at;
  samples = [...samples.slice(1 - kSamples), value];
  return samples;
}

export function TickSpark({ at, value }: { at: number | null; value: number }) {
  const [list, setList] = useState(samples);
  useEffect(() => { if (at !== null) setList(add(at, value)); }, [at, value]);
  if (list.length === 0) return null;

  // The upper half of the range, topped at the rate rounded to ten (60 for
  // 59.6 or 60.3): a tick of jitter stays a wiggle, half rate is the floor.
  const peak = Math.max(...list);
  const top = Math.max(1, peak, Math.round(peak / 10) * 10);
  // One reading is a level line until the next arrives.
  const points = list.length === 1 ? [list[0]!, list[0]!] : list;
  const x = (i: number) => 1 + (i * (kWidth - 2)) / (points.length - 1);
  const y = (v: number) =>
    kHeight - 2 - (Math.max(0, v / top - 0.5) / 0.5) * (kHeight - 4);
  const line = points.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  // The graph replaces the number, so the number is on hover.
  const label = `Tickrate ${value.toFixed(1)}; last ${list.length} readings: `
    + `${Math.min(...list).toFixed(1)} to ${peak.toFixed(1)}`;

  return (
    <svg class="tick-spark" width={kWidth} height={kHeight} viewBox={`0 0 ${kWidth} ${kHeight}`}
         role="img" aria-label={label}>
      <title>{label}</title>
      <rect width={kWidth} height={kHeight} rx={3} />
      <polyline points={line} />
    </svg>
  );
}

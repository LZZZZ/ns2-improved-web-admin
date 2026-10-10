// Per-admin settings, in this browser only.
//
// The panel has no user model beyond HTTP Digest, so these follow the browser
// and not the admin. The UI says so rather than implying they sync. Storage is
// per origin, so two servers' panels keep separate ones.

import { useEffect, useState } from "preact/hooks";
import { LOG_KINDS } from "../ui/logkinds";
import type { LogKind } from "../ui/logkinds";

export type Theme = "dark" | "light" | "system";
export type ClockFormat = "locale" | "24h" | "utc";

export interface Settings {
  /** IPs and Steam ids masked until revealed. Default on -- see API.md. */
  maskIdentifiers: boolean;
  /** Seconds between server-state polls (header, Players). 0 stops polling. */
  refreshSeconds: number;
  /**
   * Seconds between chat reads. 0 stops them. Named for the Console tab it
   * once shared with, so a stored value keeps working.
   */
  consoleRefreshSeconds: number;
  /** Seconds between log reads, while the Console tab is open. 0 stops them. */
  logRefreshSeconds: number;
  theme: Theme;
  /** How times are written: as the browser's locale does, 24-hour, or UTC. */
  clock: ClockFormat;
  /** On by default; the one thing fetched from a third party, Steam's CDN. */
  modThumbnails: boolean;
  /** Open on the tab last used rather than on Players. */
  reopenLastTab: boolean;
  /** Checked against the tab list by the App, which owns it. */
  lastTab: string;
  playersHideBots: boolean;
  /** The Console tab's filters: the kinds of line it hides. */
  logHiddenKinds: LogKind[];
}

/** What the refresh selects offer, in their order. 0 is off. */
export const REFRESH_CHOICES = [1, 2, 5, 10, 0] as const;
const THEMES: readonly Theme[] = ["dark", "light", "system"];
const CLOCKS: readonly ClockFormat[] = ["locale", "24h", "utc"];

export const DEFAULTS: Settings = {
  maskIdentifiers: true,
  refreshSeconds: 2,
  consoleRefreshSeconds: 2,
  logRefreshSeconds: 2,
  theme: "dark",
  clock: "locale",
  modThumbnails: true,
  reopenLastTab: true,
  lastTab: "players",
  playersHideBots: false,
  // The engine's reports and unrecognised lines are most of a busy log.
  logHiddenKinds: ["engine", "other"],
};

const KEY = "improved-webadmin.settings";

/**
 * Whether this browser keeps what is saved. Private modes and blocked site
 * data refuse it, sometimes by throwing on access; the panel then works for
 * the session and says it will forget.
 */
export const storageOk: boolean = (() => {
  try {
    const probe = `${KEY}.probe`;
    localStorage.setItem(probe, "1");
    localStorage.removeItem(probe);
    return true;
  } catch {
    return false;
  }
})();

/**
 * Stored settings, field by field. Anything can be in storage -- an older
 * build's shape, a hand edit, a torn write -- so a field that is not what it
 * should be falls back to its default and the rest are kept.
 */
function sanitize(raw: unknown): Settings {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return DEFAULTS;
  const r = raw as Record<string, unknown>;
  const bool = (k: keyof Settings) =>
    typeof r[k] === "boolean" ? r[k] as boolean : DEFAULTS[k] as boolean;
  const refresh = (v: unknown, fallback: number) =>
    (REFRESH_CHOICES as readonly unknown[]).includes(v) ? v as number : fallback;
  const oneOf = <T,>(v: unknown, set: readonly T[], fallback: T) =>
    set.includes(v as T) ? v as T : fallback;

  const refreshSeconds = refresh(r["refreshSeconds"], DEFAULTS.refreshSeconds);
  return {
    maskIdentifiers: bool("maskIdentifiers"),
    refreshSeconds,
    // Absent in what builds before the console had its own knob stored: keep
    // the rate it ran at then, rather than changing it silently.
    consoleRefreshSeconds: r["consoleRefreshSeconds"] === undefined
      ? refreshSeconds
      : refresh(r["consoleRefreshSeconds"], DEFAULTS.consoleRefreshSeconds),
    logRefreshSeconds: refresh(r["logRefreshSeconds"], DEFAULTS.logRefreshSeconds),
    theme: oneOf(r["theme"], THEMES, DEFAULTS.theme),
    clock: oneOf(r["clock"], CLOCKS, DEFAULTS.clock),
    modThumbnails: bool("modThumbnails"),
    reopenLastTab: bool("reopenLastTab"),
    lastTab: typeof r["lastTab"] === "string" ? r["lastTab"] : DEFAULTS.lastTab,
    playersHideBots: bool("playersHideBots"),
    logHiddenKinds: Array.isArray(r["logHiddenKinds"])
      ? LOG_KINDS.map((k) => k.kind).filter((k) => (r["logHiddenKinds"] as unknown[]).includes(k))
      : DEFAULTS.logHiddenKinds,
  };
}

function load(): Settings {
  try {
    const stored = localStorage.getItem(KEY);
    if (!stored) return DEFAULTS;
    return sanitize(JSON.parse(stored));
  } catch {
    return DEFAULTS;
  }
}

let current = load();
const listeners = new Set<() => void>();

function notify() {
  applyTheme();
  for (const l of listeners) l();
}

export function getSettings(): Settings {
  return current;
}

export function updateSettings(patch: Partial<Settings>): void {
  current = { ...current, ...patch };
  try {
    localStorage.setItem(KEY, JSON.stringify(current));
  } catch {
    // Private mode, or storage disabled. The panel still works for this
    // session; it just forgets. The Settings tab says so (storageOk).
  }
  notify();
}

export function resetSettings(): void {
  current = DEFAULTS;
  try {
    localStorage.removeItem(KEY);
  } catch {
    // As above.
  }
  notify();
}

// Another browser tab of the panel on this address changed them: follow it,
// or two open tabs drift apart and the last one closed wins.
try {
  window.addEventListener("storage", (e) => {
    if (e.key !== KEY && e.key !== null) return;   // null: storage cleared
    current = load();
    notify();
  });
} catch {
  // No window events (never in a browser); nothing to follow.
}

export function useSettings(): Settings {
  const [, force] = useState(0);
  useEffect(() => {
    const listener = () => force((n) => n + 1);
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  }, []);
  return current;
}

// ------------------------------------------------------------------ theme

// "system" is resolved here, to dark or light, and the page is only ever told
// the resolved one: the stylesheet has one light block, and the charts, which
// take their colours when they are built, need to know when to rebuild.
const lightQuery = typeof matchMedia === "function"
  ? matchMedia("(prefers-color-scheme: light)")
  : null;

/** What the system asks for, whatever the setting. */
export function systemTheme(): "dark" | "light" {
  return lightQuery?.matches ? "light" : "dark";
}

export function resolvedTheme(): "dark" | "light" {
  return current.theme === "system" ? systemTheme() : current.theme;
}

/** Set the page's theme. Called before the first render, and on any change. */
export function applyTheme(): void {
  document.documentElement.dataset["theme"] = resolvedTheme();
}

// Notify on any flip: the page's theme follows it under "system", and the
// Settings tab names what the system is asking for either way.
lightQuery?.addEventListener("change", notify);

/** The theme actually showing, re-rendering when the system's flips. */
export function useResolvedTheme(): "dark" | "light" {
  useSettings();
  return resolvedTheme();
}

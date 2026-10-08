import { getSettings } from "../store/settings";
import type { ClockFormat } from "../store/settings";

export function duration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s % 60}s`;
  return `${s}s`;
}

/**
 * The clock setting as Intl options: the locale's own way, 24-hour local, or
 * 24-hour UTC. Read at call time; a change re-renders everything from App.
 */
function clockOptions(format: ClockFormat = getSettings().clock): Intl.DateTimeFormatOptions {
  switch (format) {
    // hourCycle, not hour12: false, which some engines render as 24:05.
    case "24h": return { hourCycle: "h23" };
    case "utc": return { hourCycle: "h23", timeZone: "UTC" };
    default: return {};
  }
}

/** A time of day. `format` defaults to the setting; Settings passes others. */
export function clock(at: number, format: ClockFormat = getSettings().clock): string {
  return new Date(at).toLocaleTimeString([], {
    hour: "2-digit", minute: "2-digit", second: "2-digit", ...clockOptions(format),
  });
}

/** Hours and minutes for a chart's time axis; seconds when ticks are closer. */
export function axisClock(at: number, withSeconds = false): string {
  return new Date(at).toLocaleTimeString([], {
    hour: "2-digit", minute: "2-digit",
    ...(withSeconds ? { second: "2-digit" } : {}), ...clockOptions(),
  });
}

/** Masked identifiers keep the shape of the real value without leaking it. */
export function maskSteamId(id: number): string {
  const s = String(id);
  return s.length <= 4 ? "••••" : `••••••${s.slice(-3)}`;
}

export function maskIp(ip: string): string {
  const parts = ip.split(".");
  if (parts.length !== 4) return "•••.•••.•••.•••";
  return `${parts[0]}.•••.•••.•••`;
}

/** Console lines are log lines: 24-hour whatever the setting, UTC if it says. */
export function logClock(at: number): string {
  return new Date(at).toLocaleTimeString([], {
    hour: "2-digit", minute: "2-digit", second: "2-digit", ...clockOptions(),
    hourCycle: "h23",
  });
}

/** "3d 4h", "2h 5m", "45m", "30s": a span in its two largest units. */
export function span(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return h > 0 ? `${d}d ${h}h` : `${d}d`;
  if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`;
  if (m > 0) return `${m}m`;
  return `${s}s`;
}

/** A unix-seconds timestamp as a date and time, marked when it is UTC. */
export function dateTime(unixSeconds: number): string {
  const text = new Date(unixSeconds * 1000).toLocaleString([], {
    year: "numeric", month: "short", day: "numeric",
    hour: "2-digit", minute: "2-digit", ...clockOptions(),
  });
  return getSettings().clock === "utc" ? `${text} UTC` : text;
}

/**
 * Text that is about to become part of a console command line.
 *
 * Measured on the rig (docs/CONSTRAINTS.md, "What console arguments can
 * carry"): arguments split on whitespace, quotes are not parsed and `;` does
 * not start a second command. Nothing seen lets a value escape its argument,
 * but slot names can come from player names, so `;`, quotes and control
 * characters are dropped rather than trusted.
 */
export function consoleArg(text: string): string {
  return text
    .replace(/[;"'`\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * A chat message on its way to sv_say or sv_tsay. Unlike consoleArg it keeps
 * quotes and apostrophes, which people type in chat: measured on the rig, the
 * console does not parse quotes and `;` does not start a second command
 * (`sv_say a; sv_say b` is one line reading `a; sv_say b`). Control
 * characters still go, and whitespace collapses as the console would.
 */
export function chatArg(text: string): string {
  return text
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * A reserved slot name: one console argument, so no whitespace at all. Spaces
 * become underscores, because quoting a name only stores the quote marks.
 */
export function slotName(text: string): string {
  return consoleArg(text).replace(/ /g, "_");
}

const kSteamId64Base = 76561197960265728n;
const kMaxAccountId = 0xffffffff;

/**
 * The NS2 id (a Steam account id) from any of the forms an admin is likely to
 * paste: the account id itself, a SteamID64 from a profile URL, STEAM_X:Y:Z,
 * or [U:1:N]. Null when it is none of them.
 */
export function parseSteamId(input: string): number | null {
  const text = input.trim();
  let m: RegExpMatchArray | null;
  if ((m = text.match(/^STEAM_[0-5]:([01]):(\d+)$/i))) {
    const id = Number(m[2]) * 2 + Number(m[1]);
    return id > 0 && id <= kMaxAccountId ? id : null;
  }
  if ((m = text.match(/^\[?U:1:(\d+)\]?$/i))) {
    const id = Number(m[1]);
    return id > 0 && id <= kMaxAccountId ? id : null;
  }
  if (/^\d{1,20}$/.test(text)) {
    const big = BigInt(text);
    if (big > kSteamId64Base && big - kSteamId64Base <= BigInt(kMaxAccountId)) {
      return Number(big - kSteamId64Base);
    }
    return big > 0n && big <= BigInt(kMaxAccountId) ? Number(big) : null;
  }
  return null;
}

/** The SteamID64 of an NS2 id (a Steam account id). Past 2^53, so a string. */
export function steamId64(accountId: number): string {
  return (kSteamId64Base + BigInt(accountId)).toString();
}

/** A size in bytes, as B, KB, MB or GB (binary units). */
export function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
}

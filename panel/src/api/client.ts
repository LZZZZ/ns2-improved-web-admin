// The only module that talks to the server, and the only one that sees a raw
// API shape. Everything it returns is normalized: real booleans, stable keys,
// Steam ids and mod ids left as the server spells them.
//
// Behaviour this has to survive, all of it measured:
//
//   * every read is GET / with a `request` query parameter, and an unknown
//     `request` silently returns the server-state blob rather than an error
//   * a path that is not a file on disk returns 200 JSON too, so a bad URL
//     surfaces as a parse error, never as a 404
//   * writes answer 200 with an empty text/html body -- no success flag
//   * a POST's query string never reaches Lua: `request` and every parameter
//     go in the form body (measured on 09-26)
//   * 503 means "busy, retry", not "failed"
//   * digest re-authentication is the browser's problem, not ours: a 480 s
//     poll across a nonce expiry never showed a 401 to the page

import type {
  BanList, CommandResult, ConsoleLine, InstalledMod, MapInfo,
  MapCycleWrite, MapVote, Player, RawBanList, RawCommandResult,
  RawConsoleLine, RawInstalledMod, RawMapCycle,
  RawMapCycleWrite, RawMapListEntry, RawMapVote, RawPlayer, RawRecentPlayers,
  RawReservedSlots, RawServerState, RecentPlayers, ReservedSlots, ServerState,
  InstallModResult, RawInstallModResult, RawWorkshopItem, RawWorkshopSearch,
  WorkshopItem, WorkshopSearch, PerfPoint, PerfReport, RawPerfReport,
  PerfEngine, RawPerfEngine,
  RawPerfWindow, LogPage, RawLogPage,
  ChatEntry, ChatPage, RawChatMessage, RawChatStream,
} from "./types";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    /** A busy server, not a broken one. Retry rather than surfacing it. */
    readonly retryable = status === 503,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function call(
  params: Record<string, string>,
  signal?: AbortSignal,
  method: "GET" | "POST" = "GET",
): Promise<Response> {
  const query = new URLSearchParams(params);
  const res = await fetch(method === "GET" ? `/?${query}` : "/", {
    method,
    // A POST carries everything in its form body; its query string would be
    // dropped before Lua saw it.
    body: method === "POST" ? query : undefined,
    // Digest credentials ride along; the browser handles the challenge.
    credentials: "same-origin",
    // Replies are Cache-Control: no-store anyway; say so on our side too.
    cache: "no-store",
    signal,
  });
  if (!res.ok) {
    throw new ApiError(`${params["request"] ?? "request"} -> ${res.status}`,
                       res.status);
  }
  return res;
}

async function getJson<T>(
  params: Record<string, string>,
  signal?: AbortSignal,
  method: "GET" | "POST" = "GET",
): Promise<T> {
  const res = await call(params, signal, method);
  const text = await res.text();
  try {
    return JSON.parse(text) as T;
  } catch {
    // Reached when a request lands on a path the server does not have: the
    // body is HTML or an unrelated blob rather than what was asked for.
    throw new ApiError(
      `${params["request"] ?? "request"} did not return JSON ` +
      `(${res.headers.get("content-type") ?? "no content-type"})`,
      res.status,
      false,
    );
  }
}

// ------------------------------------------------------------- normalizing

function normalizePlayer(raw: RawPlayer, index: number): Player {
  return {
    name: raw.name,
    steamId: raw.steamid,
    isBot: raw.isbot,
    team: raw.team,
    isCommander: raw.iscomm,
    score: raw.score,
    kills: raw.kills,
    assists: raw.assists,
    deaths: raw.deaths,
    resources: raw.resources,
    ping: raw.ping,
    ip: raw.ipaddress,
    gagged: typeof raw.gagged === "boolean" ? raw.gagged : null,
    familyShared: raw.familyshared,
    ownerSteamId: typeof raw.owner_steamid === "number" ? raw.owner_steamid : null,
    movesRejected: { time: raw.moves_rejected_time, other: raw.moves_rejected_other },
    skill: typeof raw.skill === "number"
      ? { skill: raw.skill, offset: raw.skill_offset ?? 0,
          comm: raw.comm_skill ?? null, commOffset: raw.comm_skill_offset ?? 0,
          tier: typeof raw.skill_tier === "number" ? raw.skill_tier : null }
      : null,
    // Bots all report steamid 0, so the id alone is not a key. Name plus
    // index keeps rows stable across polls without colliding.
    key: raw.steamid !== 0 ? `s${raw.steamid}` : `b${raw.name}#${index}`,
  };
}

export function normalizeServerState(raw: RawServerState): ServerState {
  return {
    serverName: raw.server_name,
    map: raw.map,
    uptimeSeconds: raw.uptime,
    cheats: raw.cheats,
    devMode: raw.devmode,
    playersOnline: raw.players_online,
    marines: raw.marines,
    aliens: raw.aliens,
    marineRes: raw.marine_res,
    alienRes: raw.alien_res,
    frameRate: raw.frame_rate,
    gameStarted: raw.game_started,
    gameTimeSeconds: raw.game_time,
    players: (raw.player_list ?? []).map(normalizePlayer),
    maxPlayers: raw.max_players,
    mapLoadedAt: raw.map_loaded_at * 1000,
    rankingActive: raw.ranking_active,
    shine: raw.shine
      ? {
          bans: raw.shine.ban,
          reservedSlots: raw.shine.reservedslots,
          mapVote: raw.shine.mapvote,
          baseCommands: raw.shine.basecommands,
        }
      : null,
  };
}

// --------------------------------------------------------------- requests

export async function getServerState(signal?: AbortSignal): Promise<ServerState> {
  // `json` is not a recognised request type -- it is one of the unmatched
  // values that fall through to the default handler. The 2012 panel sends it,
  // so it stays as the convention.
  return normalizeServerState(
    await getJson<RawServerState>({ request: "json" }, signal));
}

/** The bans in force, read from whichever table decides them. */
export async function getBans(signal?: AbortSignal): Promise<BanList> {
  const raw = await getJson<RawBanList>({ request: "getbans" }, signal);
  return {
    source: raw.source,
    skewSeconds: raw.now - Date.now() / 1000,
    bans: raw.bans.map((b, order) => ({
      name: b.name,
      steamId: Number(b.id),
      reason: b.reason,
      permanent: b.permanent,
      expiresAt: b.permanent ? null : (b.expires ?? null),
      issuedAt: b.issued ?? null,
      bannedBy: b.banned_by ?? null,
      order,
    })),
  };
}

/** Players seen in the last day, connected or not. */
export async function getRecentPlayers(signal?: AbortSignal): Promise<RecentPlayers> {
  const raw = await getJson<RawRecentPlayers>({ request: "getrecentplayers" }, signal);
  return {
    windowSeconds: raw.window,
    capacity: raw.capacity,
    loaded: raw.storage.loaded,
    saveError: raw.storage.error ?? null,
    skewSeconds: raw.now - Date.now() / 1000,
    players: raw.players.map((p) => ({
      steamId: p.steamid,
      name: p.name,
      formerNames: p.names ?? [],
      ip: p.ipaddress,
      firstSeen: p.first_seen,
      lastSeen: p.last_seen,
      playedSeconds: p.played,
      connected: p.connected,
    })),
  };
}

export async function getReservedSlots(signal?: AbortSignal): Promise<ReservedSlots> {
  const raw = await getJson<RawReservedSlots>({ request: "getreservedslots" }, signal);
  return {
    configured: raw.amount !== undefined && raw.ids !== undefined,
    amount: raw.amount ?? 0,
    slots: (raw.ids ?? []).map((r) => ({ name: r.name, steamId: Number(r.id) })),
    shineSlots: raw.shine ? raw.shine.slots : null,
  };
}

function normalizeConsoleLine(raw: RawConsoleLine): ConsoleLine {
  return { id: raw.id, at: raw.time * 1000, src: raw.src, text: raw.text };
}

/**
 * Run a console command and get back what it printed.
 *
 * `dispatched` is the audit line the game emits before every command made with
 * CreateServerAdminCommand: true means it existed and ran. An empty `lines`
 * with `dispatched: true` is ordinary -- a successful kick prints nothing --
 * so it must never be rendered as failure, nor as success.
 */
export async function runCommand(
  command: string,
  signal?: AbortSignal,
): Promise<CommandResult> {
  const raw = await getJson<RawCommandResult>(
    { request: "runcommand", cmd: command }, signal);
  return {
    command: raw.cmd,
    dispatched: raw.dispatched,
    lines: (raw.lines ?? []).map(normalizeConsoleLine),
  };
}

// ------------------------------------------------------------------- chat

/** The chat ring from `since` on, with times. */
export async function getChat(since: number, signal?: AbortSignal): Promise<ChatPage> {
  const raw = await getJson<RawChatStream>(
    { request: "getchatlist", since: String(since) }, signal);
  return {
    entries: (raw.entries ?? []).map(normalizeChat),
    lastId: raw.last_id ?? 0,
    dropped: raw.dropped ?? 0,
    bufferSize: raw.buffer_size ?? 200,
  };
}

function normalizeChat(raw: RawChatMessage & { time: number }): ChatEntry {
  return {
    id: raw.id,
    at: raw.time * 1000,
    message: String(raw.message ?? ""),
    player: String(raw.player ?? ""),
    steamId: Number(raw.steamId) || 0,
    team: raw.team,
    teamOnly: raw.teamOnly === true,
  };
}

// ------------------------------------------------------------ server log

/**
 * The server's log. No cursor: its last 64 KB. `since` and `file`: what was
 * written after `since` in that file. `before`: the page ending there. A reply
 * that is not a page is an error, not an empty log.
 */
export async function getLog(
  cursor: { since?: number; before?: number; file?: string },
  signal?: AbortSignal,
): Promise<LogPage> {
  const params: Record<string, string> = { request: "getlog" };
  if (cursor.since !== undefined) params["since"] = String(cursor.since);
  if (cursor.before !== undefined) params["before"] = String(cursor.before);
  if (cursor.file !== undefined) params["file"] = cursor.file;
  const raw = await getJson<RawLogPage>(params, signal);
  if (!Array.isArray(raw?.lines)) {
    throw new ApiError("getlog did not return the log", 200, false);
  }
  return {
    fileId: raw.file_id ?? "",
    size: raw.size,
    from: raw.from,
    to: raw.to,
    lines: raw.lines,
    more: raw.more === true,
    atStart: raw.at_start === true,
    reset: raw.reset ?? null,
  };
}

// ------------------------------------------------------------ performance

/**
 * The performance windows since `since` (0 for all it holds), one page of
 * them: `more` says the server holds more past `lastId`. A reply that is not
 * a report is an error, not an empty chart.
 */
export async function getPerf(since: number, esince: number,
                              signal?: AbortSignal): Promise<PerfReport> {
  const raw = await getJson<RawPerfReport>(
    { request: "getperf", since: String(since), esince: String(esince) }, signal);
  if (typeof raw !== "object" || raw === null || !Array.isArray(raw.windows)
      || typeof raw.loaded_at !== "number") {
    throw new ApiError("getperf did not return performance windows", 200, false);
  }
  return {
    windowSeconds: raw.window_s,
    capacity: raw.capacity,
    loadedAt: raw.loaded_at * 1000,
    map: raw.map,
    config: raw.config ?? null,
    points: raw.windows.map(normalizePerfWindow),
    lastId: raw.last_id,
    more: raw.more,
    engine: normalizePerfEngine(raw.engine),
  };
}

// The engine's JSON writer writes an empty list as [] (measured), but a list
// that is not one is no records rather than a crash.
const list = <T>(v: T[] | undefined): T[] => Array.isArray(v) ? v : [];
const stamped = <T extends { time: number }>(r: T): T & { at: number } =>
  ({ ...r, at: r.time * 1000 });

function normalizePerfEngine(e: RawPerfEngine): PerfEngine {
  return {
    scanSeconds: e.scan_s,
    lastId: e.last_id,
    more: e.more === true,
    now: e.now * 1000,
    tickstatLastAt: typeof e.tickstat_last_at === "number" ? e.tickstat_last_at * 1000 : null,
    tickstatSaid: e.tickstat_said
      ? { text: e.tickstat_said.text, at: e.tickstat_said.time * 1000 } : null,
    tickstats: list(e.tickstats).map(stamped),
    perfmon: list(e.perfmon).map(stamped),
    events: list(e.events).map(stamped),
  };
}

function normalizePerfWindow(w: RawPerfWindow): PerfPoint {
  return {
    id: w.id,
    at: w.time * 1000,
    tickrate: w.tickrate,
    worstTickMs: w.worst_tick_ms,
    players: w.players,
    score: w.score,
    idlePct: w.idle_pct,
    movesPct: w.moves_pct,
    entitiesPct: w.entities_pct,
    entities: w.entities,
    interpWarns: w.interp_warns,
    interpFails: w.interp_fails,
    luaKb: w.lua_kb,
  };
}

// ------------------------------------------------------------------- maps

/** MapCycle.json as the file holds it. */
export async function getMapCycle(signal?: AbortSignal): Promise<RawMapCycle> {
  const raw = await getJson<RawMapCycle>({ request: "getmapcycle" }, signal);
  if (typeof raw !== "object" || raw === null || !Array.isArray(raw.maps)) {
    throw new ApiError("getmapcycle did not return a map cycle", 200, false);
  }
  return raw;
}

/**
 * Replace the whole cycle. Posted, since a cycle can outgrow a URL. The answer
 * is the file read back or the reason it refused.
 */
export async function setMapCycle(
  cycle: RawMapCycle,
  signal?: AbortSignal,
): Promise<MapCycleWrite> {
  const params = { request: "setmapcycle", data: JSON.stringify(cycle) };
  const raw = await getJson<RawMapCycleWrite>(params, signal, "POST");
  if (raw.ok === true && raw.cycle && Array.isArray(raw.cycle.maps)) {
    return { kind: "written", cycle: raw.cycle };
  }
  if (raw.ok === false) return { kind: "refused", error: String(raw.error) };
  throw new ApiError("setmapcycle answered neither a cycle nor a refusal", 200, false);
}

export async function getMapList(signal?: AbortSignal): Promise<MapInfo[]> {
  const raw = await getJson<RawMapListEntry[]>({ request: "getmaplist" }, signal);
  return raw.map((m) => ({
    name: m.name,
    modId: m.modId && m.modId !== "0" ? m.modId : null,
  }));
}

export async function getInstalledMods(signal?: AbortSignal): Promise<InstalledMod[]> {
  const raw = await getJson<RawInstalledMod[]>({ request: "getinstalledmodslist" }, signal);
  return raw.map((m) => ({
    id: m.id,
    name: m.name,
    active: m.active,
    whitelisted: m.whitelisted,
  }));
}

/** Shine's mapvote, as far as it concerns the cycle. */
export async function getMapVote(signal?: AbortSignal): Promise<MapVote> {
  const raw = await getJson<RawMapVote>({ request: "getmapvote" }, signal);
  return {
    enabled: raw.enabled === true,
    mapsFromCycle: raw.maps_from_cycle === true,
    roundLimit: raw.round_limit ?? 0,
    nextMap: raw.next_map ?? null,
    options: raw.options ?? [],
  };
}

// --------------------------------------------------------------- workshop

function normalizeWorkshopItem(m: RawWorkshopItem): WorkshopItem {
  return {
    id: String(m.id),
    title: String(m.title ?? ""),
    description: String(m.description ?? ""),
    authorId: String(m.authorid ?? ""),
    fileSize: Number(m.filesize) || 0,
    tags: String(m.tags ?? "").split(",").map((t) => t.trim()).filter(Boolean),
    steamResult: Number(m.steamresult),
    childCount: Number(m.childcount) || 0,
    thumbnailUrl: String(m.thumbnailurl ?? ""),
    updatedAt: Number(m.version) > 0 ? Number(m.version) : null,
    whitelisted: m.whitelisted,
  };
}

/**
 * One poll of a workshop search. The first call starts it on the server and
 * every call answers `loading` until it settles; the caller polls.
 *
 * There is no page: the engine ignores it and hands over the first 50 hits of
 * any search. An empty result means no matches or a search Steam failed --
 * the server cannot tell them apart, so neither can this.
 */
export async function searchWorkshop(
  text: string,
  signal?: AbortSignal,
): Promise<WorkshopSearch> {
  const raw = await getJson<RawWorkshopSearch>(
    { request: "getmods", searchtext: text }, signal);
  if (typeof raw !== "object" || raw === null) {
    throw new ApiError("getmods did not return a search result", 200, false);
  }
  if (raw.loading === true) {
    return { kind: "loading",
             elapsedSeconds: typeof raw.elapsed === "number" ? raw.elapsed : null };
  }
  if (typeof raw.error === "string") return { kind: "error", error: raw.error };
  const items = (Array.isArray(raw.items) ? raw.items : []).map(normalizeWorkshopItem);
  return { kind: "results", items, capped: raw.capped === true };
}

/**
 * Ask the server to download a workshop mod. Posted, with the id in the body.
 * Neither answer says the download worked: only the id showing up in
 * getinstalledmodslist does, and it shows up once downloaded, never before.
 */
export async function installMod(
  id: string,
  signal?: AbortSignal,
): Promise<InstallModResult> {
  const params = { request: "installmod", modid: id };
  const raw = await getJson<RawInstallModResult>(params, signal, "POST");
  if (raw.ok === true && typeof raw.id === "string") {
    return { kind: "sent", id: raw.id, alreadyInstalled: raw.already_installed === true };
  }
  if (raw.ok === false) return { kind: "refused", error: String(raw.error) };
  throw new ApiError("installmod answered neither ok nor a refusal", 200, false);
}

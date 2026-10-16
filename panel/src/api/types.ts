// The API's types, mirrored from docs/openapi.yaml, in two halves.
//
// `Raw*` is what the server actually sends, inconsistencies intact: `cheats`,
// `devmode` and `isbot` are stringified booleans on a stock server (the panel Lua
// sends real ones, like `iscomm` and `game_started`), mod ids are hex strings,
// and the same Steam id is spelled `steamid`, `steamId` and `id` in three
// different responses.
//
// Everything below the client's normalize step uses the second half instead,
// so no component ever has to remember which is which.

/** A workshop id, lowercase hex, no 0x prefix. Never parse it as a number. */
export type ModId = string;

/** A boolean that crossed the wire as a string. `"false"` is truthy in JS. */
export type StringBool = "true" | "false";

/** A string on a stock server, a real boolean from the panel Lua. */
export type WireBool = boolean | StringBool;

/** 0 ready room, 1 marines, 2 aliens, 3 spectators. */
export type TeamNumber = 0 | 1 | 2 | 3;

// -------------------------------------------------------------- raw shapes

export interface RawPlayer {
  name: string;
  steamid: number;
  isbot: WireBool;
  team: TeamNumber;
  iscomm: boolean;
  score: number;
  kills: number;
  assists: number;
  deaths: number;
  resources: number;
  ping: number;
  ipaddress: string;
  /** Panel Lua only, and only under Shine's basecommands: Shine's gag. */
  gagged?: boolean;
  /** Panel Lua only: playing a Steam Family Shared copy. */
  familyshared?: boolean;
  /** With `familyshared`: the account that owns the game. */
  owner_steamid?: number;
  /** Panel Lua only: moves rejected for time credit (usually a
   * modified client) and for anything else (a poor connection can do it). */
  moves_rejected_time?: number;
  moves_rejected_other?: number;
  /** Panel Lua only: Hive skill (ScoringMixin) and the per-team offsets. */
  skill?: number;
  skill_offset?: number;
  comm_skill?: number;
  comm_skill_offset?: number;
  /** Panel Lua only: the tier the game draws the skill badge for
   * (ScoringMixin:GetSkillTier): -2 none, -1 bot, 0 rookie, 1-7. */
  skill_tier?: number;
}

export interface RawServerState {
  webdomain: string;
  webport: string;
  cheats: WireBool;
  devmode: WireBool;
  map: string;
  players_online: number;
  marines: number;
  aliens: number;
  uptime: number;
  player_list: RawPlayer[];
  marine_res: number;
  alien_res: number;
  server_name: string;
  frame_rate: number;
  game_started: boolean;
  game_time: number;
  /** Added by the panel Lua. Absent means a stock server. */
  lua_version?: string;
  /** Panel Lua only. The reserved slot amount cannot exceed it. */
  max_players?: number;
  /** Panel Lua only. When the current map loaded, Unix seconds. */
  map_loaded_at?: number;
  /** Panel Lua only. Server.GetIsRankingActive(): the engine's verdict on ranking. */
  ranking_active?: boolean;
  /** Panel Lua only, and only when Shine is loaded. */
  shine?: RawShineState;
}

export interface RawShineState {
  ban: boolean;
  reservedslots: boolean;
  mapvote: boolean;
  /** Absent from mods older than 2026-10-06. */
  basecommands?: boolean;
}

/** `getbanlist`: GetBannedPlayersList() as it stands. The stock path. */
export interface RawBan {
  name: string;
  /** A number from vanilla; a digit string when Shine's ban plugin owns the list. */
  id: number | string;
  reason: string;
  /**
   * Unix seconds; 0 is permanent. Expired bans are never pruned on a stock
   * server, and under Shine a permanent ban can read 6e+24.
   */
  time: number;
}

/** `getbans` (panel Lua only): the bans in force, from the table that decides them. */
export interface RawBanEntry {
  id: number;
  name: string;
  reason: string;
  permanent: boolean;
  /** Unix seconds; absent when permanent. */
  expires?: number;
  /** Shine only. */
  issued?: number;
  duration?: number;
  banned_by?: string;
}

export interface RawBanList {
  source: "vanilla" | "shine";
  /** The server's clock, unix seconds. */
  now: number;
  bans: RawBanEntry[];
}

export interface RawReservedSlots {
  /** Both keys are absent when the server has no reserved-slot config. */
  amount?: number;
  ids?: { name: string; id: number }[];
  /** Panel Lua only, while Shine's reservedslots plugin is on. */
  shine?: { slots: number };
}

// ------------------------------------------------------- normalized shapes

export interface Player {
  name: string;
  /** `0` for bots, which is why every per-player command fails on them. */
  steamId: number;
  isBot: boolean;
  team: TeamNumber;
  isCommander: boolean;
  score: number;
  kills: number;
  assists: number;
  deaths: number;
  resources: number;
  ping: number;
  ip: string;
  /** Muted by Shine (sh_gag); null where nothing can say. */
  gagged: boolean | null;
  /** A Family Shared copy; null on an engine that cannot tell. */
  familyShared: boolean | null;
  /** Who owns a shared copy, when the engine says. */
  ownerSteamId: number | null;
  /** Rejected moves; null on an engine that does not count them. */
  movesRejected: { time: number; other: number } | null;
  /**
   * Hive skill as the server holds it; null on a stock server. Marines play
   * at skill + offset, aliens at skill - offset; the commander's pair alike.
   * `tier` is the server's skill tier, null from a mod that predates it.
   */
  skill: { skill: number; offset: number; comm: number | null; commOffset: number;
           tier: number | null } | null;
  /** Stable across polls: SteamID for players, name for bots, which share 0. */
  key: string;
}

export interface ServerState {
  serverName: string;
  map: string;
  uptimeSeconds: number;
  cheats: boolean;
  devMode: boolean;
  playersOnline: number;
  marines: number;
  aliens: number;
  marineRes: number;
  alienRes: number;
  frameRate: number;
  gameStarted: boolean;
  gameTimeSeconds: number;
  players: Player[];
  /** The panel Lua version, or null on a stock server. */
  luaVersion: string | null;
  /** Null on a stock server, which does not report it. */
  maxPlayers: number | null;
  /** When the current map loaded, ms; null on a stock server. */
  mapLoadedAt: number | null;
  /** Whether the engine counts this server's rounds for ranking; null when not reported. */
  rankingActive: boolean | null;
  /**
   * Which Shine plugins own what. Null when Shine is not loaded -- or when the
   * server is stock, which cannot say either way.
   */
  shine: ShineState | null;
}

export interface ShineState {
  /** Shine owns the ban list; ban with sh_banid, unban with sh_unban. */
  bans: boolean;
  /** Shine sets the slot count and grants access by permission. */
  reservedSlots: boolean;
  mapVote: boolean;
  /** Shine's basecommands: sh_gag and sh_ungag, the only mute there is. */
  baseCommands: boolean;
}

export interface Ban {
  name: string;
  steamId: number;
  reason: string;
  permanent: boolean;
  /** Unix seconds on the server's clock; null when permanent. */
  expiresAt: number | null;
  /** Shine only: when, by whom, and for how long. */
  issuedAt: number | null;
  bannedBy: string | null;
  /** Position in the server's own order, newest first where it has one. */
  order: number;
}

export interface BanList {
  /** `stock` means getbanlist on a server without the panel Lua: owner unknown. */
  source: "vanilla" | "shine" | "stock";
  bans: Ban[];
  /** Server clock minus this browser's, in seconds. 0 when unknown. */
  skewSeconds: number;
}

export interface ReservedSlot {
  name: string;
  steamId: number;
}

export interface ReservedSlots {
  /** False when the server has no reserved-slot config at all. */
  configured: boolean;
  amount: number;
  slots: ReservedSlot[];
  /** Shine's count while its reservedslots plugin is on, else null. */
  shineSlots: number | null;
}

// ------------------------------------------------ recent players (panel Lua only)

export type RecentLoad = "ok" | "fallback" | "empty" | "unreadable";

export interface RawRecentPlayer {
  steamid: number;
  name: string;
  /** Former names, newest first. */
  names: string[];
  ipaddress: string;
  first_seen: number;
  last_seen: number;
  played: number;
  connected: boolean;
}

export interface RawRecentPlayers {
  now: number;
  /** Seconds. */
  window: number;
  capacity: number;
  storage: { loaded: RecentLoad; saved_at?: number; error?: string };
  players: RawRecentPlayer[];
}

export interface RecentPlayer {
  steamId: number;
  name: string;
  formerNames: string[];
  /** Empty when the engine did not report one. */
  ip: string;
  /** Unix seconds on the server's clock. */
  firstSeen: number;
  lastSeen: number;
  playedSeconds: number;
  connected: boolean;
}

export interface RecentPlayers {
  windowSeconds: number;
  capacity: number;
  /** How this map's load of the saved list went. */
  loaded: RecentLoad;
  /** Why the last save failed; null while saves work. */
  saveError: string | null;
  players: RecentPlayer[];
  /** Server clock minus this browser's, in seconds. */
  skewSeconds: number;
}

export const TEAM_NAMES: Record<TeamNumber, string> = {
  0: "Ready room",
  1: "Marines",
  2: "Aliens",
  3: "Spectators",
};

// ------------------------------------------------- console (panel Lua only)

/** "audit": the line every admin command prints before it runs. */
export type ConsoleSource = "audit" | "server";

export interface RawConsoleLine {
  id: number;
  time: number;
  src: ConsoleSource;
  text: string;
}

export interface RawCommandResult {
  cmd: string;
  dispatched: boolean;
  elapsed?: number;
  lines: RawConsoleLine[];
}

/** One entry of getchatlist, as stock and the panel Lua (without `since`) send it. */
export interface RawChatMessage {
  id: number;
  message: string;
  player: string;
  steamId: number;
  team: TeamNumber;
  teamOnly: boolean;
}

/** The panel Lua's getchatlist&since=: its own ring of 200, with times. */
export interface RawChatStream {
  entries: (RawChatMessage & { time: number })[];
  last_id: number;
  dropped: number;
  buffer_size: number;
}

export interface ChatEntry {
  id: number;
  /** Milliseconds; null on a stock server, which records no time. */
  at: number | null;
  message: string;
  player: string;
  steamId: number;
  team: TeamNumber;
  teamOnly: boolean;
}

export interface ChatPage {
  entries: ChatEntry[];
  lastId: number;
  dropped: number;
  /** 200 with the panel Lua, the game's 20 without. */
  bufferSize: number;
  /** False when the server answered `{ }`: it has no chat buffer at all. */
  available: boolean;
}

export interface ConsoleLine {
  id: number;
  /** Milliseconds, converted from the server's unix seconds. */
  at: number;
  src: ConsoleSource;
  text: string;
}

export interface CommandResult {
  command: string;
  /**
   * The command was dispatched as an admin command, proven by its audit line.
   * `false` means a plain console command or no such command -- the server
   * cannot tell those apart, so neither can this.
   */
  dispatched: boolean;
  /**
   * What it printed. **Empty is not failure**: a successful `sv_kick` prints
   * nothing at all, and `sv_cheats` reports nothing either way.
   */
  lines: ConsoleLine[];
}

// ------------------------------------------------- the server log (panel Lua only)

export interface RawLogLine {
  off: number;
  text: string;
}

export interface RawLogPage {
  source: "file";
  file_id: string;
  size: number;
  from: number;
  to: number;
  lines: RawLogLine[];
  more: boolean;
  at_start: boolean;
  reset?: "new_file" | "truncated";
  tail_bytes: number;
  max_bytes: number;
}

/** One line of log-Server.txt, verbatim. */
export interface LogLine {
  /** Byte offset in the file: unique within one file, the row's key. */
  off: number;
  text: string;
}

export interface LogPage {
  /** The header's Date and Time: names the file across restarts. */
  fileId: string;
  size: number;
  from: number;
  /** Where the next read starts: after the last complete line served. */
  to: number;
  lines: LogLine[];
  /** The reply stopped at the server's cap; ask again at once. */
  more: boolean;
  atStart: boolean;
  /** The cursor did not fit the file; this reply is a fresh tail. */
  reset: "new_file" | "truncated" | null;
}

// ------------------------------------------------------------ maps

/**
 * One map cycle entry: a map name, or an object naming the mods that map
 * needs. Loose on purpose: Shine's mapvote reads more keys here (`min`,
 * `max`, `chance`, ...), and the game ignores them. They must survive every
 * write, so the panel edits the raw cycle and never rebuilds it.
 */
export type RawMapCycleEntry = string | RawMapCycleObject;

export interface RawMapCycleObject {
  map: string;
  mods?: ModId[];
  [key: string]: unknown;
}

/** `getmapcycle`: MapCycle.json, mod ids hex. Unknown keys kept, as above. */
export interface RawMapCycle {
  maps: RawMapCycleEntry[];
  /** Minutes on a map before the cycle advances; 0 never. */
  time?: number;
  mode?: string;
  /** Mods mounted with every map. */
  mods?: ModId[];
  [key: string]: unknown;
}

/** The panel Lua's answer to `setmapcycle`. A stock server answers an empty 200. */
export type RawMapCycleWrite =
  | { ok: true; cycle: RawMapCycle }
  | { ok: false; error: string };

export interface RawMapListEntry {
  name: string;
  /** `"0"` for a stock map. */
  modId: ModId;
}

export interface RawInstalledMod {
  id: ModId;
  /** The workshop title, or the decimal workshop id when the server has none. */
  name: string;
  /** Panel Lua only: mounted now. Changes only when the map changes. */
  active?: boolean;
  /** Panel Lua only: on the ranked-mod whitelist the engine read at boot. */
  whitelisted?: boolean;
}

/** `getmapvote` (panel Lua only). */
export interface RawMapVote {
  enabled: boolean;
  maps_from_cycle?: boolean;
  round_limit?: number;
  next_map?: string;
  options?: string[];
}

export type MapCycleWrite =
  /** Mod: MapCycle.json read back after the write. */
  | { kind: "written"; cycle: RawMapCycle }
  /** Mod: refused before anything was written. */
  | { kind: "refused"; error: string }
  /** Stock: an empty 200, whatever happened. */
  | { kind: "unverified" };

export interface MapInfo {
  name: string;
  /** Null for a stock map. */
  modId: ModId | null;
}

export interface InstalledMod {
  id: ModId;
  name: string;
  /** Mounted now; null on a stock server, which cannot say. */
  active: boolean | null;
  /** The engine's whitelist verdict; null on a stock server. */
  whitelisted: boolean | null;
}

export interface MapVote {
  /** False when Shine's mapvote is not on (or Shine is not loaded). */
  enabled: boolean;
  /** The vote's options are the cycle's maps. */
  mapsFromCycle: boolean;
  /** Rounds before the map ends; 0 means the cycle's time decides. */
  roundLimit: number;
  nextMap: string | null;
  /** What the vote offers now: read from the cycle when the map loaded. */
  options: string[];
}

// ---------------------------------------------------------------- workshop

/** One `getmods` hit, as Server.SearchWorshop hands it over. */
export interface RawWorkshopItem {
  id: ModId;
  title: string;
  /** Steam BBCode, written by the mod's author. Text, never markup. */
  description: string;
  /** SteamID64 as a string. */
  authorid: string;
  filesize: number;
  /** Comma-separated, possibly empty. */
  tags: string;
  /** Steam's result code; 1 is OK. */
  steamresult: number;
  childcount: number;
  /** On Steam's CDN: shown only when the operator turns thumbnails on. */
  thumbnailurl: string;
  /** Unix seconds of the last update. */
  version: number;
  /** Panel Lua only: on the ranked-mod whitelist the engine read at boot. */
  whitelisted?: boolean;
}

/**
 * `getmods`. Stock: `{loading}` or `{items}`. The panel Lua adds `elapsed` while
 * loading, and `done`, `page`, `count`, `capped` and, for a search that never
 * answered, `error` once settled.
 */
export interface RawWorkshopSearch {
  loading?: boolean;
  elapsed?: number;
  items?: RawWorkshopItem[];
  done?: boolean;
  page?: number;
  count?: number;
  capped?: boolean;
  error?: string;
}

export type RawInstallModResult =
  | { ok: true; id: ModId; already_installed: boolean }
  | { ok: false; error: string };

export interface WorkshopItem {
  id: ModId;
  title: string;
  description: string;
  authorId: string;
  fileSize: number;
  tags: string[];
  /** Steam's per-item result code; anything but 1 is a problem with the item. */
  steamResult: number;
  childCount: number;
  thumbnailUrl: string;
  /** Unix seconds, or null when the item carries none. */
  updatedAt: number | null;
  /** The engine's whitelist verdict; null on a stock server. */
  whitelisted: boolean | null;
}

export type WorkshopSearch =
  | { kind: "loading"; elapsedSeconds: number | null }
  /** At most 50 items; `capped` when there may be more than were returned. */
  | { kind: "results"; items: WorkshopItem[]; capped: boolean }
  /** Panel Lua only: the search had no answer in time. */
  | { kind: "error"; error: string };

export type InstallModResult =
  /** Mod: handed to the engine. Whether it downloads shows in the installed list. */
  | { kind: "sent"; id: ModId; alreadyInstalled: boolean }
  /** Mod: not a workshop id; nothing was sent to the engine. */
  | { kind: "refused"; error: string }
  /** Stock: an empty 200, whatever happened. */
  | { kind: "unverified" };

// ------------------------------------------------------------- performance

/** getperfdata: vanilla, one reading a minute, the last 30. */
export interface RawPerfSample {
  players: number;
  tickrate: number;
  time: number;
  ent_count: number;
}

/** getperf (panel Lua only): one 10 s window of what perfmon logs. */
export interface RawPerfWindow {
  id: number;
  time: number;
  duration_ms: number;
  ticks: number;
  tickrate: number;
  worst_tick_ms: number;
  players: number;
  score: number;
  quality: number;
  idle_pct: number;
  moves_pct: number;
  entities_pct: number;
  moves_per_s: number;
  move_ms?: number;
  entities: number;
  incomplete: number;
  interp_warns: number;
  interp_fails: number;
  lua_kb: number;
}

export interface PerfConfig {
  tickrate: number;
  moverate: number;
  sendrate: number;
  interp_ms: number;
  max_players: number;
  /** Server.GetBwLimit(), bytes a second per player. */
  bw_limit?: number;
}

/**
 * getperf's `engine`: one tickstat window, Server.GetTickStat() as the engine
 * gives it. `time` is the window's end on the server's system clock.
 */
export interface RawTickstat {
  id: number;
  time: number;
  window?: number;
  hz?: number;
  target?: number;
  intervalP50?: number;
  intervalP99?: number;
  intervalP999?: number;
  intervalMax?: number;
  latenessMax?: number;
  rearms?: number;
  stretchPct?: number;
  governorMax?: number;
  incomplete?: number;
  loops?: number;
  incompleteLate?: number;
  incompleteWriters?: number;
  incompleteMoves?: number;
  waitOverP99?: number;
  waitOverMax?: number;
  waits?: number;
  busyPct?: number;
  humans?: number;
  bots?: number;
  snapPerSecPerHuman?: number;
  bytesPerSecPerHuman?: number;
  movesPerSecPerHuman?: number;
  movesPerSecPerBot?: number;
  injectedPct?: number;
  moveMsPerTick?: number;
  specMovesPerSec?: number;
  specMoveMsPerTick?: number;
  snapBytesP50?: number;
  snapBytesP99?: number;
  snapBytesMax?: number;
  chokedPct?: number;
  humanMoveMsPerTick?: number;
  sendBufDrops?: number;
  rateStepped?: number;
  slowestSendrate?: number;
  creationsDeferred?: number;
}

/** The engine's `perfmon:` block: printed when `perfmon` is typed; the last second. */
export interface RawPerfmonBlock {
  id: number;
  time: number;
  jitter_avg_ms?: number;
  jitter_max_ms?: number;
  jitter_n?: number;
  snapshot_write_avg_ms?: number;
  snapshot_write_max_ms?: number;
  snapshot_write_n?: number;
  entities_skipped?: number;
  entities_total?: number;
  entities_skipped_pct?: number;
  rejected_time_credit?: number;
  rejected_other?: number;
  rewound_missing?: number;
  score?: number;
  idle_pct?: number;
  delivery_pct?: number;
  overload_pct?: number;
  updates?: number;
  warn?: number;
  fail?: number;
}

export type RawEngineEvent =
  /** A player's update rate stepped; `client` is a slot number. */
  | { id: number; time: number; kind: "rate"; client: number; from_rate: number;
      to_rate: number; choked_pct: number; clear_ms: number; bwlimit: number }
  /** The engine's warning that bwlimit leaves too few bytes per snapshot. */
  | { id: number; time: number; kind: "bwlimit_low"; bwlimit: number; sendrate: number;
      per_snapshot: number; needed: number; suggested: number };

export interface RawPerfEngine {
  scan_s: number;
  last_id: number;
  /** More records are held past last_id: ask again from it. Absent before paging. */
  more?: boolean;
  now: number;
  tickstat_last_at?: number;
  tickstat_said?: { text: string; time: number };
  tickstats: RawTickstat[];
  perfmon: RawPerfmonBlock[];
  events: RawEngineEvent[];
}

export interface RawPerfReport {
  window_s: number;
  capacity: number;
  loaded_at: number;
  map: string;
  config?: PerfConfig;
  windows: RawPerfWindow[];
  last_id: number;
  /** More windows are held past last_id: ask again from it. Absent before paging. */
  more?: boolean;
  /** Absent from a mod that predates it. */
  engine?: RawPerfEngine;
}

/** An engine record with `at`, milliseconds, beside its raw `time`. */
export type Tickstat = RawTickstat & { at: number };
export type PerfmonBlock = RawPerfmonBlock & { at: number };
export type EngineEvent = RawEngineEvent & { at: number };

export interface PerfEngine {
  scanSeconds: number;
  lastId: number;
  /** The reply is one page: more records are held past lastId. */
  more: boolean;
  /** The server's clock at the reply, milliseconds. */
  now: number;
  /** When the newest TICKSTAT line was found, milliseconds; null if none since the map load. */
  tickstatLastAt: number | null;
  /** The last `tickstat: on|off` the command printed, if seen since the map load. */
  tickstatSaid: { text: string; at: number } | null;
  tickstats: Tickstat[];
  perfmon: PerfmonBlock[];
  events: EngineEvent[];
}

/**
 * A point on the Performance tab's charts, from either source. Times are
 * milliseconds. Fields only the panel Lua reports are null on a stock server.
 */
export interface PerfPoint {
  /** getperf's window id; null for a vanilla sample. */
  id: number | null;
  /** When the window closed, or the sample was taken. */
  at: number;
  durationMs: number | null;
  tickrate: number;
  worstTickMs: number | null;
  players: number;
  score: number | null;
  quality: number | null;
  idlePct: number | null;
  movesPct: number | null;
  entitiesPct: number | null;
  movesPerSecond: number | null;
  moveMs: number | null;
  entities: number;
  incomplete: number | null;
  interpWarns: number | null;
  interpFails: number | null;
  luaKb: number | null;
}

export interface PerfReport {
  windowSeconds: number;
  capacity: number;
  /** Milliseconds. Changes at every map load, when the ids restart. */
  loadedAt: number;
  map: string;
  config: PerfConfig | null;
  points: PerfPoint[];
  lastId: number;
  /** The reply is one page: more windows are held past lastId. */
  more: boolean;
  /** Null from a mod that predates it. */
  engine: PerfEngine | null;
}

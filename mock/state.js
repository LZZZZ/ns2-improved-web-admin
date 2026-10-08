// The Lua half of the mock: server state, the request types, and the console
// commands. This is what `lua/ServerWebInterface.lua` does, plus enough of
// `ServerAdminCommands.lua` for the panel's buttons to have somewhere to land.
//
// It reproduces the vanilla bugs on purpose -- see BUGS below. The whole point
// of the mock is that the *shipped* 2012 panel runs against it unmodified, and
// the shipped panel is written against a server that has those bugs.

import { readFileSync } from "node:fs";
import { join } from "node:path";

// Vanilla defects the mock reproduces. Each can be switched off individually so
// the mod's Lua fixes can be developed against a mock that has them fixed.
// See docs/CONSTRAINTS.md "Lua changes the mod ships".
export const BUGS = {
  // Item 7: SetReservedSlotAmount(actions.amount) hits a (client, amount)
  // signature, so the amount lands in `client` and nothing happens.
  setreservedslotamount: true,
  // Item 8: UnbanUser gets the raw string argument while bannedPlayersMap is
  // keyed by number, so sv_unban never matches.
  unban: true,
  // Item 9: expired bans are never pruned from getbanlist.
  banPruning: true,
  // Item 1: console commands return nothing at all -- no output, no error.
  silentCommands: true,
};

const kMaxPerfDatas = 30; // ServerWebInterface.lua:11
// Server.lua:74. The mod keeps a ring of its own, of 200, with times.
const kMaxChat = 20;
const kModChatBufferSize = 200;

const clone = (v) => JSON.parse(JSON.stringify(v));

// Tickrates cross the wire as float32 widened back to a double, which is why
// real captures read 29.966260910034 rather than 29.96626. Worth matching: a
// client that formats these has to cope with the long tail either way.
const f32 = new Float32Array(1);
const float32 = (v) => { f32[0] = v; return f32[0]; };

// The fixture's readings, a minute apart, moved so the newest is now: a live
// server's window is always the last half hour, not the capture's.
function rebasePerf(samples) {
  const last = samples[samples.length - 1]?.time ?? 0;
  const shift = Math.floor(Date.now() / 1000) - last;
  return samples.map((p) => ({ ...p, time: p.time + shift }));
}

export function createState(fixturesDir, opts = {}) {
  // --mod means the server is running this repo's lua/, which fixes all three
  // of these. Leaving them on there would mock a server that does not exist:
  // you cannot have the mod's request types and its bugs at the same time.
  // An explicit --fix still wins, since it is the more specific flag.
  const modFixes = opts.mod
    ? { setreservedslotamount: false, unban: false, banPruning: false }
    : {};
  const bugs = { ...BUGS, ...modFixes, ...(opts.bugs || {}) };
  const log = opts.log || (() => {});
  const fx = (name) =>
    JSON.parse(readFileSync(join(fixturesDir, `${name}.json`), "utf8"));

  // --maps=modded: a modded server's cycle, captured on the rig -- 22 global mods,
  // per-map mods, a Shine per-map option and a map group -- with its map list
  // and installed mods. The default is a stock install's.
  const modded = opts.maps === "modded";

  const base = fx("serverstate-populated");
  const bootedAt = Date.now();

  const s = {
    // Everything GetServerState() reports, minus the fields recomputed per call.
    server_name: base.server_name,
    map: base.map || "ns2_summit",
    webdomain: opts.webdomain || "127.0.0.1",
    webport: String(opts.port || 8080),
    cheats: base.cheats,
    devmode: base.devmode,
    marine_res: base.marine_res,
    alien_res: base.alien_res,
    game_started: base.game_started,
    gameStartedAt: base.game_started ? bootedAt : null,
    players: clone(base.player_list),

    bans: clone(fx("getbanlist-populated")),
    reserved: clone(fx("getreservedslots")),
    // Fixture entries carry no time; give them the boot's.
    chat: clone(fx("getchatlist-player")).map((e) => ({ ...e, time: Math.floor(bootedAt / 1000) })),
    chatDropped: 0,
    perf: rebasePerf(clone(fx("getperfdata-populated"))),
    installedMods: clone(fx(modded ? "getinstalledmodslist-modded" : "getinstalledmodslist")),
    mapList: clone(fx(modded ? "getmaplist-modded" : "getmaplist")),
    // MapCycle.json, with mod ids as numbers the way the file holds them. The
    // game also keeps the copy it loaded with the map, `mapCycleMemory`: a
    // stock getmapcycle answers from that one, and only a map change reloads
    // it from the file (docs/CONSTRAINTS.md item 13).
    mapCycle: modIdsFromHex(clone(fx(modded ? "getmapcycle-shine-options" : "getmapcycle"))),

    // What the workshop search finds: a real page of results, plus a few made
    // up to have a small result, a map mod and a description with markup.
    catalogue: [...clone(fx("getmods-settled").items || []), ...syntheticWorkshopItems()],
  };

  s.mapCycleMemory = clone(s.mapCycle);

  // What is mounted, fixed when the map loads (measured on the rig, 09-26):
  // the two hotfix mods the engine downloads itself, mounted with no cycle
  // entry; the cycle's global mods; and the loaded map's own mods, which drop
  // out again at the next map. Ids as the engine spells them, hex. A cycle
  // edit changes none of it until the next map change.
  const kAlwaysMounted = ["acd4ecf3", "d41d68cd"];   // NSL Badges, UWE Hotfix 344
  const mountMods = () => {
    const cycle = modIdsToHex(clone(s.mapCycle));
    const entry = (cycle.maps ?? []).find((e) => typeof e === "object" && e?.map === s.map);
    s.activeMods = [...kAlwaysMounted, ...(cycle.mods ?? []), ...(entry?.mods ?? [])]
      .map((m) => String(m).toLowerCase());
  };
  mountMods();

  // getmods caches a completed search for 60 s keyed by searchtext..page, and
  // answers {"loading": true} until the search lands. Modelled with a timer so
  // the panel's poll loop has something real to poll. (API.md, "getmods is
  // asynchronous".) What the engine does, measured on 09-26: at most 50 hits,
  // the page ignored, and an empty table both for no matches and for a search
  // Steam failed. /__mock/workshop makes the next search hang or fail, and the
  // next install one that never arrives.
  const modSearches = new Map();
  const kWorkshopLimit = 50;
  let workshopTimeoutS = 30;
  const workshopNext = { search: null, searches: 0, install: null };
  const kModVersion = "0.1.0";

  // ------------------------------------------------------------- whitelist

  // request=getwhitelist (--mod): the ranked-mod whitelist as the mod's
  // GetWhitelist() serves it (docs/CONSTRAINTS.md item 17). The list is the rig's read from
  // Steam. With no copy, the first request starts a read and answers
  // `fetching`; a read lands after --whitelist-delay, or fails with
  // --whitelist=fail and is not tried again for 5 minutes. A copy older than
  // an hour is read again, and served meanwhile.
  const wlFixture = fx("getwhitelist-rig");
  const wl = {
    copy: opts.whitelist === "cached"
      ? { readAt: Math.floor(bootedAt / 1000) - 600,
          whitelist: wlFixture.whitelist, hotfix: wlFixture.hotfix }
      : null,
    fetchingSince: null,
    error: null,
    errorAt: null,
  };
  const kWhitelistMaxAgeS = 60 * 60;
  const kWhitelistRetryS = 5 * 60;
  const getWhitelist = () => {
    const now = Math.floor(Date.now() / 1000);
    const stale = !wl.copy || now - wl.copy.readAt >= kWhitelistMaxAgeS;
    const resting = wl.errorAt !== null && now - wl.errorAt < kWhitelistRetryS;
    if (stale && wl.fetchingSince === null && !resting) {
      wl.fetchingSince = now;
      setTimeout(() => {
        wl.fetchingSince = null;
        if (opts.whitelist === "fail") {
          wl.error = "Steam could not be reached: Could not resolve host: steamcommunity.com";
          wl.errorAt = Math.floor(Date.now() / 1000);
          log(`webadmin-spa: whitelist not read: ${wl.error}`);
          return;
        }
        wl.error = null;
        wl.errorAt = null;
        wl.copy = { readAt: Math.floor(Date.now() / 1000),
                    whitelist: wlFixture.whitelist, hotfix: wlFixture.hotfix };
      }, opts.whitelistDelayMs ?? 1500);
    }
    return {
      now,
      hotfix_list_id: wlFixture.hotfix_list_id,
      branch: wlFixture.branch,
      whitelist_id: wlFixture.whitelist_id,
      fetching: wl.fetchingSince !== null,
      ...(wl.error ? { error: wl.error } : {}),
      ...(wl.copy ? { read_at: wl.copy.readAt, whitelist: wl.copy.whitelist,
                      hotfix: wl.copy.hotfix } : {}),
    };
  };

  // Server.GetMaxPlayers(). The reserved slot amount cannot exceed it.
  const maxPlayers = opts.maxPlayers ?? 16;

  // --------------------------------------------------------- recent players

  // request=getrecentplayers (--mod): what the mod's GetRecentPlayers()
  // builds. Seeded from a synthetic fixture -- a real one is player data --
  // with its times moved to sit where they did relative to "now", plus every
  // human connected now. A player the mock removes (kick, ban, map change)
  // stays in the list, no longer connected. The two save slots are the Lua's
  // business; /__mock/recent-load forces what the load reports.
  const kRecentWindow = 24 * 60 * 60;
  const kRecentCapacity = 100;
  const kRecentFormerNames = 5;
  const unixNow = () => Math.floor(Date.now() / 1000);
  const recent = new Map();
  const joinedAt = new Map();   // steamid -> when this session started
  const recentSeed = fx("getrecentplayers");
  {
    const delta = Math.floor(bootedAt / 1000) - recentSeed.now;
    for (const r of recentSeed.players) {
      recent.set(r.steamid, {
        ...clone(r), first_seen: r.first_seen + delta, last_seen: r.last_seen + delta,
      });
    }
  }
  let recentStorage = { loaded: "ok", saved_at: Math.floor(bootedAt / 1000) };

  const isHuman = (p) => p.isbot !== "true" && p.steamid !== 0;

  function seeConnected(now) {
    for (const p of s.players) {
      if (!isHuman(p)) continue;
      if (!joinedAt.has(p.steamid)) joinedAt.set(p.steamid, now);
      let e = recent.get(p.steamid);
      if (!e) {
        e = { steamid: p.steamid, name: "", names: [], ipaddress: "",
              first_seen: now, last_seen: now, played: 0 };
        recent.set(p.steamid, e);
      }
      if (p.name && p.name !== e.name) {
        if (e.name) {
          e.names = [e.name, ...e.names.filter((n) => n !== e.name && n !== p.name)]
            .slice(0, kRecentFormerNames);
        }
        e.name = p.name;
      }
      if (p.ipaddress) e.ipaddress = p.ipaddress;
      e.last_seen = now;
    }
  }

  // Takes players off the server, and closes their session in the list.
  function leave(...players) {
    const now = unixNow();
    seeConnected(now);
    for (const p of players) {
      const e = recent.get(p.steamid);
      if (e && joinedAt.has(p.steamid)) {
        e.played += now - joinedAt.get(p.steamid);
        e.last_seen = now;
      }
      joinedAt.delete(p.steamid);
    }
    s.players = s.players.filter((x) => !players.includes(x));
  }

  function recentPlayers() {
    const now = unixNow();
    seeConnected(now);
    const connected = new Set(s.players.filter(isHuman).map((p) => p.steamid));
    const kept = [...recent.values()]
      .filter((e) => connected.has(e.steamid) || now - e.last_seen <= kRecentWindow)
      .sort((a, b) => (connected.has(b.steamid) - connected.has(a.steamid))
        || b.last_seen - a.last_seen || a.steamid - b.steamid)
      .filter((e, i) => i < kRecentCapacity || connected.has(e.steamid));
    recent.clear();
    for (const e of kept) recent.set(e.steamid, e);
    const players = kept
      .map((e) => ({
        ...clone(e),
        played: e.played + (connected.has(e.steamid) ? now - joinedAt.get(e.steamid) : 0),
        connected: connected.has(e.steamid),
      }))
      .sort((a, b) => b.last_seen - a.last_seen || a.steamid - b.steamid);
    return {
      now, window: kRecentWindow, capacity: kRecentCapacity,
      storage: clone(recentStorage), players,
    };
  }

  // ------------------------------------------------------------------ Shine

  // --shine: Shine loaded, with the plugins named on. Which plugins are on
  // decides who owns bans and reserved slots; see docs/CONSTRAINTS.md "Shine".
  const shine = opts.shine ?? null;
  const shineHas = (plugin) => Boolean(shine && shine.has(plugin));
  // basecommands' `Gagged`, by Steam id: Lua state, so a map change clears it.
  const shineGagged = new Set();

  // The ban plugin's own table, `Config.Banned`, keyed by *string* id. Seeded
  // from a synthetic getbans capture -- the only real one is production data --
  // with its times moved so they sit where they did relative to "now". The
  // 6e+24 expiry comes back the way Shine makes it: issued plus a huge
  // duration.
  const shineBans = new Map();
  let shineSlots = 2;   // reservedslots' DefaultConfig
  if (shine) {
    const seed = fx("getbans-shine");
    const delta = Math.floor(bootedAt / 1000) - seed.now;
    for (const b of seed.bans) {
      const issued = b.issued + delta;
      shineBans.set(String(b.id), {
        ID: String(b.id), Name: b.name, Reason: b.reason,
        Duration: b.duration, Issued: issued,
        UnbanTime: b.duration === 0 ? 0 : issued + b.duration,
        BannedBy: b.banned_by, BannerID: 0,
      });
    }
  }

  // Shine's mapvote reads the cycle's maps once, at plugin start -- boot or a
  // map change -- so an edit reaches the vote only at the next map (measured
  // on the rig, docs/CONSTRAINTS.md item 13). The config measured:
  // GetMapsFromMapCycle true, RoundLimit 2.
  const mapName = (entry) => (typeof entry === "string" ? entry : entry?.map);
  let voteOptions = [];
  const startMapVote = () => {
    voteOptions = (s.mapCycle.maps ?? []).map(mapName).filter((m) => typeof m === "string");
  };
  startMapVote();

  // Plugin:GetNextMap (mapvote/cycle.lua:451) with no vote winner: the first
  // option after the last occurrence of the current map, wrapping round.
  function nextVoteMap() {
    let index = -1;
    for (let i = voteOptions.length - 1; i >= 0; i--) {
      if (voteOptions[i] === s.map) { index = i; break; }
    }
    const rest = [...voteOptions.slice(index + 1), ...voteOptions.slice(0, Math.max(index, 0))];
    return rest[0] ?? null;
  }

  // Perf samples accrue on a timer, one every kLogPerfDataRate seconds.
  const perfEvery = (opts.perfRateSeconds ?? 60) * 1000;
  const perfTimer = setInterval(() => {
    s.perf.push({
      ent_count: 140 + Math.floor(Math.random() * 30),
      players: s.players.length,
      tickrate: float32(29.5 + Math.random()),
      time: Math.floor(Date.now() / 1000),
    });
    while (s.perf.length > kMaxPerfDatas) s.perf.shift();
  }, perfEvery);
  perfTimer.unref?.();

  // request=getperf (--mod): the mod's 10 s performance windows. The Lua keeps
  // an hour of them from the map load, with ids from 1, and a map change starts
  // over with a new loaded_at. Here they are made up, in the shape the rig
  // returned (fixtures/getperf-rig.json), and seeded with half an hour of
  // history so the chart has something to draw at once. --perf-window sets the
  // window length; /__mock/perf forces the next window's values.
  const kPerfCapacity = 360;
  // getperf's page: at most this many windows, and as many engine records,
  // from the cursor, with `more` until caught up (kPerfReplyMax in the Lua).
  const kPerfReplyMax = 60;
  const perfWindowS = opts.perfWindowSeconds ?? 10;
  const perfConfig = { tickrate: 60, moverate: 60, sendrate: 60, interp_ms: 85,
                       max_players: maxPlayers, bw_limit: 131072 };
  let perfWin = null;
  let perfForced = null;
  const perfWindow = (at, id) => {
    const players = s.players.length;
    const busy = players / 16;
    const hitch = Math.random() < 0.05;
    const w = {
      id,
      time: at,
      duration_ms: perfWindowS * 1000 + Math.floor(Math.random() * 30),
      ticks: 0,
      tickrate: Math.round((59.7 + Math.random() * 0.4 - (hitch ? 1.5 : 0)) * 100) / 100,
      worst_tick_ms: Math.round((hitch ? 40 + Math.random() * 40 : 17 + Math.random() * 6) * 10) / 10,
      players,
      score: players ? Math.round(45 - 25 * busy + Math.random() * 6) : 0,
      quality: players ? Math.round(80 + Math.random() * 15) : 0,
      idle_pct: Math.round((80 - 35 * busy + Math.random() * 4) * 10) / 10,
      moves_pct: Math.round((25 * busy + Math.random() * 2) * 10) / 10,
      entities_pct: Math.round((3 + 12 * busy + Math.random() * 2) * 10) / 10,
      moves_per_s: Math.round(players * 60 * (0.95 + Math.random() * 0.05)),
      entities: Math.round(160 + 700 * busy + Math.random() * 40),
      incomplete: 0,
      interp_warns: 0,
      interp_fails: 0,
      lua_kb: Math.round(20000 + 30000 * busy + Math.random() * 4000),
    };
    if (players) w.move_ms = Math.round((0.15 + Math.random() * 0.05) * 1000) / 1000;
    if (perfForced) { Object.assign(w, perfForced); perfForced = null; }
    w.ticks = Math.round(w.tickrate * w.duration_ms / 1000);
    return w;
  };
  const pushPerfWindow = () => {
    const w = perfWindow(unixNow(), perfWin.nextId++);
    perfWin.windows.push(w);
    while (perfWin.windows.length > kPerfCapacity) perfWin.windows.shift();
  };
  const loadPerf = (seed) => {
    const now = unixNow();
    const n = seed ? Math.min(180, Math.floor(1800 / perfWindowS)) : 0;
    perfWin = { loadedAt: now - n * perfWindowS, nextId: 1, windows: [] };
    for (let i = n; i > 0; i--) {
      perfWin.windows.push(perfWindow(now - (i - 1) * perfWindowS, perfWin.nextId++));
    }
  };
  loadPerf(true);
  const perfWindowTimer = setInterval(pushPerfWindow, perfWindowS * 1000);
  perfWindowTimer.unref?.();

  const uptimeMinutes = () => Math.floor((Date.now() - bootedAt) / 60000);

  const wireBool = (v) => (opts.mod ? v === "true" : v);

  // --beta-players: what the 09-26+ engine adds per player, made up. The
  // first human plays a Family Shared copy and has had moves rejected; bots
  // read as not shared, as the engine's CHANGELOG says they always do.
  function betaPlayer(p) {
    const firstHuman = s.players.find(isHuman);
    if (firstHuman && p.steamid === firstHuman.steamid) {
      return { familyshared: true, owner_steamid: 10000042,
               moves_rejected_time: 37, moves_rejected_other: 2 };
    }
    return { familyshared: false, moves_rejected_time: 0, moves_rejected_other: 0 };
  }

  // The game's GetPlayerSkillTier (NS2Utility.lua): 0 for a rookie, else
  // the skill less 25/sqrt(adagrad sum), the server's uncertainty, banded.
  function skillTier(skill, isRookie, adagradSum) {
    if (isRookie) return 0;
    const capped = adagradSum <= 0 ? 0 : Math.max(skill - 25 / Math.sqrt(adagradSum), 0);
    const tops = [300, 750, 1400, 2100, 2900, 4100];
    const i = tops.findIndex((top) => capped <= top);
    return i < 0 ? 7 : i + 1;
  }

  // The mod's Hive skill per player, made up but stable: from the Steam id.
  // Bots report -1 in all four, as on the rig (P1, 2026-10-07), and tier -1,
  // as GetSkillTier() gives a virtual client. The level and adagrad sum the
  // tier comes from stay on the server, as they do on the real one.
  function skillOf(p) {
    if (!isHuman(p)) {
      return { skill: -1, skill_offset: -1, comm_skill: -1, comm_skill_offset: -1, skill_tier: -1 };
    }
    const n = Number(p.steamid);
    const skill = 800 + (n * 37) % 2600;
    return { skill, skill_offset: (n % 7) * 25 - 75,
             comm_skill: 500 + (n * 53) % 2200, comm_skill_offset: (n % 5) * 20 - 40,
             skill_tier: skillTier(skill, n % 11 === 3, 0.04 + (n % 13) / 10) };
  }

  function serverState() {
    const marines = s.players.filter((p) => p.team === 1).length;
    const aliens = s.players.filter((p) => p.team === 2).length;
    return {
      webdomain: s.webdomain,
      webport: s.webport,
      server_name: s.server_name,
      map: s.map,
      uptime: uptimeMinutes(),
      // Stock stringifies these three; the mod sends real booleans
      // (CONSTRAINTS item 4). State keeps the stock strings.
      cheats: wireBool(s.cheats),
      devmode: wireBool(s.devmode),
      players_online: s.players.length,
      marines,
      aliens,
      marine_res: s.marine_res,
      alien_res: s.alien_res,
      // A stock rig runs the default 30. The --mod mock runs at getperf's
      // configured rate (60, not the stock 30), so the header and the
      // Performance tab agree and nothing gets away with assuming 30.
      frame_rate: float32((opts.mod ? perfConfig.tickrate : 30) - 0.5 + Math.random()),
      game_started: s.game_started,
      game_time: s.gameStartedAt
        ? Math.floor((Date.now() - s.gameStartedAt) / 1000)
        : 0,
      player_list: clone(s.players).map((p) => ({
        ...p,
        isbot: wireBool(p.isbot),
        // The mod reads Shine's gags under basecommands, and only then.
        ...(opts.mod && shineHas("basecommands") ? { gagged: shineGagged.has(p.steamid) } : {}),
        ...(opts.mod && opts.betaPlayers ? betaPlayer(p) : {}),
        ...(opts.mod ? skillOf(p) : {}),
      })),
      // Absent on a stock server, which is how the panel knows which it is
      // talking to and what it can honestly offer.
      ...(opts.mod ? {
        mod_version: kModVersion, max_players: maxPlayers, map_loaded_at: perfWin.loadedAt,
        // Unranked, as any server with this mod mounted is until it is
        // whitelisted (CONSTRAINTS item 18).
        ranking_active: false,
      } : {}),
      // Also the mod's: absent when Shine is not loaded.
      ...(opts.mod && shine ? {
        shine: {
          ban: shineHas("ban"),
          reservedslots: shineHas("reservedslots"),
          mapvote: shineHas("mapvote"),
          basecommands: shineHas("basecommands"),
        },
      } : {}),
    };
  }

  function findPlayer(steamid) {
    // GetPlayerMatching resolves by SteamID. Bots report 0, which matches
    // nothing -- CURRENT-UI.md defect 7, and the mock has to reproduce it or
    // the panel's bot buttons would appear to work.
    const id = Number(steamid);
    if (!Number.isFinite(id) || id === 0) return null;
    return s.players.find((p) => p.steamid === id) || null;
  }

  // Server.AddChatToHistory: the game's ring of 20, and under --mod the mod's
  // ring of 200 recording the same calls. One array serves both.
  function addChat(message, { player = opts.adminName || "Admin", team = 0, teamOnly = false, steamId = 0, tee = true } = {}) {
    const id = (s.chat.at(-1)?.id ?? 0) + 1;
    s.chat.push({ message, teamOnly, player, id, team, steamId, time: Math.floor(Date.now() / 1000) });
    while (s.chat.length > (opts.mod ? kModChatBufferSize : kMaxChat)) {
      s.chat.shift();
      s.chatDropped++;
    }
    // Chat is written to the server log through Shared.Message, so with the
    // mod's wrappers it lands in the console buffer as well. Measured on the
    // rig: `Chat All - Admin: <text>`.
    if (opts.mod && tee) {
      teeConsole("server", `Chat ${teamOnly ? "Team" : "All"} - ${player}: ${message}`);
    }
  }

  // -------------------------------------------------------------- server log

  // log-Server.txt, for request=getlog (--mod). The real file is written by
  // the engine and read by the mod's Lua through config://, which works when
  // -logdir is the config directory (docs/REQUIREMENTS.md item 7); --log=off
  // is a server where it is not. Here it is a Buffer: a header, a boot and
  // rounds of made-up history from log-seed.txt (fake names, 0.0.0.0), then
  // every line the console prints, a map change's loading lines and the
  // engine's Script tracing pair every 30 s. Offsets are bytes, as on the
  // server: a name with an accent is longer in bytes than in characters.
  // clearconsole does nothing to it (measured: a client command).
  const kLogPath = "config://log-Server.txt";
  const kLogTailBytes = 64 * 1024;
  const kLogMaxBytes = 64 * 1024;   // the Lua's, since 2026-10-08
  const kLogRoundSeconds = 300;
  let logFile = Buffer.alloc(0);
  let logBootAt = 0;

  const pad2 = (n) => String(n).padStart(2, "0");
  // The engine's own header, in the server's local time.
  function logHeader(at) {
    const d = new Date(at);
    const h = d.getHours() % 12 || 12;
    return `Date: ${pad2(d.getMonth() + 1)}/${pad2(d.getDate())}/${d.getFullYear()}\n`
      + `Time: ${pad2(h)}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())} `
      + `${d.getHours() < 12 ? "AM" : "PM"}:\nBuild: 344 (9beedad4ba beta)\n`
      + `${"-".repeat(62)}\n`;
  }
  // `[ 23.062]`: seconds since boot, as the engine stamps its own lines.
  const engineStamp = (at) => `[${((at - logBootAt) / 1000).toFixed(3).padStart(7)}]`;
  const shineClock = (at) => {
    const d = new Date(at);
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
  };
  const logWrite = (text) => { logFile = Buffer.concat([logFile, Buffer.from(text, "utf8")]); };
  const logLine = (text) => logWrite(`${text}\n`);

  // A new file, as a restart makes it: `rounds` of history behind it.
  function newLogFile(rounds) {
    const seed = readFileSync(new URL("./log-seed.txt", import.meta.url), "utf8");
    const [boot, round = ""] = seed.split("@@ round @@\n");
    const now = Date.now();
    logBootAt = now - (rounds * kLogRoundSeconds + 60) * 1000;
    let at = logBootAt;
    const fill = (text) => text.split("\n").map((l) => {
      at += 200;
      return l.replaceAll("{t}", engineStamp(at).slice(1, -1)).replaceAll("{clock}", shineClock(at));
    }).join("\n");
    logFile = Buffer.from(logHeader(logBootAt) + fill(boot), "utf8");
    for (let i = 0; i < rounds; i++) {
      at = logBootAt + (60 + i * kLogRoundSeconds) * 1000;
      logWrite(fill(round));
    }
  }
  newLogFile(opts.logRounds ?? 40);

  const logTracing = setInterval(() => {
    const t = engineStamp(Date.now());
    logLine(`${t} Main : Script tracing: 212.4 ms compiling Lua traces over the last 30 s, `
      + `worst frame 3.81 ms, 2 frame(s) hit the 3.00 ms limit.`);
    logLine(`${t} Main : Script tracing aborts: 301 over the last 30 s (BLACKL x190, `
      + `TRACEOV x61, TRACEUV x50), 4 bytecode(s) blacklisted for good.`);
  }, 30000);
  logTracing.unref?.();

  // The mod's getlog, step for step: complete lines only, each with its byte
  // offset; the header's Date and Time name the file.
  function logLinesOf(buf, from) {
    const lines = [];
    let pos = 0;
    for (;;) {
      const nl = buf.indexOf(10, pos);
      if (nl < 0) break;
      const end = nl > pos && buf[nl - 1] === 13 ? nl - 1 : nl;
      lines.push({ off: from + pos, text: buf.toString("utf8", pos, end) });
      pos = nl + 1;
    }
    return [lines, from + pos];
  }
  function logFileId() {
    const m = /^Date: ([^\r\n]*)\r?\nTime: ([^\r\n]*?):?\r?\n/
      .exec(logFile.toString("latin1", 0, 128));
    return m ? `${Buffer.from(m[1], "latin1").toString()} ${Buffer.from(m[2], "latin1").toString()}` : "";
  }
  // Lua's tonumber, for what a query string can carry: "" is nil, not 0.
  const luaNumber = (v) => {
    if (v === undefined || String(v).trim() === "") return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };
  // The mod checks once per map load that the file is the one the engine is
  // writing, by printing a line and looking for it; a copy an earlier run left
  // in the config directory never grows. `logStale` is that case.
  let logChecked = false;
  let logStale = false;
  function getLog(actions) {
    if (opts.logOff) {
      return { source: "none", path: kLogPath,
               error: `${kLogPath}: No such file or directory` };
    }
    if (!logChecked) {
      logChecked = true;
      if (!logStale) {
        logLine(`webadmin-spa: checking that ${kLogPath} is this server's log `
          + `(${Date.now() % 1000000})`);
      }
    }
    if (logStale) {
      return { source: "none", path: kLogPath, stale: true,
               error: "the file does not grow: a line this server printed did not reach it" };
    }
    const size = logFile.length;
    const fileId = logFileId();
    const since = luaNumber(actions.since);
    const before = luaNumber(actions.before);
    const wanted = since ?? before;
    let reset;
    if (wanted !== null && actions.file !== undefined && actions.file !== fileId) reset = "new_file";
    else if (wanted !== null && (wanted > size || wanted < 0)) reset = "truncated";

    let from, to, lines, more = false;
    if (since !== null && !reset) {
      from = Math.floor(since);
      const stop = Math.min(size, from + kLogMaxBytes);
      const text = logFile.subarray(from, stop);
      [lines, to] = logLinesOf(text, from);
      if (to === from && stop === from + kLogMaxBytes) {
        lines = [{ off: from, text: text.toString("utf8") }];
        to = stop;
      }
      more = to < size && stop < size;
    } else if (before !== null && !reset) {
      to = Math.floor(before);
      from = Math.max(0, to - kLogTailBytes);
      let text = logFile.subarray(from, to);
      if (from > 0) {
        const nl = text.indexOf(10);
        if (nl < 0) lines = [{ off: from, text: text.toString("utf8") }];
        else { from += nl + 1; text = text.subarray(nl + 1); }
      }
      lines ??= logLinesOf(text, from)[0];
    } else {
      from = Math.max(0, size - kLogTailBytes);
      let text = logFile.subarray(from, size);
      if (from > 0) {
        const nl = text.indexOf(10);
        if (nl < 0) { from = size; text = Buffer.alloc(0); }
        else { from += nl + 1; text = text.subarray(nl + 1); }
      }
      [lines, to] = logLinesOf(text, from);
    }
    return {
      source: "file", path: kLogPath, file_id: fileId, size, from, to, lines,
      more, at_start: from === 0, ...(reset ? { reset } : {}),
      tail_bytes: kLogTailBytes, max_bytes: kLogMaxBytes,
    };
  }

  // ----------------------------------------------------- engine log lines

  // getperf's `engine` (--mod): what the 09-27 engine prints only to the log,
  // as the mod's scan of it finds it (docs/REQUIREMENTS.md item 10). The
  // engine side is emulated too: `tickstat N` writes a TICKSTAT line every N s
  // until `tickstat 0` and survives a map change; a bare `tickstat` reports
  // on or off; `perfmon` prints its block; a bwlimit too small for a full
  // game prints the engine's warning. None of it passes through Lua, so
  // runcommand gets no lines for these commands, as on the real server.
  // --tickstat <s> boots with it on and half an hour of it behind.
  // /__mock/tickstat forces the next line's values or a rate step.
  const kEngineScanS = 2;
  const kMaxTickstats = 360;
  let engine = null;
  let tickstatEvery = 0;
  let tickstatTimer = null;
  let tickstatForced = null;
  // Vanilla perfmon's level, which each `perfmon` steps whatever follows it:
  // off, basic, detailed, spam (ServerPerformanceData.lua, measured on 09-27).
  let perfmonLevel = 0;
  const round = (v, p = 2) => Math.round(v * 10 ** p) / 10 ** p;

  function resetEngine() {
    engine = { nextId: 1, tickstats: [], perfmon: [], events: [], said: null, lastAt: null };
  }
  const engineRecord = (fields, at = unixNow()) => ({ id: engine.nextId++, time: at, ...fields });

  // One TICKSTAT record from the mock's players and rates.
  function tickstatRecord(win, at) {
    const humans = s.players.filter(isHuman).length;
    const bots = s.players.length - humans;
    const target = perfConfig.tickrate;
    const busy = s.players.length / 16;
    const p99 = Math.round(300 + 60 * s.players.length + Math.random() * 200);
    const budget = Math.floor((perfConfig.bw_limit ?? 131072) / perfConfig.sendrate);
    const i99 = 1000 / target + 1.5 + Math.random();
    const i999 = i99 + Math.random() * 3;
    const r = {
      win_s: win, hz: round(target - Math.random() * 0.05), target,
      int_p50_ms: round(1000 / target), int_p99_ms: round(i99),
      int_p999_ms: round(i999), int_max_ms: round(i999 + Math.random() * 2),
      late_max_ms: round(1 + Math.random() * 2), rearm: 0, stretch_pct: 0, gov_max: 0,
      incomplete: 0, incomplete_of: Math.round(target * win * 3), late: 0, writers: 0, moves: 0,
      wait_p99_ms: 2.06, wait_max_ms: round(2.05 + Math.random() * 0.2),
      wait_n: Math.round(target * win * 2.5),
      busy_pct: round(18 + 20 * busy + Math.random() * 3, 1), humans, bots,
      snaps_per_s_human: humans ? round(perfConfig.sendrate - Math.random() * 0.1) : 0,
      bytes_per_s_human: humans ? Math.round(perfConfig.sendrate * p99 * 0.4) : 0,
      moves_per_s_human: humans ? round(perfConfig.moverate - Math.random() * 0.1) : 0,
      moves_per_s_bot: bots ? round(target - Math.random() * 0.1) : 0, injected_pct: 0,
      move_ms_tick: round(bots * 0.12, 3), spec_moves_per_s: 0, spec_move_ms_tick: 0,
      snap_p50_bytes: humans ? Math.round(p99 / 2) : 0, snap_p99_bytes: humans ? p99 : 0,
      snap_max_bytes: humans ? Math.round(p99 * 3) : 0,
      choked_pct: humans && p99 > budget ? round(Math.min(40, (p99 / budget - 1) * 30)) : 0,
      human_move_ms_tick: round(humans * 0.06, 3), sendbuf_drops: 0, rate_stepped: 0,
      slowest_rate: 0, creations_deferred: 0,
    };
    if (tickstatForced) { Object.assign(r, tickstatForced); tickstatForced = null; }
    return engineRecord({ ...r, unparsed: 0 }, at);
  }
  // The line as the engine writes it, from a record.
  const f2 = (v) => Number(v).toFixed(2);
  function tickstatLine(r) {
    return `TICKSTAT| win ${Number(r.win_s).toFixed(1)} s hz ${f2(r.hz)} target ${r.target}`
      + ` | int p50 ${f2(r.int_p50_ms)} p99 ${f2(r.int_p99_ms)} p999 ${f2(r.int_p999_ms)} max ${f2(r.int_max_ms)} ms`
      + ` | late max ${f2(r.late_max_ms)} ms rearm ${r.rearm} stretch ${f2(r.stretch_pct)}% gov max ${r.gov_max}`
      + ` | incomplete ${r.incomplete}/${r.incomplete_of} late ${r.late} writers ${r.writers} moves ${r.moves}`
      + ` | wait over p99 ${f2(r.wait_p99_ms)} max ${f2(r.wait_max_ms)} ms (n=${r.wait_n})`
      + ` | busy ${Number(r.busy_pct).toFixed(1)}% | humans ${r.humans} bots ${r.bots}`
      + ` | snap/s/human ${f2(r.snaps_per_s_human)} bytes/s/human ${Math.round(r.bytes_per_s_human)}`
      + ` | moves/s/human ${f2(r.moves_per_s_human)} moves/s/bot ${f2(r.moves_per_s_bot)} injected ${f2(r.injected_pct)}%`
      + ` | move ms/tick ${Number(r.move_ms_tick).toFixed(3)}`
      + ` | spec moves/s ${f2(r.spec_moves_per_s)} spec move ms/tick ${Number(r.spec_move_ms_tick).toFixed(3)}`
      + ` | snap bytes p50 ${Math.round(r.snap_p50_bytes)} p99 ${Math.round(r.snap_p99_bytes)} max ${r.snap_max_bytes} choked ${f2(r.choked_pct)}%`
      + ` | human move ms/tick ${Number(r.human_move_ms_tick).toFixed(3)} | sendbuf drops ${r.sendbuf_drops}`
      + ` | rate stepped ${r.rate_stepped} slowest ${Number(r.slowest_rate).toFixed(1)}/s`
      + ` | creations deferred ${r.creations_deferred}`;
  }
  function pushTickstat(win = tickstatEvery, at = unixNow()) {
    const r = tickstatRecord(win, at);
    logLine(tickstatLine(r));
    engine.tickstats.push(r);
    while (engine.tickstats.length > kMaxTickstats) engine.tickstats.shift();
    engine.lastAt = r.time;
  }
  function setTickstat(every) {
    tickstatEvery = every;
    if (tickstatTimer) clearInterval(tickstatTimer);
    tickstatTimer = null;
    if (every > 0) {
      tickstatTimer = setInterval(() => pushTickstat(), every * 1000);
      tickstatTimer.unref?.();
    }
  }
  function pushRateStep(from, to, choked) {
    const bw = perfConfig.bw_limit ?? 131072;
    const clear = round(10 + Math.random() * 15, 1);
    logLine(`client 1: snapshot rate ${from.toFixed(1)} -> ${to.toFixed(1)}/s `
      + `(${choked}% choked, ${clear.toFixed(1)} ms to clear each, bwlimit ${bw})`);
    engine.events.push(engineRecord({ kind: "rate", client: 1, from_rate: from, to_rate: to,
                                      choked_pct: choked, clear_ms: clear, bwlimit: bw }));
  }
  function perfmonBlock() {
    const n = perfConfig.tickrate;
    const people = s.players.length;
    const b = {
      jitter_avg_ms: round(0.5 + Math.random() * 0.8), jitter_max_ms: round(1 + Math.random()),
      jitter_n: n, snapshot_write_avg_ms: people ? round(0.03, 3) : 0,
      snapshot_write_max_ms: people ? round(0.06, 3) : 0,
      snapshot_write_n: people ? perfConfig.sendrate : 0,
      entities_skipped: people ? 6438 : 0, entities_total: people ? 13198 : 0,
      entities_skipped_pct: people ? 48.8 : 0, rejected_time_credit: 0, rejected_other: 0,
      rewound_missing: 0, score: people ? 63 : 0, idle_pct: people ? 63 : 0,
      delivery_pct: 0, overload_pct: 0, updates: people ? perfConfig.sendrate : 0,
      warn: 0, fail: 0,
    };
    logLine(`perfmon: tick jitter avg ${f2(b.jitter_avg_ms)}ms max ${f2(b.jitter_max_ms)}ms (n=${b.jitter_n})`);
    logLine(`perfmon: snapshot write avg ${b.snapshot_write_avg_ms.toFixed(3)}ms max ${b.snapshot_write_max_ms.toFixed(3)}ms (n=${b.snapshot_write_n})`);
    logLine(`perfmon: entities skipped ${b.entities_skipped} / ${b.entities_total} (${b.entities_skipped_pct.toFixed(1)}%)`);
    logLine(`perfmon: moves rejected: time credit 0, other 0`);
    logLine(`perfmon: moves rewound with missing snapshots 0 (since map load)`);
    logLine(`perfmon: score ${b.score} = idle ${b.idle_pct.toFixed(1)}% - delivery 0.0% - overload 0.0% `
      + `(updates ${b.updates}, warn 0, fail 0)`);
    engine.perfmon.push(engineRecord(b));
  }
  // The engine's side of the three commands; "" so nothing reaches the tee.
  function engineCommand(cmd, args) {
    if (cmd === "tickstat") {
      if (args[0] !== undefined) {
        const every = Number(args[0]);
        setTickstat(Number.isFinite(every) && every > 0 ? every : 0);
      }
      const said = tickstatEvery > 0 ? "on" : "off";
      logLine(`tickstat: ${said}`);
      engine.said = { text: said, time: unixNow() };
      return "";
    }
    if (cmd === "perfmon") {
      // The engine's block goes to the log only; the game's Lua then says
      // where the level went, and that line does pass through Lua.
      perfmonBlock();
      perfmonLevel = (perfmonLevel + 1) % 4;
      const said = ["false", "true", "true (detailed)", "true (detailed)[spam]"][perfmonLevel];
      return `Server  : ${((Date.now() - bootedAt) / 1000).toFixed(6)} : monitoringActive ${said}`;
    }
    if (cmd === "bwlimit" && args[0] !== undefined) {
      const bw = Math.round(Number(args[0]));
      if (!Number.isFinite(bw) || bw <= 0) return "";
      perfConfig.bw_limit = bw;
      const per = Math.floor(bw / perfConfig.sendrate);
      if (per < 2048) {
        const suggested = 2048 * perfConfig.sendrate;
        logLine(`bwlimit ${bw} bytes/sec at sendrate ${perfConfig.sendrate} leaves ${per} bytes per `
          + `snapshot, below the 2048 a full game needs: snapshots will choke and arrive late. `
          + `bwlimit ${suggested} or more avoids it.`);
        engine.events.push(engineRecord({ kind: "bwlimit_low", bwlimit: bw,
          sendrate: perfConfig.sendrate, per_snapshot: per, needed: 2048, suggested }));
      }
      logLine(`bandwidth limit: ${bw} bytes/sec per player`);
      return "";
    }
    return null;
  }
  function engineReport(esince) {
    const base = { path: kLogPath, scan_s: kEngineScanS, last_id: engine.nextId - 1, more: false,
                   now: unixNow() };
    if (opts.logOff) {
      return { ...base, source: "none", error: `${kLogPath}: No such file or directory`,
               tickstats: [], perfmon: [], events: [] };
    }
    if (logStale) {
      return { ...base, source: "none", stale: true,
               error: "the file does not grow: a line this server printed did not reach it",
               tickstats: [], perfmon: [], events: [] };
    }
    // One id sequence across the three lists: the page ends at the
    // kPerfReplyMax-th lowest id held past the cursor, whichever list it is in.
    const held = [...engine.tickstats, ...engine.perfmon, ...engine.events]
      .map((r) => r.id).filter((id) => id > esince).sort((a, b) => a - b);
    const more = held.length > kPerfReplyMax;
    const upTo = more ? held[kPerfReplyMax - 1] : base.last_id;
    const page = (r) => r.id > esince && r.id <= upTo;
    return {
      ...base, source: "log", last_id: upTo, more,
      ...(engine.lastAt !== null ? { tickstat_last_at: engine.lastAt } : {}),
      ...(engine.said ? { tickstat_said: engine.said } : {}),
      tickstats: engine.tickstats.filter(page),
      perfmon: engine.perfmon.filter(page),
      events: engine.events.filter(page),
    };
  }
  resetEngine();
  if (opts.mod && opts.tickstatSeconds > 0) {
    const every = opts.tickstatSeconds;
    const now = unixNow();
    for (let i = Math.floor(1800 / every); i > 0; i--) pushTickstat(every, now - i * every);
    setTickstat(every);
  }

  // ----------------------------------------------------------- console tee

  // The mod's Lua wraps ServerAdminPrint and Shared.Message and tees every
  // line into a 500-entry ring buffer, so a command's own output comes back in
  // its response and a console tab can stream everything. Only present with
  // --mod; a stock server has none of this.
  //
  // What each command really prints, and through which path, is not guesswork:
  //   * "No matching player"                ServerAdminCommands.lua:172, via ServerAdminPrint
  //   * "No matching Steam Id in ban list"  ServerAdminCommands.lua:488, via ServerAdminPrint
  //   * "Reserved slot amount set to N"     measured on the rig, via Shared.Message
  //   * "Chat All - <name>: <text>"         measured on the rig, via Shared.Message
  // and commands that print nothing at all print nothing here either --
  // sv_cheats and sv_changemap emit only their audit line, and an unknown
  // command emits not even that. All three measured 2026-09-05.

  const kConsoleBufferSize = 500;
  let consoleBuffer = [];
  let nextConsoleId = 1;
  let droppedConsoleLines = 0;

  // Commands the game creates with CreateServerAdminCommand. Only these emit
  // the audit line that proves a command was dispatched.
  const kAdminCommands = new Set([
    "sv_kick", "sv_ban", "sv_unban", "sv_slay", "sv_eject",
    "sv_switchteam", "sv_changemap", "sv_say", "sv_tsay", "sv_psay",
    "sv_reset", "sv_rrall", "sv_randomall", "sv_forceeventeams",
    "sv_reserved_slots", "sv_add_reserved_slot", "sv_remove_reserved_slot",
    "sv_password", "sv_cheats", "sv_status",
    // sv_help is deliberately absent: core/lua/ServerAdmin.lua:143 registers
    // it with Event.Hook rather than CreateServerAdminCommand, so it emits no
    // audit line. Measured on the rig -- 37 help lines, no receipt.
  ]);

  // Help text lifted verbatim from ServerAdminCommands.lua, for the commands
  // the mock implements.
  const kHelp = [
    ["sv_kick", "<player id>, Kicks the player from the server"],
    ["sv_reset", "Resets the game round"],
    ["sv_rrall", "Forces all players to go to the Ready Room"],
    ["sv_randomall", "Forces all players to join a random team"],
    ["sv_forceeventeams", "Balances teams based on previous round and Hive skill"],
    ["sv_ban", "<player id> <duration in minutes> <reason text>, Bans the player from the server, pass in 0 for duration to ban forever"],
    ["sv_unban", "<steam id>, Removes the player matching the passed in Steam Id from the ban list"],
    ["sv_slay", "<player id>, Kills player"],
    ["sv_eject", "<player id>, Ejects Commander from the Command Structure"],
    ["sv_switchteam", "<player id> <team number>, 0 is Ready Room, 1 is Marines, 2 is Aliens, 3 is Spectate"],
    ["sv_say", "<message>, Sends a message to every player on the server"],
    ["sv_tsay", "<team number> <message>, Sends a message to one team"],
    ["sv_psay", "<player id> <message>, Sends a message to a single player"],
    ["sv_password", "<string>, Changes the password on the server"],
    ["sv_cheats", "<boolean>, Turns cheats on and off"],
  ];

  // Strings consoleCommand returns for the mock's own log that the real server
  // never prints. They must not reach the console buffer or the mock would be
  // more informative than the thing it imitates.
  // Checked one by one against ServerAdminCommands.lua: a successful sv_kick
  // prints nothing (only the failure branch calls ServerAdminPrint, line 172),
  // and neither sv_slay nor sv_switchteam reports success at all. A
  // successful sv_unban prints nothing either -- measured on the rig, where a
  // working unban returned an empty line list. sv_ban *does* report, and is
  // not in this list. The mock keeps these strings for its own log, but they
  // must never reach the console buffer.
  const kMockOnlyOutput = [
    /^Changing map to /, /^Cheats /, /^Password set$/, /^Unknown command: /,
    /^No map specified$/,
    /^Kicked /, /^Slayed /, /^Switched /, /^Unbanned /,
  ];

  // Lines the real server routes through ServerAdminPrint rather than
  // Shared.Message. Everything else that does get printed goes through
  // Shared.Message, which is what "server" means here.
  const kAdminPrintOutput = [
    /^No matching player$/, /^No matching Steam Id in ban list: /,
    / has been banned$/,
    /^Added reserved slot for /, /^Removed reserved slot for /,
    /^Invalid arguments?\. /,
  ];

  function teeConsole(src, text) {
    // Everything the wrappers see went to Shared.Message, i.e. to the log.
    logLine(text);
    if (consoleBuffer.length === kConsoleBufferSize) {
      consoleBuffer.shift();
      droppedConsoleLines += 1;
    }
    consoleBuffer.push({
      id: nextConsoleId++,
      time: Math.floor(Date.now() / 1000),
      src,
      text,
    });
  }

  // Run one console line the way Shared.ConsoleCommand does, and return what it
  // printed, in order, as { src, text } -- without teeing it anywhere. Both the
  // mod's runcommand and the legacy rcon path go through here, so Shine's
  // effects land whichever path sent the command.
  //
  // Arguments split on whitespace and nothing else: quotes are not parsed and
  // `;` does not separate commands (both measured on the rig, 2026-09-27).
  function execute(line) {
    const raw = String(line).trim();
    const [cmd = "", ...args] = raw.split(/\s+/);
    const rest = raw.slice(cmd.length).trim();
    const out = [];

    // Shine's own commands. They print through Shared.Message, never emit the
    // vanilla audit line, and end with Shine's own receipt.
    const own = shineCommand(cmd, args, rest);
    if (own) {
      for (const text of own) out.push({ src: "server", text });
      return { dispatched: false, lines: out };
    }

    // sv_help prints one line per command, through ServerAdminPrint, and never
    // a dispatch receipt.
    if (cmd === "sv_help") {
      const wanted = args[0];
      for (const [name, help] of kHelp) {
        if (!wanted || wanted === name) out.push({ src: "admin", text: `${name}: ${help}` });
      }
      return { dispatched: false, lines: out };
    }

    // Shine's ban plugin hooks sv_ban and sv_unban and runs sh_ban/sh_unban
    // first; vanilla's own command then runs as well. Measured order: Shine's
    // lines, the audit line, vanilla's output.
    if (shineHas("ban") && (cmd === "sv_ban" || cmd === "sv_unban")) {
      const redirected = shineCommand(cmd === "sv_ban" ? "sh_ban" : "sh_unban", args, rest);
      for (const text of redirected ?? []) out.push({ src: "server", text });
    }

    const dispatched = kAdminCommands.has(cmd);
    if (dispatched) {
      // core/lua/ServerAdmin.lua:113 emits this before the command runs.
      out.push({ src: "audit", text: `sv - Admin - 0: : STEAM_0:0:0: ${cmd}` });
    }

    const output = consoleCommand(raw);
    // One command can print several lines (sv_reset prints three).
    for (const text of output ? output.split("\n") : []) {
      if (kMockOnlyOutput.some((re) => re.test(text))) continue;
      const src = kAdminPrintOutput.some((re) => re.test(text))
        ? "admin" : "server";
      out.push({ src, text });
    }
    return { dispatched, lines: out, mockLog: output };
  }

  // Run a command the way request=runcommand does, capturing what it printed.
  function runCommandCapturing(line) {
    const firstId = nextConsoleId;
    const { dispatched, lines } = execute(line);
    for (const l of lines) teeConsole(l.src, l.text);
    return {
      cmd: line,
      dispatched,
      elapsed: 0,
      lines: consoleBuffer.filter((l) => l.id >= firstId),
      last_id: nextConsoleId - 1,
    };
  }

  // ---------------------------------------------------------- Shine commands

  // string.TimeToDuration, server side (lua/shine/lib/string.lua): weeks are
  // the largest unit, so 30 days is "4 weeks and 2 days".
  function shineDuration(seconds) {
    if (seconds === 0) return "permanently";
    const parts = [
      [Math.floor(seconds / 604800), "week"],
      [Math.floor(seconds / 86400) % 7, "day"],
      [Math.floor(seconds / 3600) % 24, "hour"],
      [Math.floor(seconds / 60) % 60, "minute"],
      [Math.floor(seconds % 60), "second"],
    ].filter(([n]) => n > 0).map(([n, u]) => `${n} ${u}${n === 1 ? "" : "s"}`);
    const text = parts.length > 1
      ? `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}`
      : (parts[0] ?? "0 seconds");
    return `for ${text}`;
  }

  function shineBan(id, name, minutes, reason) {
    const now = Math.floor(Date.now() / 1000);
    const duration = minutes * 60;
    shineBans.set(String(id), {
      ID: String(id), Name: name, Reason: reason, Duration: duration,
      Issued: now, UnbanTime: duration === 0 ? 0 : now + duration,
      BannedBy: "Console", BannerID: 0,
    });
  }

  // Shine's commands, as they answer a web admin request (no client, so
  // "Console[N/A]"). Wording measured on the rig with a Shine config,
  // 2026-09-27. Returns the printed lines, or null when `cmd` is not a Shine
  // command that exists with the configured plugins -- which on the real server
  // means it prints nothing at all.
  function shineCommand(cmd, args, rest) {
    if (!shine) return null;
    const ran = `Console[N/A] ran command ${cmd} with arguments: ${rest}`;
    const minutesArg = (v) => {
      const n = Number(v ?? 60);   // DefaultBanTime
      return Number.isFinite(n) && n >= 0 ? Math.round(n) : null;
    };

    if (shineHas("ban")) {
      if (cmd === "sh_ban") {
        // Targets a connected client. Anything that matches nobody gets
        // Shine's misleading "cannot target yourself", as measured.
        const p = findPlayer(args[0]);
        const minutes = minutesArg(args[1]);
        if (!p || minutes === null) return ["You cannot target yourself with this command."];
        const reason = args.slice(2).join(" ") || "No reason given.";
        shineBan(p.steamid, p.name, minutes, reason);
        setTimeout(() => leave(p), 500);
        return [`Console[N/A] banned ${p.name}[${p.steamid}] ${shineDuration(minutes * 60)}.`, ran];
      }
      if (cmd === "sh_banid") {
        const id = Number(args[0]);
        const minutes = minutesArg(args[1]);
        // A malformed id fails Shine's parameter parsing; its wording there
        // was not measured, so the mock stays quiet rather than invent one.
        if (!Number.isInteger(id) || id <= 0 || minutes === null) return [];
        const p = findPlayer(id);
        const name = p ? p.name : "<unknown>";
        // With the mod, AddBan is wrapped: an absent player is recorded under
        // the name the recent list last saw. Shine's own line still prints
        // its local, "<unknown>"; the mod's line says what was stored.
        const known = opts.mod && !p ? recent.get(id)?.name : "";
        shineBan(id, known || name, minutes, args.slice(2).join(" ") || "No reason given.");
        // Kicks the target when connected (PerformBan).
        if (p) setTimeout(() => leave(p), 500);
        const line = `Console[N/A] banned ${name}[${id}] ${shineDuration(minutes * 60)}.`;
        return known
          ? [`Named the ban of ${id} "${known}", from recent players.`, line, ran]
          : [line, ran];
      }
      if (cmd === "sh_unban") {
        const id = String(Number(args[0]));
        if (!Number.isInteger(Number(args[0]))) return [];
        if (!shineBans.delete(id)) return [`${id} is not banned.`, ran];
        return [`Console[N/A] unbanned ${id}.`, ran];
      }
    }

    if (shineHas("basecommands")) {
      // Measured on the rig with a Shine config and a human joined,
      // 2026-10-06: the gag and ungag lines, an id that matches nobody, an
      // ungag of someone not gagged (only the receipt: Shine's "is not
      // gagged" goes to the console client, which is nobody), and sv_say,
      // which Shine runs as sh_say.
      const target = () => findPlayer(args[0]);
      const nobody = [`No player matching '${args[0] ?? ""}' was found.`];
      if (cmd === "sh_gag") {
        const p = target();
        if (!p) return nobody;
        shineGagged.add(p.steamid);
        return [`Console[N/A] gagged ${p.name}[${p.steamid}]`, ran];
      }
      if (cmd === "sh_ungag") {
        const p = target();
        if (!p) return nobody;
        if (!shineGagged.delete(p.steamid)) return [ran];
        return [`Console[N/A] ungagged ${p.name}[${p.steamid}]`, ran];
      }
      if (cmd === "sv_say" || cmd === "sh_say") {
        // No audit line, no "Chat All - Admin" line: only Shine's receipt.
        addChat(rest, { tee: false });
        return [`Console[N/A] ran command sh_say with arguments: ${rest}`];
      }
    }

    if (shineHas("reservedslots") && cmd === "sh_setresslots") {
      const n = Math.round(Number(args[0]));
      if (!Number.isFinite(n) || n < 0) return [];
      shineSlots = n;
      return [`Console[N/A] set reserved slot count to ${n}`, ran];
    }

    return null;
  }

  // The list GetBannedPlayersList() returns once Shine's ban plugin has
  // replaced it: string ids, Shine's UnbanTime as `time`, and pairs() order --
  // which is not stable, so it is shuffled on every call.
  function shineBanList() {
    const list = [...shineBans.values()].map((b) => ({
      name: b.Name, id: b.ID, reason: b.Reason, time: b.UnbanTime,
    }));
    for (let i = list.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [list[i], list[j]] = [list[j], list[i]];
    }
    return list;
  }

  // request=getbans: what the mod's GetBansInForce() builds.
  const kPermanentAfter = 100 * 365 * 24 * 60 * 60;
  function bansInForce() {
    const now = Math.floor(Date.now() / 1000);
    const bans = [];
    const add = (ban, expiry) => {
      expiry = Number(expiry) || 0;
      if (expiry !== 0 && expiry <= now) return;
      ban.permanent = expiry === 0 || expiry - now > kPermanentAfter;
      if (!ban.permanent) ban.expires = expiry;
      bans.push(ban);
    };
    if (shineHas("ban")) {
      for (const b of shineBans.values()) {
        add({
          id: Number(b.ID), name: b.Name, reason: b.Reason,
          issued: b.Issued, duration: b.Duration, banned_by: b.BannedBy,
        }, b.UnbanTime);
      }
      bans.sort((a, b) => (b.issued - a.issued) || (a.id - b.id));
      return { source: "shine", now, bans };
    }
    for (const b of [...s.bans].reverse()) {
      add({ id: Number(b.id), name: b.name, reason: b.reason }, b.time);
    }
    return { source: "vanilla", now, bans };
  }

  // ---------------------------------------------------------------- commands

  // SetReservedSlotAmount's guard: tonumber, then 0 <= amount <= max players.
  function setSlotAmount(value) {
    const n = Number(value);
    if (value === undefined || value === "" || !Number.isFinite(n)
        || n < 0 || n > maxPlayers) return false;
    s.reserved.amount = n;
    return true;
  }

  // Every command the shipped panel can send, plus the ones an operator types
  // into the manual box. Returns a line for the mock's own log only: the real
  // server sends command output to log-Server.txt and the HTTP response never
  // sees it (API.md, "Demonstrated, not argued").
  function consoleCommand(line) {
    const [cmd, ...args] = String(line).trim().split(/\s+/);
    switch (cmd) {
      case "sv_kick": {
        const p = findPlayer(args[0]);
        if (!p) return `No matching player`;
        // The response is rendered before the disconnect completes, so the
        // player is still in player_list for this reply. That is exactly what
        // made a failed kick indistinguishable from a successful one.
        setTimeout(() => {
          leave(p);
        }, 500);
        return `Kicked ${p.name}`;
      }
      case "sv_ban": {
        // ServerAdminCommands.lua:432. A connected player is banned by name;
        // any other positive id is banned as "Unknown", with "None provided"
        // when no reason is given -- both measured on the rig. Vanilla appends
        // without checking for an existing entry.
        const id = Number(args[0]);
        const minutes = Number(args[1]);
        const time = Number.isFinite(minutes) && minutes > 0
          ? Math.floor(Date.now() / 1000) + minutes * 60 : 0;
        const reason = args.slice(2).join(" ");
        const p = findPlayer(id);
        if (p) {
          s.bans.push({ name: p.name, id: p.steamid, reason, time });
          setTimeout(() => leave(p), 500);
          return `${p.name} has been banned`;
        }
        if (Number.isInteger(id) && id > 0) {
          s.bans.push({ name: "Unknown", id, reason: reason || "None provided", time });
          return `Player with SteamId ${id} has been banned`;
        }
        return "No matching player";
      }
      case "sv_unban": {
        const raw = args[0];
        if (bugs.unban) {
          // UnbanUser(steamId) with the raw console string against a map keyed
          // by number. Never matches, however plainly the ban is listed.
          const hit = s.bans.find((b) => b.id === raw);
          if (!hit) return `No matching Steam Id in ban list: ${raw}`;
        }
        const id = Number(raw);
        const before = s.bans.length;
        s.bans = s.bans.filter((b) => b.id !== id);
        return s.bans.length < before
          ? `Unbanned ${id}`
          : `No matching Steam Id in ban list: ${raw}`;
      }
      case "sv_slay": {
        const p = findPlayer(args[0]);
        if (!p) return "No matching player";
        p.deaths = (p.deaths || 0) + 1;
        return `Slayed ${p.name}`;
      }
      case "sv_eject":
        return findPlayer(args[0]) ? `Ejected ${args[0]}` : "No matching player";
      // The round commands (ServerAdminCommands.lua:124-128). Measured on the
      // rig, vanilla and Shine alike: sv_reset prints its AI brains' resets,
      // the other three print nothing. ForceEvenTeams() has no round check.
      case "sv_reset": {
        s.game_started = false;
        s.gameStartedAt = null;
        const t = ((Date.now() - bootedAt) / 1000).toFixed(6);
        return [
          `Server  : ${t} : Reset AI TeamBrain for Marines`,
          `Server  : ${t} : Reset AI TeamBrain for Aliens`,
          `Server  : ${t} : Reset location group stale timers`,
        ].join("\n");
      }
      case "sv_rrall":
        for (const p of s.players) { p.team = 0; p.iscomm = false; }
        return "";
      case "sv_randomall":
        for (const p of s.players) { p.team = Math.random() < 0.5 ? 1 : 2; p.iscomm = false; }
        return "";
      case "sv_forceeventeams":
        // Best first, alternating: what the skill sort amounts to here.
        [...s.players].sort((a, b) => b.score - a.score)
          .forEach((p, i) => { p.team = i % 2 === 0 ? 1 : 2; p.iscomm = false; });
        return "";
      case "sv_switchteam": {
        const p = findPlayer(args[0]);
        if (!p) return "No matching player";
        p.team = Number(args[1]);
        p.iscomm = false;
        return `Switched ${p.name} to team ${p.team}`;
      }
      case "sv_changemap": {
        const map = args[0];
        if (!map) return "No map specified";
        s.map = map;
        logChecked = false;   // a new Lua VM checks again
        logLine(`${engineStamp(Date.now())} Worker 00 : Loading 'maps/${map}.level'`);
        logLine(`Loading pathing mesh for level maps/${map}.level`);
        logLine(`Finished loading 'maps/${map}.level'`);
        s.game_started = false;
        s.gameStartedAt = null;
        leave(...s.players);  // everyone reconnects through the map change
        // Both chat rings are Lua state: a new VM starts them empty, ids from 1.
        // So are Shine's gags (sh_gag holds "for the remainder of the map").
        s.chat = [];
        s.chatDropped = 0;
        shineGagged.clear();
        s.perf = [];
        // A new Lua VM: the perf windows start over, ids from 1, and so do
        // the engine lines it has scanned. tickstat itself stays on.
        loadPerf(false);
        resetEngine();
        // The new map loads the cycle from the file, and Shine re-reads it.
        s.mapCycleMemory = clone(s.mapCycle);
        startMapVote();
        mountMods();
        return `Changing map to ${map}`;
      }
      case "sv_say":
        addChat(args.join(" "));
        return "";
      case "sv_tsay": {
        const team = Number(args[0]);
        addChat(args.slice(1).join(" "), { team, teamOnly: true });
        return "";
      }
      case "sv_psay":
        addChat(args.slice(1).join(" "));
        return "";
      case "sv_reserved_slots":
        // SetReservedSlotAmount: an amount outside 0..max players is ignored
        // without a word (measured: `sv_reserved_slots 99` on a 16-slot rig).
        return setSlotAmount(args[0]) ? `Reserved slot amount set to ${s.reserved.amount}` : "";
      case "sv_add_reserved_slot": {
        // AddReservedSlot(client, name, id), ServerAdminCommands.lua:632. The
        // name is one argument -- quotes are not parsed, so `"Two Words"`
        // arrives with its quote marks and `Two Words 123` takes "Words" as
        // the id. Slots are keyed by name: a second slot under the same name
        // replaces the first. All measured on the rig, 2026-09-27.
        const name = args[0] ?? "None";
        const id = Number(args[1]);
        if (args[1] === undefined || !Number.isFinite(id)) {
          return "Invalid arguments. Pass in a name and Steam Id for the new reserved slot.";
        }
        s.reserved.ids = s.reserved.ids.filter((r) => r.name !== name);
        s.reserved.ids.push({ name, id });
        return `Added reserved slot for ${name} with Id ${id}`;
      }
      case "sv_remove_reserved_slot": {
        // RemoveReservedSlot, ServerAdminCommands.lua:657: the first match is
        // removed, and no match prints nothing at all.
        const id = Number(args[0]);
        if (args[0] === undefined || !Number.isFinite(id)) {
          return "Invalid argument. Pass in the Steam Id for the existing reserved slot.";
        }
        const gone = s.reserved.ids.find((r) => r.id === id);
        if (!gone) return "";
        s.reserved.ids = s.reserved.ids.filter((r) => r !== gone);
        return `Removed reserved slot for ${gone.name}`;
      }
      case "sv_password":
        return "Password set";
      case "sv_cheats":
        s.cheats = args[0] === "1" ? "true" : "false";
        return `Cheats ${s.cheats}`;
      default: {
        // tickstat, perfmon, bwlimit: the engine's, printed to the log only.
        const printed = engineCommand(cmd, args);
        if (printed !== null) return printed;
        return `Unknown command: ${cmd}`;
      }
    }
  }

  // ----------------------------------------------------------- request types

  // Mirrors OnWebRequest(actions). Returns [contentType, body] the way the Lua
  // does, or null for the write operations, which the engine turns into an
  // empty 200 with `Content-Type: text/html` -- not JSON. Verified against a
  // live server; see fixtures/live/setmapcycle.headers.
  function onWebRequest(actions) {
    const json = (v) => ["application/json", JSON.stringify(v)];

    // The mod answers a request with no parameters at all -- a bare `/`, a
    // missing file, an empty POST -- with a page pointing at the panel, not
    // the state blob (CONSTRAINTS item 6). The rig's reply, verbatim.
    if (opts.mod && Object.keys(actions).length === 0) {
      return ["text/html", readFileSync(join(fixturesDir, "root-mod.html"), "utf8")];
    }

    switch (actions.request) {
      case "getbanlist": {
        const now = Math.floor(Date.now() / 1000);
        // Under Shine's ban plugin this is Shine's list, not vanilla's.
        const all = shineHas("ban") ? shineBanList() : s.bans;
        // Vanilla never prunes: an expired ban keeps being listed even though
        // it no longer blocks anyone.
        const list = bugs.banPruning
          ? all
          : all.filter((b) => b.time === 0 || b.time > now);
        return json(list);
      }

      case "getreservedslots":
        // With the mod, Shine's reservedslots count rides along when that
        // plugin is on.
        return json(opts.mod && shineHas("reservedslots")
          ? { ...s.reserved, shine: { slots: shineSlots } }
          : s.reserved);

      case "setreservedslotamount":
        if (bugs.setreservedslotamount) {
          // The amount arrives as `client`, `amount` is nil, the guard rejects
          // it, and the request still answers 200 with an empty body.
          log("setreservedslotamount: swallowed (vanilla bug)");
          return null;
        }
        if (setSlotAmount(actions.amount)) {
          log(`Reserved slot amount set to ${s.reserved.amount}`);
        }
        return null;

      case "getchatlist":
        // `Server.recentChatMessages and json.encode(...) or "{ }"` -- when the
        // buffer does not exist the reply is an object, not an array.
        if (opts.noChatBuffer) return ["application/json", "{ }"];
        // The mod's cursor (CONSTRAINTS item 3). Without one, or on stock, the
        // game's 20 in the game's shape -- no time, which only the mod records.
        if (opts.mod && actions.since !== undefined && Number.isFinite(Number(actions.since))) {
          const since = Number(actions.since);
          return json({
            entries: s.chat.filter((e) => e.id > since),
            last_id: s.chat.at(-1)?.id ?? 0,
            dropped: s.chatDropped,
            buffer_size: kModChatBufferSize,
          });
        }
        return json(s.chat.slice(-kMaxChat).map(({ time, ...e }) => e));

      case "getperfdata":
        return json(s.perf.slice(-kMaxPerfDatas));

      case "getinstalledmodslist":
        // The mod marks what is mounted now; a stock server cannot say.
        if (!opts.mod) return json(s.installedMods);
        return json(s.installedMods.map((m) => ({
          ...m, active: s.activeMods.includes(m.id.toLowerCase()),
        })));

      case "getmaplist":
        return json(s.mapList);

      case "getmapcycle":
        // Stock answers from the copy loaded with the map; the mod reads the
        // file, which is what rotation uses.
        return json(modIdsToHex(clone(opts.mod ? s.mapCycle : s.mapCycleMemory)));

      case "setmapcycle": {
        let cycle;
        try {
          cycle = JSON.parse(actions.data);
        } catch {
          cycle = null;
        }
        if (opts.mod) {
          // The mod refuses what the game could not use, writes nothing, and
          // otherwise answers with the file read back.
          const problem = cycle === null ? "not valid JSON" : checkMapCycle(cycle);
          if (problem) {
            log(`setmapcycle refused: ${problem}`);
            return json({ ok: false, error: problem });
          }
        } else if (!cycle) {
          log("setmapcycle web request passed bad json data");
          return null;
        } else if (!Array.isArray(cycle.maps)) {
          // ipairs(mapcycle.maps) raises before anything is written; the
          // engine answers an empty 200 regardless (measured on the rig).
          log("setmapcycle: bad argument #1 to 'ipairs' (table expected, got nil)");
          return null;
        }
        s.mapCycle = modIdsFromHex(cycle);
        s.mapCycleMemory = clone(s.mapCycle);
        log(`map cycle written: ${s.mapCycle.maps.length} maps`);
        if (opts.mod) return json({ ok: true, cycle: modIdsToHex(clone(s.mapCycle)) });
        return null;
      }

      case "installmod": {
        const raw = actions.modid;
        let id = null;
        let refusal = null;
        if (typeof raw !== "string" || !/^[0-9a-f]{1,16}$/i.test(raw)) {
          refusal = `Not a hex workshop id: ${String(raw ?? "nil").slice(0, 40)}`;
        } else {
          id = raw.toLowerCase().replace(/^0+/, "");
          if (!id) refusal = "0 is not a workshop id.";
        }
        // The engine drops what it cannot parse without a word; the mod says so.
        if (refusal) return opts.mod ? json({ ok: false, error: refusal }) : null;

        const already = s.installedMods.some((m) => m.id === id);
        const item = s.catalogue.find((m) => m.id === id);
        const never = workshopNext.install === "never";
        workshopNext.install = null;
        if (!already && item && !never) {
          // Listed once downloaded and unpacked, under its real title, never
          // before (measured: 1.7 s for 710 bytes, 3.8 s for 26 MB). An id
          // Steam does not have never arrives at all.
          setTimeout(() => {
            if (s.installedMods.some((m) => m.id === id)) return;
            s.installedMods.push({ id, name: item.title });
            log(`installed mod ${id}`);
          }, opts.installDelayMs ?? 3000);
        }
        return opts.mod ? json({ ok: true, id, already_installed: already }) : null;
      }

      case "getmods": {
        const now = Date.now();
        // Stock: no searchtext never starts a search, and a `p` that is not a
        // number is a Lua error, an empty 200. The mod reads them as "" and 1.
        const hasText = typeof actions.searchtext === "string";
        let page;
        if (opts.mod) {
          page = Math.floor(Number(actions.p ?? 1));
          if (!(page >= 1 && page <= 1000)) page = 1;
        } else {
          page = actions.p === undefined ? 1 : Number(actions.p);
          if (Number.isNaN(page)) return null;
        }
        const searchtext = hasText ? actions.searchtext : "";
        // Vanilla's key runs text and page together; the mod's does not
        // (without searchtext, vanilla's key is the page number itself).
        const key = opts.mod ? `${searchtext}\0${page}`
          : hasText ? `${searchtext}${page}` : `#${page}`;

        for (const [k, e] of modSearches) {
          if (e.result && now - e.cachedAt >= 60_000) modSearches.delete(k);
        }
        const entry = modSearches.get(key);
        if (entry?.result) return ["application/json", entry.result];
        if (entry && now - entry.startedAt < workshopTimeoutS * 1000) {
          return opts.mod
            ? json({ loading: true, elapsed: (now - entry.startedAt) / 1000 })
            : ["application/json", '{"loading": true}'];
        }
        if (entry && opts.mod) {
          // Given up once; the next request starts afresh.
          modSearches.delete(key);
          return json({ done: true, page, items: [], count: 0,
            error: `The workshop search had no answer after ${workshopTimeoutS} s.` });
        }

        // Start (or, on stock, silently restart) the search.
        const started = { startedAt: now, result: null, cachedAt: 0 };
        modSearches.set(key, started);
        if (!opts.mod && !hasText) {
          // Vanilla starts nothing without searchtext: loading forever.
          return ["application/json", '{"loading": true}'];
        }
        const fate = workshopNext.searches > 0 ? workshopNext.search : null;
        workshopNext.searches = Math.max(0, workshopNext.searches - 1);
        if (fate !== "hang") {
          setTimeout(() => {
            if (modSearches.get(key) !== started) return;   // abandoned
            const needle = searchtext.toLowerCase();
            const hits = fate === "offline" ? [] : s.catalogue
              .filter((m) => m.title.toLowerCase().includes(needle)
                || m.description.toLowerCase().includes(needle))
              .slice(0, kWorkshopLimit);
            started.result = JSON.stringify(opts.mod
              ? { done: true, page, items: hits, count: hits.length,
                  capped: hits.length >= kWorkshopLimit }
              : { items: hits });
            started.cachedAt = Date.now();
          }, fate === "offline" ? 0 : (opts.modSearchMs ?? 1200));
        }
        return opts.mod ? json({ loading: true, elapsed: 0 })
                        : ["application/json", '{"loading": true}'];
      }

      // The mod's two additions. Absent without --mod, in which case they
      // fall through to the default handler exactly as any unknown request
      // does on a stock server -- which is what a panel talking to the wrong
      // server would actually see.
      case "runcommand": {
        if (!opts.mod) break;
        return json(runCommandCapturing(actions.cmd ?? ""));
      }

      case "getbans": {
        if (!opts.mod) break;
        return json(bansInForce());
      }

      case "getrecentplayers": {
        if (!opts.mod) break;
        return json(recentPlayers());
      }

      case "getwhitelist": {
        if (!opts.mod) break;
        return json(getWhitelist());
      }

      case "getmapvote": {
        if (!opts.mod) break;
        if (!shineHas("mapvote")) return json({ enabled: false });
        return json({
          enabled: true,
          maps_from_cycle: true,
          round_limit: 2,
          ...(nextVoteMap() ? { next_map: nextVoteMap() } : {}),
          options: [...voteOptions],
        });
      }

      case "getperf": {
        if (!opts.mod) break;
        const since = Number(actions.since ?? 0) || 0;
        const after = perfWin.windows.filter((w) => w.id > since);
        const more = after.length > kPerfReplyMax;
        const windows = after.slice(0, kPerfReplyMax);
        return json({
          engine: engineReport(Number(actions.esince ?? 0) || 0),
          window_s: perfWindowS,
          capacity: kPerfCapacity,
          loaded_at: perfWin.loadedAt,
          map: s.map,
          config: { ...perfConfig },
          windows,
          last_id: more ? windows[windows.length - 1].id : perfWin.nextId - 1,
          more,
        });
      }

      case "getlog": {
        if (!opts.mod) break;
        return json(getLog(actions));
      }

      case "getconsole": {
        if (!opts.mod) break;
        const since = Number(actions.since ?? 0) || 0;
        return json({
          lines: consoleBuffer.filter((l) => l.id > since),
          last_id: nextConsoleId - 1,
          dropped: droppedConsoleLines,
          filtered: 0,
          buffer_size: kConsoleBufferSize,
        });
      }
    }

    // Anything unmatched falls through here, including a bare `/`, an unknown
    // request type, and -- without --mod -- runcommand and getconsole. The
    // shipped panel sends request=json, which is one of those unmatched
    // values. See API.md, "There is no directory index either".
    if (actions.command) {
      // The legacy path the 2012 panel uses. It still runs the command and
      // still returns nothing about it, with or without --mod: the mod adds a
      // way to see output, it does not change this one.
      const out = opts.mod
        ? runCommandCapturing(actions.rcon ?? "").lines.map((l) => l.text).join(" | ")
        : execute(actions.rcon ?? "").mockLog;
      log(`console: ${actions.rcon} -> ${out || "(no output)"}`);
    }
    return json(serverState());
  }

  return {
    onWebRequest,
    consoleCommand,
    serverState,
    bugs,
    raw: s,
    /** Start or end the round, as the game's own rules would. */
    setRound(started) {
      s.game_started = started;
      s.gameStartedAt = started ? Date.now() : null;
    },
    /**
     * A player says something, n times: what OnChatReceived does
     * (NetworkMessages_Server.lua:277-282), printed and then recorded.
     */
    playerChat({ text = "hello", player = "Skulkovich", team = 1, teamOnly = false, steamId = 10000000, n = 1 } = {}) {
      // A gagged player's chat never reaches AddChatToHistory: Shine refuses
      // it in CheckChatAllowed first.
      if (shineGagged.has(steamId)) return;
      for (let i = 1; i <= n; i++) {
        addChat(n > 1 ? `${text} ${i}` : text, { player, team, teamOnly, steamId });
      }
    },
    /**
     * Edit MapCycle.json behind the server's back, as an operator with a
     * shell would: the game's own copy is not reloaded.
     */
    editCycleFile({ time, append, mod } = {}) {
      if (time !== undefined) s.mapCycle.time = time;
      if (append) s.mapCycle.maps.push(append);
      // As written by hand: no conversion, so junk stays junk.
      if (mod) (s.mapCycle.mods ??= []).push(mod);
    },
    /**
     * The next `n` workshop searches hang or fail the way an offline server's
     * do (at once, empty), the next install never arrives, and the mod's
     * search timeout, in seconds.
     */
    setWorkshop({ search, n = 1, install, timeout } = {}) {
      if (search !== undefined) { workshopNext.search = search; workshopNext.searches = n; }
      if (install !== undefined) workshopNext.install = install;
      if (timeout !== undefined) workshopTimeoutS = timeout;
    },
    /** What the next getrecentplayers reports about the file's load and save. */
    setRecentStorage(loaded, error) {
      recentStorage = { loaded, saved_at: recentStorage.saved_at,
                        ...(error ? { error } : {}) };
    },
    /**
     * Values the next perf window carries (score, interp_fails, worst_tick_ms,
     * ...), and with `emit` that window at once rather than at the timer.
     */
    forcePerf(fields, emit) {
      perfForced = { ...(perfForced ?? {}), ...fields };
      if (emit) pushPerfWindow();
    },
    /**
     * The log behind the server's back: `restart` starts a new file (a new
     * header, as a restart does), `truncate` cuts it to its header, `append`
     * adds `n` numbered lines, `partial` writes text with no newline, `burst`
     * appends that many bytes of lines at once, `stale` makes the file one
     * the server is not writing (a copy left by an earlier run).
     */
    logControl({ restart, truncate, append, n = 1, partial, burst, stale } = {}) {
      if (restart) { newLogFile(Number(restart) > 1 ? Number(restart) : 0); logChecked = false; }
      if (stale !== undefined) { logStale = stale; logChecked = false; }
      if (truncate) logFile = Buffer.from(logHeader(logBootAt), "utf8");
      if (append !== undefined) {
        for (let i = 1; i <= n; i++) logLine(n > 1 ? `${append} ${i}` : append);
      }
      if (partial !== undefined) logWrite(partial);
      if (burst) {
        const lines = [];
        let bytes = 0;
        for (let i = 1; bytes < burst; i++) {
          const l = `burst ${String(i).padStart(6, "0")} ${"x".repeat(88)}`;
          lines.push(l);
          bytes += l.length + 1;
        }
        logWrite(`${lines.join("\n")}\n`);
      }
      return { size: logFile.length, file_id: logFileId() };
    },
    /** A runtime rate change, as `tickrate 80` on the console would make. */
    setPerfConfig(fields) { Object.assign(perfConfig, fields); },
    /**
     * Values the next TICKSTAT line carries (choked_pct, snap_p99_bytes, ...);
     * `emit` writes it now; `rateChange` logs a player's rate step down and,
     * with `rateChange === "up"`, back up.
     */
    forceTickstat(fields, { emit = false, rateChange } = {}) {
      tickstatForced = { ...(tickstatForced ?? {}), ...fields };
      if (rateChange === "down") pushRateStep(perfConfig.sendrate, round(perfConfig.sendrate * 2 / 3, 1), 29);
      if (rateChange === "up") pushRateStep(round(perfConfig.sendrate * 2 / 3, 1), perfConfig.sendrate, 0);
      if (emit) pushTickstat(tickstatEvery || 10);
    },
    stop() {
      clearInterval(perfTimer); clearInterval(perfWindowTimer); clearInterval(logTracing);
      if (tickstatTimer) clearInterval(tickstatTimer);
    },
  };
}

// The mod's CheckMapCycle: why a cycle cannot be written, or null. The
// wording is the Lua's, so a refusal reads the same from either.
// Workshop results the fixture lacks, in the engine's shape. Made up, not
// captured: a small result ("halcyon" finds three), and a title and a
// description carrying markup and BBCode, which the panel must show as text.
function syntheticWorkshopItems() {
  const item = (id, title, description, filesize, extra = {}) => ({
    description, authorid: "76561197960287930", filesize, id,
    tags: "Mod", steamresult: 1, childcount: 0,
    thumbnailurl: `https://images.steamusercontent.com/ugc/mock/${id}/`,
    title, version: 1758931200, ...extra,
  });
  return [
    item("5ea0001", "Halcyon Tweaks", "Server-side tweaks.\r\n\r\nNo client files.", 48213),
    item("5ea0002", "Halcyon Sprays", "[b]Sprays[/b] for the Halcyon servers.", 1843200,
         { tags: "Look and Feel" }),
    item("5ea0003", "ns2_halcyon", "A map. [url=https://example.com/sud]Changelog[/url]",
         9437184, { tags: "Map" }),
    item("5ea0004", "Markup <b>test</b> & <i>friends</i>",
         "<script>window.__xss = 1</script><img src=x onerror=\"window.__xss = 2\">\n"
         + "[h1]Heading[/h1] [b]bold[/b] [url=https://example.com]a link[/url] "
         + "[img]https://example.com/banner.png[/img]\n[list][*]one[*]two[/list]",
         2048, { childcount: 2, steamresult: 9 }),
    // A real whitelisted mod, Badges+ (191973881), for the whitelist status.
    item("b7149f9", "Badges+", "Custom badges.", 120832),
  ];
}

function checkModIds(mods, where) {
  if (mods === undefined || mods === null) return null;
  if (!Array.isArray(mods)) return `${where} must be a list`;
  for (let i = 0; i < mods.length; i++) {
    const m = mods[i];
    if (typeof m === "string") {
      if (!m.includes(":") && !/^[0-9a-fA-F]+$/.test(m)) {
        return `${where}[${i + 1}] is not a hex mod id: ${m}`;
      }
    } else if (typeof m !== "number") {
      return `${where}[${i + 1}] is not a mod id`;
    }
  }
  return null;
}

function checkMapCycle(cycle) {
  if (typeof cycle !== "object" || cycle === null || Array.isArray(cycle)) {
    return "not a JSON object";
  }
  if (!Array.isArray(cycle.maps) || cycle.maps.length === 0) {
    return "`maps` must be a list with at least one map";
  }
  for (let i = 0; i < cycle.maps.length; i++) {
    const entry = cycle.maps[i];
    if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      if (typeof entry.map !== "string" || entry.map === "") {
        return `maps[${i + 1}] has no map name`;
      }
      const err = checkModIds(entry.mods, `maps[${i + 1}].mods`);
      if (err) return err;
    } else if (typeof entry !== "string" || entry === "") {
      return `maps[${i + 1}] is not a map name`;
    }
  }
  if (cycle.time !== undefined
      && (typeof cycle.time !== "number" || !(cycle.time >= 0))) {
    return "`time` must be a number of minutes, 0 or more";
  }
  if (cycle.mode !== undefined && cycle.mode !== "order" && cycle.mode !== "random") {
    return '`mode` must be "order" or "random"';
  }
  return checkModIds(cycle.mods, "mods");
}

// JSON has no 64-bit integers, so mod ids cross the wire as hex strings.
// ModsIdsToHex / ModIdsFromHex, applied to the cycle and to each map entry.
function modIdsToHex(cycle) {
  const conv = (t) => {
    if (!t || !Array.isArray(t.mods)) return t;
    t.mods = t.mods.map((m) => (typeof m === "string" ? m : m.toString(16)));
    return t;
  };
  conv(cycle);
  for (const map of cycle.maps || []) conv(map);
  return cycle;
}

function modIdsFromHex(cycle) {
  const conv = (t) => {
    if (!t || !Array.isArray(t.mods)) return t;
    t.mods = t.mods.map((m) => {
      // A string carrying ':' is a non-workshop source and is left alone.
      if (typeof m !== "string" || m.includes(":")) return m;
      const v = Number.parseInt(m, 16);
      return Number.isFinite(v) ? v : m;
    });
    return t;
  };
  conv(cycle);
  for (const map of cycle.maps || []) conv(map);
  return cycle;
}

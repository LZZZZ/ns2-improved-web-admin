#!/usr/bin/env node
// The engine half of the mock: the 2026-09-03 web server's routing and rules.
//
// It exists because of the cross-site Origin rule -- a dev server cannot talk
// to a real game server -- and because UI work should not need a 3.5 GB NS2
// install running. Zero dependencies, so it starts with `node mock/server.js`.
//
// What it reproduces, all of it measured against a live 26-09-03 server and
// written up in docs/API.md and docs/CONSTRAINTS.md:
//
//   * one endpoint. `/` is the Lua handler, not a directory index; the panel
//     lives at /index.html, and any path that is not a file on disk falls
//     through to the handler rather than 404ing.
//   * GET and POST only. Method is not enforced beyond that, so every write
//     works as a GET with query parameters -- which is how the shipped panel
//     installs mods.
//   * an Origin header that does not match Host is refused 403.
//   * with no login configured, a Host that is neither localhost nor an IP
//     literal is refused 403 (09-25 and later; measured on 09-26).
//   * a POST's parameters come from its form body only; its query string is
//     dropped (measured on 09-26).
//   * the hardening response headers, on every reply.
//   * writes answer 200 with an empty body and Content-Type: text/html.
//
// Usage: node mock/server.js [--port 8080] [--web <dir>] [--auth user:pass]
//                           [--mod] [--shine[=ban,reservedslots,mapvote,basecommands]]
//                           [--maps=modded] [--log=off] [--beta-players]
//                           [--whitelist=cached|fail]
// See mock/README.md.

import { createServer } from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createState } from "./state.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const REPO = resolve(HERE, "..");

// ------------------------------------------------------------------ options

function parseArgs(argv) {
  const o = {
    port: 8080,
    host: "127.0.0.1",
    web: null,
    auth: null,
    control: true,
    quiet: false,
    perfRateSeconds: 60,
    hostRule: true,
    shine: null,
    bugs: {},
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === "--port") o.port = Number(next());
    else if (a === "--host") o.host = next();
    else if (a === "--web") o.web = resolve(next());
    else if (a === "--auth") o.auth = next();
    else if (a === "--no-control") o.control = false;
    else if (a === "--quiet") o.quiet = true;
    else if (a === "--perf-rate") o.perfRateSeconds = Number(next());
    else if (a === "--perf-window") o.perfWindowSeconds = Number(next());
    else if (a === "--tickstat") o.tickstatSeconds = Number(next());
    else if (a === "--no-chat-buffer") o.noChatBuffer = true;
    else if (a === "--mod") o.mod = true;
    else if (a === "--log=off") o.logOff = true;
    else if (a === "--beta-players") o.betaPlayers = true;
    else if (a === "--whitelist=cached" || a === "--whitelist=fail") {
      o.whitelist = a.slice(a.indexOf("=") + 1);
    }
    else if (a === "--whitelist-delay") o.whitelistDelayMs = Number(next());
    else if (a === "--log-rounds") o.logRounds = Number(next());
    else if (a === "--maps" || a.startsWith("--maps=")) {
      o.maps = a.includes("=") ? a.slice(a.indexOf("=") + 1) : next();
    }
    else if (a === "--no-host-rule") o.hostRule = false;
    else if (a === "--shine" || a.startsWith("--shine=")) {
      // A common config: ban, mapvote and basecommands on, reservedslots off.
      const list = a.includes("=") ? a.slice(a.indexOf("=") + 1) : "ban,mapvote,basecommands";
      o.shine = new Set(list.split(",").map((k) => k.trim()).filter(Boolean));
    }
    else if (a === "--fix") {
      // --fix unban,setreservedslotamount -- develop against a mock that has
      // the mod's Lua fixes in it.
      for (const k of next().split(",")) o.bugs[k.trim()] = false;
    } else if (a === "--fix-all") {
      o.bugs = { setreservedslotamount: false, unban: false, banPruning: false };
    } else if (a === "-h" || a === "--help") o.help = true;
    else {
      console.error(`unknown option: ${a}`);
      o.help = true;
    }
  }
  return o;
}

const HELP = `
mock NS2 web admin server

  --port <n>          default 8080
  --host <addr>       default 127.0.0.1
  --web <dir>         static root: web/ for the new panel, or a server
                      install's ns2/web for the shipped 2012 one. Without it
                      the mock serves the API only.
  --auth user:pass    require HTTP Digest, with the real 301 s nonce lifetime.
                      Off by default; the real server always requires it.
  --no-host-rule      without --auth, the engine refuses a Host that is not
                      localhost or an IP literal; this switches that off
  --mod               behave as a server running this repo's lua/
  --shine[=a,b]       Shine loaded, with these plugins on (default
                      ban,mapvote,basecommands).
                      Plugins that matter: ban, reservedslots, mapvote,
                      basecommands
  --maps=modded       a modded server's map cycle, map list and installed mods
                      instead of a stock install's
  --log=off           --mod's getlog cannot open the log, as on a server whose
                      -logdir is not its config directory
  --log-rounds <n>    rounds of made-up history in the log (default 40, ~200 KB)
  --beta-players      with --mod: the 09-26+ engine's per-player Family
                      Sharing and rejected-move counts (made up)
  --whitelist=cached  with --mod: getwhitelist has a copy already, as after a
                      map change; by default the first call starts a read
  --whitelist=fail    with --mod: the read from Steam fails
  --whitelist-delay <ms>  how long a read takes (default 1500)
  --perf-rate <s>     seconds between perf samples (default 60; try 2)
  --perf-window <s>   length of a --mod getperf window (default 10, as the Lua)
  --tickstat <s>      boot with the engine's tickstat on at this interval and
                      half an hour of it behind (default: off, as after a restart)
  --no-chat-buffer    answer getchatlist with "{ }", as a server whose chat
                      ring buffer does not exist does
  --fix a,b           switch off a reproduced vanilla bug: setreservedslotamount,
                      unban, banPruning
  --fix-all           switch all of them off
  --no-control        disable the /__mock/ control endpoints
  --quiet             do not log requests

Control endpoints (not part of the real API, and never requested by the panel):
  GET /__mock/state          the whole simulated server as JSON
  GET /__mock/503?n=3        answer the next 3 requests with 503
  GET /__mock/slow?ms=2000   delay every reply by 2000 ms
  GET /__mock/reset          reload the fixtures
  GET /__mock/round?started=1|0
                             start or end the round
  GET /__mock/chat?text=<t>[&player=<name>][&team=1][&teamOnly=1][&steamid=<id>][&n=3]
                             a player says something (n times, numbered)
  GET /__mock/cycle-file?time=45[&append=ns2_x][&mod=<id>]
                             edit MapCycle.json behind the game's back
  GET /__mock/recent-load?status=fallback[&error=...]
                             what getrecentplayers reports about its file
  GET /__mock/workshop?search=hang|offline[&n=2][&install=never][&timeout=<s>]
                             the next n workshop searches hang or fail, the
                             next install never arrives
  GET /__mock/log?append=<text>[&n=3] | partial=<text> | burst=<bytes>
                 | truncate=1 | restart=1 | stale=1|0
                             write to log-Server.txt behind the server's back:
                             lines, a line with no newline yet, a burst, a cut
                             to the header, a new file (restart=<n> with n
                             rounds of history), or make it a copy the server
                             is not writing
  GET /__mock/perf?score=-20[&interp_fails=3][&worst_tick_ms=80][&emit=1]
                             the next getperf window's values; emit=1 closes
                             it now. tickrate_config=80 etc. change the rates
  GET /__mock/tickstat?choked_pct=12[&snap_p99_bytes=4000][&emit=1][&rate=down|up]
                             the next TICKSTAT line's values (--mod); emit=1
                             writes it now; rate= logs a player's rate step
`;

const opts = parseArgs(process.argv.slice(2));
if (opts.help) {
  console.log(HELP);
  process.exit(0);
}

const WEB_ROOT = opts.web || null;

const log = opts.quiet ? () => {} : (m) => console.log(`  ${m}`);
let state = createState(join(REPO, "fixtures"), { ...opts, log });

// ------------------------------------------------------------------- knobs

const chaos = { fail503: 0, delayMs: 0 };

// ---------------------------------------------------------- digest auth

// Only used with --auth. The real server always requires this; the mock leaves
// it off so a dev tool does not need credentials, but it is here because the
// nonce lifetime is a measured behaviour worth being able to exercise.
const NONCE_LIFETIME_MS = 301_000; // measured: accepted at 300 s, refused at 301
const nonces = new Map(); // nonce -> { issued, used:Set<nc> }

function issueNonce() {
  const n = randomBytes(24).toString("hex");
  nonces.set(n, { issued: Date.now(), used: new Set() });
  return n;
}

function md5(s) {
  return createHash("md5").update(s).digest("hex");
}

function challenge(res, realm, stale) {
  const n = issueNonce();
  res.writeHead(401, {
    ...HARDENING_HEADERS,
    "WWW-Authenticate":
      `Digest qop="auth", realm="${realm}", nonce="${n}"` +
      (stale ? `, stale="true"` : ""),
    "Content-Type": "text/plain",
    "Content-Length": "0",
    Connection: "close",
  });
  res.end();
}

function checkAuth(req, res, realm) {
  const [user, pass] = opts.auth.split(":");
  const header = req.headers.authorization;
  if (!header || !header.startsWith("Digest ")) return challenge(res, realm, false), false;

  const p = Object.fromEntries(
    [...header.slice(7).matchAll(/(\w+)=(?:"([^"]*)"|([^,\s]+))/g)]
      .map((m) => [m[1], m[2] ?? m[3]]));

  const rec = nonces.get(p.nonce);
  if (!rec) return challenge(res, realm, true), false;
  if (Date.now() - rec.issued > NONCE_LIFETIME_MS) {
    nonces.delete(p.nonce);
    return challenge(res, realm, true), false;
  }
  // Each (nonce, nc) pair is accepted once. Replaying an nc is refused stale,
  // which is what "single-use login challenge" in the changelog means.
  if (rec.used.has(p.nc)) return challenge(res, realm, true), false;

  const ha1 = md5(`${user}:${realm}:${pass}`);
  const ha2 = md5(`${req.method}:${p.uri}`);
  const want = md5(`${ha1}:${p.nonce}:${p.nc}:${p.cnonce}:${p.qop}:${ha2}`);
  if (p.username !== user || p.response !== want) {
    return challenge(res, realm, false), false;
  }
  rec.used.add(p.nc);
  return true;
}

// ------------------------------------------------------------------ headers

// Every reply on the 26-09-03 build carries these. The stock pre-09-03 build
// sends none of them.
const HARDENING_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Content-Security-Policy": "frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "no-store",
};

const MIME = {
  ".html": "text/html; charset=utf-8",
  // The real server really does send the obsolete x-javascript form.
  ".js": "application/x-javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".map": "application/json; charset=utf-8",
};

function send(res, status, contentType, body) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body ?? "");
  res.writeHead(status, {
    ...HARDENING_HEADERS,
    "Content-Type": contentType,
    "Content-Length": String(buf.length),
    "Keep-Alive": "timeout=5, max=100",
  });
  res.end(buf);
}

// ------------------------------------------------------------------ routing

const MAX_BODY = 64 * 1024; // the engine's request-body cap

function readBody(req) {
  // A declared Content-Length over the cap is refused without reading the
  // body at all. Otherwise read to the end but stop buffering past the cap, so
  // the client still gets a complete reply rather than a dropped connection --
  // "refusals now return a complete response" is one of the hardening rules.
  const declared = Number(req.headers["content-length"] ?? NaN);
  if (Number.isFinite(declared) && declared > MAX_BODY) {
    return Promise.reject(Object.assign(new Error("body too large"),
                                        { tooLarge: true }));
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) { tooLarge = true; return; }
      chunks.push(c);
    });
    req.on("end", () => {
      if (tooLarge) {
        reject(Object.assign(new Error("body too large"), { tooLarge: true }));
      } else {
        resolve(Buffer.concat(chunks));
      }
    });
    req.on("error", reject);
  });
}

function staticFile(pathname) {
  if (!WEB_ROOT) return null;
  // A path is only static if it resolves to a real file inside the root.
  // Everything else -- including `/` -- is the Lua handler's problem.
  const rel = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  const full = join(WEB_ROOT, rel);
  if (!full.startsWith(WEB_ROOT)) return null;
  try {
    if (!statSync(full).isFile()) return null;
  } catch {
    return null;
  }
  return [MIME[extname(full).toLowerCase()] || "application/octet-stream",
          readFileSync(full)];
}

function control(url, res) {
  const q = url.searchParams;
  switch (url.pathname) {
    case "/__mock/state":
      return send(res, 200, "application/json; charset=utf-8",
                  JSON.stringify(state.raw, null, 2));
    case "/__mock/503":
      chaos.fail503 = Number(q.get("n") ?? 1);
      return send(res, 200, "text/plain", `next ${chaos.fail503} requests -> 503\n`);
    case "/__mock/slow":
      chaos.delayMs = Number(q.get("ms") ?? 0);
      return send(res, 200, "text/plain", `delay ${chaos.delayMs}ms\n`);
    case "/__mock/recent-load": {
      // What getrecentplayers says about its file: ok, fallback, empty or
      // unreadable, and with error= a save that is failing.
      const status = q.get("status") ?? "ok";
      if (!["ok", "fallback", "empty", "unreadable"].includes(status)) {
        return send(res, 400, "text/plain", "status: ok|fallback|empty|unreadable\n");
      }
      state.setRecentStorage(status, q.get("error") ?? undefined);
      return send(res, 200, "text/plain", `recent load -> ${status}\n`);
    }
    case "/__mock/workshop": {
      // search=hang|offline: the next n (default 1) searches never answer,
      // or answer at once with nothing, as an offline server's do -- a stock
      // server restarts a search after 30 s, so a lasting hang needs n=2.
      // install=never: the next install never arrives. timeout=<s>: the mod's
      // search timeout.
      const search = q.get("search") ?? undefined;
      const install = q.get("install") ?? undefined;
      if ((search && !["hang", "offline"].includes(search))
          || (install && install !== "never")) {
        return send(res, 400, "text/plain", "search=hang|offline, install=never\n");
      }
      state.setWorkshop({ search, install,
        n: q.has("n") ? Number(q.get("n")) : undefined,
        timeout: q.has("timeout") ? Number(q.get("timeout")) : undefined });
      return send(res, 200, "text/plain", "workshop set\n");
    }
    case "/__mock/perf": {
      // Any numeric window field (score, quality, tickrate, worst_tick_ms,
      // idle_pct, players, interp_warns, interp_fails, ...) for the next
      // window; <rate>_config for the configured rates; emit=1 closes the
      // window now.
      const fields = {};
      const config = {};
      for (const [k, v] of q) {
        if (k === "emit") continue;
        const n = Number(v);
        if (!Number.isFinite(n)) return send(res, 400, "text/plain", `${k}: not a number\n`);
        if (k.endsWith("_config")) config[k.slice(0, -"_config".length)] = n;
        else fields[k] = n;
      }
      if (Object.keys(config).length) state.setPerfConfig(config);
      state.forcePerf(fields, q.get("emit") === "1");
      return send(res, 200, "text/plain", "perf set\n");
    }
    case "/__mock/tickstat": {
      // Any numeric TICKSTAT field (choked_pct, snap_p99_bytes, hz, ...) for
      // the next line; emit=1 writes it now; rate=down|up logs a player's
      // snapshot rate step.
      const fields = {};
      for (const [k, v] of q) {
        if (k === "emit" || k === "rate") continue;
        const n = Number(v);
        if (!Number.isFinite(n)) return send(res, 400, "text/plain", `${k}: not a number\n`);
        fields[k] = n;
      }
      const rate = q.get("rate") ?? undefined;
      if (rate && rate !== "down" && rate !== "up") {
        return send(res, 400, "text/plain", "rate=down|up\n");
      }
      state.forceTickstat(fields, { emit: q.get("emit") === "1", rateChange: rate });
      return send(res, 200, "text/plain", "tickstat set\n");
    }
    case "/__mock/log": {
      const result = state.logControl({
        restart: q.get("restart") ?? undefined,
        truncate: q.get("truncate") === "1",
        append: q.get("append") ?? undefined,
        n: q.has("n") ? Number(q.get("n")) : 1,
        partial: q.get("partial") ?? undefined,
        burst: q.has("burst") ? Number(q.get("burst")) : 0,
        stale: q.has("stale") ? q.get("stale") === "1" : undefined,
      });
      return send(res, 200, "application/json", JSON.stringify(result));
    }
    case "/__mock/round":
      state.setRound(q.get("started") === "1");
      return send(res, 200, "text/plain", "round set\n");
    case "/__mock/chat": {
      state.playerChat({
        text: q.get("text") ?? undefined,
        player: q.get("player") ?? undefined,
        team: q.has("team") ? Number(q.get("team")) : undefined,
        teamOnly: q.get("teamOnly") === "1",
        steamId: q.has("steamid") ? Number(q.get("steamid")) : undefined,
        n: q.has("n") ? Number(q.get("n")) : 1,
      });
      return send(res, 200, "text/plain", "said\n");
    }
    case "/__mock/cycle-file": {
      state.editCycleFile({
        time: q.has("time") ? Number(q.get("time")) : undefined,
        append: q.get("append") ?? undefined,
        mod: q.get("mod") ?? undefined,
      });
      return send(res, 200, "text/plain", "MapCycle.json edited\n");
    }
    case "/__mock/reset":
      state.stop();
      state = createState(join(REPO, "fixtures"), { ...opts, log });
      return send(res, 200, "text/plain", "reloaded\n");
    default:
      return send(res, 404, "text/plain", "no such control endpoint\n");
  }
}

// With no web users configured, the 09-25 engine refuses any Host that is
// neither localhost nor an IP literal -- static files included. A missing Host
// passes. Measured on 09-26; the table is in docs/CONSTRAINTS.md.
function hostAllowedWithoutLogin(hostHeader) {
  if (!hostHeader) return true;
  let name;
  try { name = new URL(`http://${hostHeader}`).hostname; } catch { return false; }
  if (name.toLowerCase() === "localhost") return true;
  if (/^\[[0-9a-f:.]+\]$/i.test(name)) return true;            // [::1]
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(name);                  // any IPv4 literal
}

const server = createServer(async (req, res) => {
  const host = req.headers.host || `${opts.host}:${opts.port}`;
  const url = new URL(req.url, `http://${host}`);

  // PUT and DELETE are refused by the web server before Lua sees them.
  if (req.method !== "GET" && req.method !== "POST") {
    return send(res, 405, "text/plain", "");
  }

  if (!opts.auth && opts.hostRule && !hostAllowedWithoutLogin(req.headers.host)) {
    log(`WebAdmin - rejected request from ${req.socket.remoteAddress} (no users ` +
        `configured and Host is not localhost or an IP address)`);
    return send(res, 403, "text/plain", "");
  }

  // Origin is compared against the Host header, not against -webdomain.
  // A foreign Origin is refused, and that is why a Vite dev server cannot
  // talk to a real game server directly.
  const origin = req.headers.origin;
  if (origin) {
    let originHost = null;
    try { originHost = new URL(origin).host; } catch { /* Origin: null */ }
    if (originHost !== host) {
      log(`WebAdmin - rejected request from ${req.socket.remoteAddress} ` +
          `(origin does not match host)`);
      return send(res, 403, "text/plain", "");
    }
  }

  if (opts.auth && !checkAuth(req, res, opts.webdomain || "127.0.0.1")) return;

  if (opts.control && url.pathname.startsWith("/__mock/")) {
    return control(url, res);
  }

  if (chaos.delayMs) await new Promise((r) => setTimeout(r, chaos.delayMs));
  if (chaos.fail503 > 0) {
    chaos.fail503--;
    // "Requests give up after 30 s with 503" -- to the client this is the
    // shape of a busy server, and it must be retried rather than surfaced.
    return send(res, 503, "text/plain", "");
  }

  let body = Buffer.alloc(0);
  try {
    if (req.method === "POST") body = await readBody(req);
  } catch (e) {
    if (e.tooLarge) {
      // The cap is measured; this status is not -- an over-cap body was never
      // captured from the real server. Treated as a refusal either way.
      return send(res, 413, "text/plain", "");
    }
    return;
  }

  const file = staticFile(url.pathname);
  if (file) {
    log(`${req.method} ${url.pathname} -> ${file[1].length} B`);
    return send(res, 200, file[0], file[1]);
  }

  // The parameters become one `actions` table, which is all the Lua handler
  // ever sees. It never learns the path, which is why `/` and
  // `/does-not-exist.png` are indistinguishable to it. A GET's come from the
  // query string; a POST's come from the form body only, and its query string
  // is dropped -- measured on 09-26.
  const actions = req.method === "POST"
    ? Object.fromEntries(new URLSearchParams(body.toString("utf8")))
    : Object.fromEntries(url.searchParams);

  const result = state.onWebRequest(actions);
  log(`${req.method} ${url.pathname}${url.search} -> ` +
      `${actions.request ?? "(default)"} ${result ? `${result[1].length} B` : "empty"}`);

  if (!result) {
    // A write. Lua returns nothing, so the engine sends an empty 200 whose
    // Content-Type is text/html rather than JSON.
    return send(res, 200, "text/html; charset=utf-8", "");
  }
  return send(res, 200, `${result[0]}; charset=utf-8`, result[1]);
});

server.listen(opts.port, opts.host, () => {
  console.log(`mock web admin on http://${opts.host}:${opts.port}`);
  console.log(WEB_ROOT
    ? `  serving ${WEB_ROOT}  ->  http://${opts.host}:${opts.port}/index.html`
    : `  no web root; API only (pass --web <dir>)`);
  console.log(`  lua: ${opts.mod ? "webadmin-spa mod" : "stock"}` +
              `${opts.shine ? ` + shine (${[...opts.shine].join(",") || "no plugins"})` : ""}` +
              `   auth: ${opts.auth ? "digest" : `off, host rule ${opts.hostRule ? "on" : "off"}`}` +
              `   reproduced bugs: ${Object.entries(state.bugs)
                .filter(([, on]) => on).map(([k]) => k).join(", ") || "none"}`);
});

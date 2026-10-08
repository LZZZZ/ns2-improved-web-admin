// What kind of line a log line is, for the Log tab's filters.
//
// Read off real logs rather than guessed: the rig's (09-26), and a populated
// round on a Shine server. Three writers share the file --
// the engine (`[ 23.062] Main : ...`, seconds since boot), Lua through
// Shared.Message (bare lines, `Server  : 0.03 : ...`), and Shine
// (`[23:22:02]...`, the server's wall clock) -- so a pattern matches the
// message, never the prefix. First match wins, and chat goes first: a player
// can type "Error" as easily as anything else.

export type LogKind = "chat" | "admin" | "connection" | "error" | "engine" | "other";

export const LOG_KINDS: { kind: LogKind; label: string }[] = [
  { kind: "chat", label: "Chat" },
  { kind: "connection", label: "Connections" },
  { kind: "admin", label: "Admin commands" },
  { kind: "error", label: "Errors and warnings" },
  { kind: "engine", label: "Engine" },
  { kind: "other", label: "Other" },
];

const RULES: [LogKind, RegExp][] = [
  // `Chat All - Admin: text`, `[23:22:45]Chat Team 1 - name: text`, and
  // Shine's improvedchat, `[20:19:32]Chat Team - name: text` (rig, 10-06).
  ["chat", /^(\[\d\d:\d\d:\d\d\])?Chat (All|Team( \d+)?) - /],
  // The game's dispatch receipt (`sv - Admin - 0: : STEAM_0:0:0: sv_say`),
  // Shine's command log (`name[123] ran command sh_x with no arguments.`) and
  // its receipts for the console (`Console[N/A] banned ...`).
  ["admin", /^sv - .* - \d+: : |\] ran command |^(\[\d\d:\d\d:\d\d\])?Console\[N\/A\] /],
  // Connects, auth and names, from the engine and the game.
  ["connection", new RegExp([
    "^Client (connecting|connected|disconnected) \\(",
    "^BeginAuthSession ", "^AuthTicketResponse\\(",
    "Client Authed\\. Steam ID: ",
    " connected\\.$", " is now known as ",
  ].join("|"))],
  ["error", /\b(Error|Warning|ERROR|WARNING)\b|Script error|stack traceback/],
  // The engine's own reports: JIT tracing, perfmon, and the 09-27 tickstat,
  // its reply, a player's rate step and the bwlimit warning (all measured on
  // the rig, REQUIREMENTS item 10).
  ["engine", new RegExp([
    "Script tracing", "^perfmon: ", "^Perf ", "^TICKSTAT\\|", "^tickstat: (on|off)$",
    "^client \\d+: snapshot rate ", "^bwlimit \\d+ bytes/sec at sendrate ",
  ].join("|"))],
];

export function logKind(text: string): LogKind {
  for (const [kind, re] of RULES) {
    if (re.test(text)) return kind;
  }
  return "other";
}

/**
 * How a line is coloured: its kind, except that errors and warnings share a
 * filter and not a colour. A line naming an error is an error, even if it
 * says "warning" too.
 */
export type LogTone = Exclude<LogKind, "error"> | "error" | "warning";

const kErrorWords = /\b(Error|ERROR)\b|Script error|stack traceback/;

export function logTone(kind: LogKind, text: string): LogTone {
  return kind === "error" && !kErrorWords.test(text) ? "warning" : kind;
}

/**
 * A line's own prefix, to colour apart from what it says: the engine's
 * `[ 23.062] Main : ` (seconds since boot and the thread), Shine's
 * `[23:22:02]` (the server's clock) and Lua's `Server  : 0.03 : `.
 */
export interface LogParts { time: string; thread: string; sep: string; text: string }

const kPrefixes: RegExp[] = [
  /^(\[\s*\d+\.\d+\])( )(\S+)( : )/,
  /^(\[\d\d:\d\d:\d\d\])()()()/,
  /^()()(Server|Client)(\s+: [\d.]+ : )/,
];

export function logParts(line: string): LogParts {
  for (const re of kPrefixes) {
    const m = re.exec(line);
    if (m) {
      return { time: m[1]! + m[2]!, thread: m[3]!, sep: m[4]!, text: line.slice(m[0].length) };
    }
  }
  return { time: "", thread: "", sep: "", text: line };
}

/**
 * A chat line's audience and, when it names it, the team. The server writes
 * `Chat All - name: text` and `Chat Team - name: text` with no number
 * (NetworkMessages_Server.lua); `Chat Team 1 - ` is the client's form, which
 * Shine's improvedchat also uses. `msg` is the line after its prefix.
 */
export interface ChatHead { teamOnly: boolean; team: number | null; rest: string }

const kChatHead = /^Chat (All|Team)(?: (\d+))? - /;

export function chatHead(msg: string): ChatHead | null {
  const m = kChatHead.exec(msg);
  if (!m) return null;
  return { teamOnly: m[1] === "Team", team: m[2] ? Number(m[2]) : null, rest: msg.slice(m[0].length) };
}

/**
 * Who said it, out of the names given: the longest name the text after the
 * audience starts with, then ": ". A name can hold ": " itself, so the line
 * cannot be split on it.
 */
export function chatSpeaker(rest: string, names: Iterable<string>): string | null {
  let best: string | null = null;
  for (const name of names) {
    if (rest.startsWith(`${name}: `) && (best === null || name.length > best.length)) best = name;
  }
  return best;
}

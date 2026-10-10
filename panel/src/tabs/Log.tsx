import { Download, MessageSquare } from "lucide-preact";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import type { ServerState } from "../api/types";
import { TEAM_NAMES } from "../api/types";
import type { TeamNumber } from "../api/types";
import {
  acknowledgeReset, loadEarlier, refreshLog, setLogIntervalMs, useLog,
} from "../store/log";
import type { LogState } from "../store/log";
import { updateSettings, useSettings } from "../store/settings";
import { CommandLine } from "../ui/CommandLine";
import { dateTime, fileSize } from "../ui/format";
import { LOG_KINDS, chatHead, chatSpeaker, logKind, logParts, logTone } from "../ui/logkinds";
import type { LogKind } from "../ui/logkinds";

/**
 * The Console tab: the engine's own log, log-Server.txt, as it is written,
 * and the server's command line under it (the 2012 Console tab merged into
 * the Log tab on 2026-10-07, and named Console since).
 *
 * The log shows what the engine writes itself too -- connects and auth,
 * engine errors, Script tracing, Shine's chat and command lines -- and it
 * survives a map change, because the file does. Lines are shown verbatim,
 * identifiers included, by design: this is the server's own
 * record, not a view built for display.
 */
export function Log({ state, onOpenSettings }: {
  state: ServerState;
  onOpenSettings: () => void;
}) {
  if (state.modVersion === null) {
    return (
      <section class="wrap">
        <div class="banner">
          <h2>This server cannot serve its log or command output</h2>
          <p>
            The stock web interface has no way to read <code>log-Server.txt</code>,
            and runs a command only to answer with the ordinary server state, so
            a kick that worked and one that matched nobody look the same. There
            is nothing for this tab to show, and no command line it could
            honour. Commands can still be sent from the Players tab, reported
            as unverified because that is all that is true.
          </p>
          <p>
            Mount this mod's <code>lua/</code> on the server and this tab shows
            the log as the engine writes it, and runs commands with their output.
          </p>
        </div>
      </section>
    );
  }
  return <LogView state={state} onOpenSettings={onOpenSettings} />;
}

function LogView({ state, onOpenSettings }: {
  state: ServerState;
  onOpenSettings: () => void;
}) {
  const settings = useSettings();
  const log = useLog();
  const hidden = useMemo(() => new Set(settings.logHiddenKinds), [settings.logHiddenKinds]);
  const [search, setSearch] = useState("");

  const scroller = useRef<HTMLDivElement>(null);
  const wasAtBottom = useRef(true);
  // Set just before earlier lines are prepended: the height to keep the view
  // anchored to, so what the reader was looking at stays where it was.
  const heightBeforePrepend = useRef<number | null>(null);

  const paused = settings.logRefreshSeconds === 0;

  useEffect(() => {
    setLogIntervalMs(settings.logRefreshSeconds * 1000);
  }, [settings.logRefreshSeconds]);

  const kinds = useMemo(() => log.lines.map((l) => logKind(l.text)), [log.lines]);
  const counts = useMemo(() => {
    const c = new Map<LogKind, number>();
    for (const k of kinds) c.set(k, (c.get(k) ?? 0) + 1);
    return c;
  }, [kinds]);
  const teams = useMemo(() => {
    const byName = new Map<string, TeamNumber>();
    for (const p of state.players) if (!byName.has(p.name)) byName.set(p.name, p.team);
    return byName;
  }, [state.players]);
  const needle = search.trim().toLowerCase();
  const visible = useMemo(() => {
    const out: { off: number; text: string; kind: LogKind; chat: ChatTeam | null }[] = [];
    log.lines.forEach((l, i) => {
      const kind = kinds[i]!;
      if (hidden.has(kind)) return;
      if (needle && !l.text.toLowerCase().includes(needle)) return;
      const chat = kind === "chat" ? chatTeam(`${log.fileId}:${l.off}`, l.text, teams) : null;
      out.push({ off: l.off, text: l.text, kind, chat });
    });
    return out;
  }, [log.lines, log.fileId, kinds, hidden, needle, teams]);

  // Stick to the bottom only if that is where the reader already was, as the
  // console does. Earlier lines arriving at the top keep the view where it is.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    if (heightBeforePrepend.current !== null) {
      el.scrollTop += el.scrollHeight - heightBeforePrepend.current;
      heightBeforePrepend.current = null;
    } else if (wasAtBottom.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [visible]);

  const onScroll = () => {
    const el = scroller.current;
    if (!el) return;
    wasAtBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  const earlier = () => {
    heightBeforePrepend.current = scroller.current?.scrollHeight ?? null;
    void loadEarlier();
  };

  const toggle = (kind: LogKind) => {
    const next = new Set(hidden);
    if (next.has(kind)) next.delete(kind); else next.add(kind);
    updateSettings({ logHiddenKinds: LOG_KINDS.map((k) => k.kind).filter((k) => next.has(k)) });
  };

  if (log.source === "none" && log.unavailable) {
    return (
      <section class="wrap console-tab log-tab">
        <Unavailable {...log.unavailable} />
        <CommandLine shine={state.shine !== null} />
      </section>
    );
  }

  return (
    <section class="wrap console-tab log-tab">
      <div class="toolbar log-filters">
        {LOG_KINDS.map(({ kind, label }) => (
          <label key={kind} class={`check kind-${kind}`}>
            <input type="checkbox" name={`kind-${kind}`} checked={!hidden.has(kind)}
                   onChange={() => toggle(kind)} />
            {kind === "chat" && <MessageSquare class="chat-mark" size={13} aria-hidden="true" />}
            {label} <span class="muted count">{counts.get(kind) ?? 0}</span>
          </label>
        ))}
      </div>
      <div class="toolbar">
        <input type="search" class="log-search" name="log-search"
               placeholder="Find in the lines read" value={search}
               onInput={(e) => setSearch((e.target as HTMLInputElement).value)} />
        <span class="muted log-count">
          {visible.length === log.lines.length
            ? `${log.lines.length} line${log.lines.length === 1 ? "" : "s"}`
            : `${visible.length} of ${log.lines.length} lines`}
        </span>
        <span class="spacer" />
        {log.fileId !== null && (
          <span class="muted log-file"
                title="The date and time in the file's header: when the server started writing it.">
            log-Server.txt{log.fileId && `, started ${log.fileId}`}, {fileSize(log.size)}
          </span>
        )}
        {log.error && <span class="tone-error">{log.error.message}</span>}
        {log.lines.length > 0 && (
          <button type="button" class="btn btn-sm log-save"
                  title={`Save the ${log.lines.length} lines read, every kind, as a text file`
                    + (log.atStart ? "" : ". Load earlier first to include more of the file.")}
                  onClick={() => saveLines(log)}>
            <Download size={14} aria-hidden="true" /> Save
          </button>
        )}
        {state.mapLoadedAt !== null && (
          <span class="muted console-map" title="When the current map loaded, as the server says">
            Last map change: <b>{dateTime(state.mapLoadedAt / 1000)}</b>
          </span>
        )}
      </div>

      {paused && (
        <p class="console-paused">
          Log refresh is off, so new lines appear only when you read them.{" "}
          <button class="btn btn-sm" onClick={() => void refreshLog()}>Read now</button>{" "}
          <button class="link-button" onClick={onOpenSettings}>Settings</button>
        </p>
      )}

      {log.reset && <ResetBanner log={log} />}

      <div class="console log" ref={scroller} onScroll={onScroll}>
        {log.source === "file" && (
          <p class="log-edge muted">
            {log.atStart ? (
              "Start of the file."
            ) : (
              <button class="btn btn-sm log-earlier" disabled={log.loadingEarlier}
                      onClick={earlier}>
                {log.loadingEarlier ? "Reading..." : "Load earlier"}
              </button>
            )}
          </p>
        )}
        {visible.length === 0 && (
          <p class="muted console-empty">
            {log.loading ? "Reading the log..."
              : log.lines.length ? "No line matches." : "The log is empty."}
          </p>
        )}
        {visible.map((line) => {
          const p = logParts(line.text);
          const team = line.chat?.team ?? null;
          return (
            <div key={line.off}
                 class={`log-line logtone-${logTone(line.kind, line.text)}`
                   + (line.chat ? ` chat-team-${team ?? "none"}` : "")}
                 data-off={line.off} data-kind={line.kind}
                 data-team={line.chat && team !== null ? team : undefined}>
              <span class="console-text">
                {p.time && <span class="log-time">{p.time}</span>}
                {p.thread && <span class="log-thread">{p.thread}</span>}
                {p.sep}
                {line.chat && <ChatMark chat={line.chat} />}
                <span class="log-msg">{p.text}</span>
              </span>
            </div>
          );
        })}
      </div>

      <CommandLine shine={state.shine !== null} />
    </section>
  );
}

// ------------------------------------------------------------------ chat

interface ChatTeam { teamOnly: boolean; team: TeamNumber | null }

/**
 * The team of each chat line's speaker, by file and offset, as it was when
 * the line was first shown. The server's chat lines carry no team number
 * (only the client's form does), so the speaker is looked up in the player
 * list: right for a line read as it arrives, the speaker's team now for one
 * read later (the first read's tail, Load earlier), and no team for someone
 * no longer on the server. Kept so a player who switches teams does not
 * repaint what they said before.
 */
const chatTeams = new Map<string, ChatTeam>();
const kMaxChatTeams = 20000;

function chatTeam(key: string, text: string, teams: Map<string, TeamNumber>): ChatTeam | null {
  const known = chatTeams.get(key);
  if (known) return known;
  const head = chatHead(logParts(text).text);
  if (!head) return null;
  let team = head.team !== null && head.team in TEAM_NAMES ? head.team as TeamNumber : null;
  if (team === null) {
    const speaker = chatSpeaker(head.rest, teams.keys());
    team = speaker === null ? null : teams.get(speaker)!;
  }
  if (chatTeams.size >= kMaxChatTeams) chatTeams.clear();
  const found = { teamOnly: head.teamOnly, team };
  chatTeams.set(key, found);
  return found;
}

/**
 * Marks a chat line as chat, whatever colour its team gives it. Its words are
 * a label, not text, so copying a line copies what the file says.
 */
function ChatMark({ chat }: { chat: ChatTeam }) {
  const who = chat.team === null ? "speaker not on the server now" : TEAM_NAMES[chat.team];
  const label = `${chat.teamOnly ? "Team chat" : "Chat"}, ${who}`;
  return (
    <span class="chat-mark" title={label} role="img" aria-label={label}>
      <MessageSquare size={13} aria-hidden="true" />
    </span>
  );
}

// ------------------------------------------------------------------ save

/** The lines held, every kind, as a file named for the log it came from. */
function saveLines(log: LogState) {
  const stamp = (log.fileId ?? "").replace(/[^0-9A-Za-z]+/g, "-").replace(/^-|-$/g, "");
  const blob = new Blob([log.lines.map((l) => l.text).join("\n") + "\n"],
                        { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `log-Server${stamp ? `-${stamp}` : ""}.txt`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function ResetBanner({ log }: { log: LogState }) {
  const [title, text] = log.reset === "new_file"
    ? ["A new log file: the server restarted",
       `It started writing log-Server.txt again${log.fileId ? ` at ${log.fileId}` : ""}. ` +
       "The previous file is log-Server.old.txt on the server, which this tab " +
       "does not read. What is shown now is the new file."]
    : log.reset === "truncated"
      ? ["The log got shorter",
         "The file is now shorter than where this tab had read to, so " +
         "something cut it. What is shown now is its end."]
      : ["Skipped ahead",
         `${fileSize(log.skippedBytes)} were written while this tab was not ` +
         "reading. Rather than read all of it, this shows the end of the file; " +
         "Load earlier reads back from there."];
  return (
    <div class="banner log-reset">
      <h2>{title}</h2>
      <p>
        {text}{" "}
        <button class="btn btn-sm" onClick={acknowledgeReset}>Dismiss</button>
      </p>
    </div>
  );
}

function Unavailable({ path, error, stale }: {
  path: string;
  error: string;
  stale: boolean;
}) {
  return (
    <div class="banner log-unavailable">
      <h2>The server's log cannot be read</h2>
      <p>
        {stale
          ? <span class="log-stale">Found <code>{path}</code>, but this server is not writing it.</span>
          // The engine's message usually names the path already.
          : <span class="mono">{error.includes(path) ? error
              : `${path}: ${error || "no reason given"}`}</span>}
      </p>
      <p>To fix it:</p>
      <ol>
        <li>Stop the server.</li>
        {stale && <li>Delete <code>{path}</code>, an old copy from an earlier run.</li>}
        <li>
          Start it with <code>-logdir</code> set to the same directory
          as <code>-config_path</code>, or with neither flag.
        </li>
      </ol>
      <p>Commands below still run and show their output.</p>
    </div>
  );
}

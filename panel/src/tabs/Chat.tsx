import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { ServerState } from "../api/types";
import { TEAM_NAMES } from "../api/types";
import type { CommandOutcome } from "../store/commands";
import { sendCommand } from "../store/commands";
import {
  acknowledgeChatRestart, getChatState, refreshChat, setChatIntervalMs, setChatMod,
  useChat,
} from "../store/chat";
import { useSettings } from "../store/settings";
import { Masked } from "../ui/Masked";
import { chatArg, logClock, maskSteamId } from "../ui/format";

/** `kMaxChatLength` (Globals.lua:155). The server cuts anything longer. */
const kMaxChatLength = 120;

type Audience = "all" | "1" | "2";

const AUDIENCES: { value: Audience; label: string }[] = [
  { value: "all", label: "All" },
  { value: "1", label: "Marines" },
  { value: "2", label: "Aliens" },
];

/**
 * The chat, as the server records it, and a way to talk to it.
 *
 * The 2012 panel showed this on its Players tab. Its log was the server's
 * last 20 messages, re-read every 2 s; with the mod the server keeps 200, with
 * times, and hands over only what is new.
 */
export function Chat({ state, onOpenSettings }: {
  state: ServerState;
  onOpenSettings: () => void;
}) {
  const settings = useSettings();
  const hasMod = state.modVersion !== null;
  // A layout effect runs before useChat's effect, so the first read already
  // asks the right way.
  useLayoutEffect(() => setChatMod(hasMod), [hasMod]);
  const chat = useChat();

  const [audience, setAudience] = useState<Audience>("all");
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [last, setLast] = useState<CommandOutcome | null>(null);
  /** Whether what was sent is now in the chat, read back from the server. */
  const [landed, setLanded] = useState<boolean | null>(null);

  const scroller = useRef<HTMLDivElement>(null);
  const wasAtBottom = useRef(true);
  const paused = settings.consoleRefreshSeconds === 0;

  useEffect(() => {
    setChatIntervalMs(settings.consoleRefreshSeconds * 1000);
  }, [settings.consoleRefreshSeconds]);

  // Stick to the bottom only if that is where the reader already was.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && wasAtBottom.current) el.scrollTop = el.scrollHeight;
  }, [chat.entries]);

  const onScroll = () => {
    const el = scroller.current;
    if (!el) return;
    wasAtBottom.current =
      el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  const message = chatArg(text);
  const send = async () => {
    if (!message || busy) return;
    setBusy(true);
    const command = audience === "all"
      ? `sv_say ${message}`
      : `sv_tsay ${audience} ${message}`;
    setText("");
    setLanded(null);
    wasAtBottom.current = true;
    const before = getChatState().cursor;
    setLast(await sendCommand(command, hasMod));
    await refreshChat();
    // The chat itself is the receipt. Under Shine sv_say becomes sh_say and
    // prints nothing but Shine's own line, so the command's output cannot
    // say whether it was said; the server's chat can.
    const sent = message.slice(0, kMaxChatLength);
    setLanded(getChatState().entries.some((e) =>
      e.id > before && e.player === "Admin" && e.message === sent));
    setBusy(false);
  };

  if (!chat.available) {
    return (
      <section class="wrap">
        <div class="banner">
          <h2>This server keeps no chat</h2>
          <p>
            It answered the chat request with an empty object, which is what
            the stock web interface does when the game's chat buffer does not
            exist. Chat still reaches the server's log: see the Console
            tab, with this panel's mod.
          </p>
        </div>
      </section>
    );
  }

  return (
    <section class="wrap console-tab chat-tab">
      <div class="toolbar">
        <span class="muted">
          {chat.entries.length} message{chat.entries.length === 1 ? "" : "s"}
          {chat.bufferSize !== null && ` · the server keeps the last ${chat.bufferSize}`}
          {chat.dropped > 0
            && ` · ${chat.dropped} dropped by the server before they were read`}
        </span>
        <span class="spacer" />
        {chat.error && <span class="tone-error">{chat.error.message}</span>}
      </div>

      {!hasMod && (
        <p class="muted chat-stock">
          A stock server keeps only its last 20 messages and gives them no
          times; anything said while this tab was closed may already be gone.
          This panel's mod keeps 200, with times.
        </p>
      )}

      {paused && (
        <p class="console-paused">
          Chat refresh is off, so new messages appear only when you read them
          or send one.{" "}
          <button class="btn btn-sm" onClick={() => void refreshChat()}>
            Read now
          </button>{" "}
          <button class="link-button" onClick={onOpenSettings}>Settings</button>
        </p>
      )}

      {chat.restarted && (
        <div class="banner">
          <h2>The chat restarted</h2>
          <p>
            Message numbering went backwards, which means the map changed: the
            server keeps chat in Lua state and the map change rebuilt it.
            What was said before the change is gone from here; the Log tab
            still has it.{" "}
            <button class="btn btn-sm" onClick={acknowledgeChatRestart}>
              Dismiss
            </button>
          </p>
        </div>
      )}

      <div class="console chat" ref={scroller} onScroll={onScroll}>
        {chat.entries.length === 0 && (
          <p class="muted console-empty">
            {chat.loading ? "Reading the chat..." : "Nobody has said anything yet."}
          </p>
        )}
        {chat.entries.map((e) => (
          <div key={e.id} class="console-line chat-line" data-id={e.id}>
            {e.at !== null && <time>{logClock(e.at)}</time>}
            <span class={`chat-player team-${e.team}`}>{e.player}</span>
            {e.teamOnly && (
              <span class="tag" title={`Team chat: ${TEAM_NAMES[e.team] ?? `team ${e.team}`} only`}>
                TEAM
              </span>
            )}
            {e.steamId !== 0 && (
              <span class="chat-id">
                <Masked value={String(e.steamId)} masked={maskSteamId(e.steamId)}
                        label="Steam id" />
              </span>
            )}
            <span class="console-text">{e.message}</span>
          </div>
        ))}
      </div>

      <div class="console-input chat-input">
        <select
          class="btn"
          value={audience}
          disabled={busy}
          aria-label="Send to"
          onChange={(e) => setAudience((e.target as HTMLSelectElement).value as Audience)}
        >
          {AUDIENCES.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
        </select>
        <input
          type="text"
          value={text}
          maxLength={kMaxChatLength}
          placeholder="Say something as Admin"
          autocomplete="off"
          disabled={busy}
          onInput={(e) => setText((e.target as HTMLInputElement).value)}
          onKeyDown={(e) => { if (e.key === "Enter") void send(); }}
        />
        <button class="btn" disabled={busy || message === ""} onClick={() => void send()}>
          Send
        </button>
      </div>
      {last && (
        <p class={last.tone === "error" ? "console-status tone-error" : "console-status"}>
          <span class="mono">{last.command}</span>{" "}
          {landed
            ? "was said: it is in the server's chat above."
            : (last.output.length > 0 ? `printed: ${last.note}` : last.note)}
        </p>
      )}
    </section>
  );
}

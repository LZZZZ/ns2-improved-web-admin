// The server's command line, on the Console tab: the 2012
// Console tab's input, with what the command printed shown under it.
//
// With the mod's Lua a command comes back with what it printed, so the result
// is shown here as it is; the log above shows it too once the engine writes
// it, along with what everyone else ran. A stock server cannot return output,
// and gets no input: the panel does not offer what it cannot honour.
//
// As the command's name is typed it suggests names from commands.json (read
// from the game's and Shine's Lua by tools/make-commands.py), and once it is
// typed it shows that command's arguments and help. A suggestion, never a
// gate: whatever is typed is sent.

import { useMemo, useState } from "preact/hooks";
import commandList from "../commands.json";
import type { CommandOutcome } from "../store/commands";
import { sendCommand } from "../store/commands";

interface Command {
  name: string;
  args?: string;
  help?: string;
  source: string;
  plugin?: string;
}

const COMMANDS = commandList as Command[];
const kMaxSuggestions = 8;

const SOURCES: Record<string, string> = {
  vanilla: "game",
  shine: "Shine",
  engine: "engine",
};

/** Names starting with what is typed first, then names containing it. */
function suggest(typed: string, shine: boolean): Command[] {
  const t = typed.toLowerCase();
  if (!t || /\s/.test(typed)) return [];
  const usable = COMMANDS.filter((c) => shine || c.source !== "shine");
  const starts = usable.filter((c) => c.name.startsWith(t));
  const contains = usable.filter((c) => !c.name.startsWith(t) && c.name.includes(t));
  const out = starts.concat(contains);
  // Nothing left to suggest once the name is typed out in full.
  return out.length === 1 && out[0]!.name === t ? [] : out.slice(0, kMaxSuggestions);
}

export function CommandLine({ shine }: { shine: boolean }) {
  const [command, setCommand] = useState("");
  const [history, setHistory] = useState<string[]>([]);
  const [historyAt, setHistoryAt] = useState(-1);
  const [busy, setBusy] = useState(false);
  const [last, setLast] = useState<CommandOutcome | null>(null);
  /** The highlighted suggestion; -1 when none is. */
  const [picked, setPicked] = useState(-1);
  /** Escape closes the list until the next keystroke. */
  const [dismissed, setDismissed] = useState(false);

  const suggestions = useMemo(
    () => (dismissed ? [] : suggest(command.trimStart(), shine)),
    [command, shine, dismissed]);
  const typedName = command.trimStart().split(/\s+/)[0]?.toLowerCase() ?? "";
  const current = suggestions.length === 0 && /\S\s/.test(command)
    ? COMMANDS.find((c) => c.name === typedName && (shine || c.source !== "shine")) ?? null
    : null;

  const edit = (value: string) => {
    setCommand(value);
    setPicked(-1);
    setDismissed(false);
  };

  const accept = (c: Command) => edit(`${c.name} `);

  const submit = async () => {
    const text = command.trim();
    if (!text || busy) return;
    setBusy(true);
    setHistory((h) => [text, ...h.filter((c) => c !== text)].slice(0, 50));
    setHistoryAt(-1);
    edit("");
    setLast(await sendCommand(text, true));
    setBusy(false);
  };

  const onKeyDown = (e: KeyboardEvent) => {
    if (suggestions.length > 0) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        // Through -1 (nothing picked, the text as typed) and round again.
        const n = suggestions.length + 1;
        const step = e.key === "ArrowDown" ? 1 : -1;
        setPicked(((picked + 1 + step + n) % n) - 1);
        return;
      }
      if (e.key === "Tab" && !e.shiftKey) {
        e.preventDefault();
        accept(suggestions[Math.max(0, picked)]!);
        return;
      }
      if (e.key === "Enter" && picked >= 0) {
        e.preventDefault();
        accept(suggestions[picked]!);
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        setDismissed(true);
        setPicked(-1);
        return;
      }
    }
    if (e.key === "Enter") { void submit(); return; }
    if (e.key === "ArrowUp" && history.length > 0) {
      e.preventDefault();
      const next = Math.min(historyAt + 1, history.length - 1);
      setHistoryAt(next);
      setCommand(history[next] ?? "");
      setDismissed(true);
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      const next = historyAt - 1;
      setHistoryAt(next);
      setCommand(next < 0 ? "" : (history[next] ?? ""));
      setDismissed(true);
    }
  };

  const active = picked >= 0 && picked < suggestions.length ? picked : -1;

  return (
    <div class="command-line">
      <div class="console-input">
        <span class="prompt" aria-hidden="true">&gt;</span>
        <div class="command-box">
          <input
            type="text"
            name="command"
            value={command}
            placeholder="Type a command; Tab completes its name"
            spellcheck={false}
            autocomplete="off"
            role="combobox"
            aria-autocomplete="list"
            aria-expanded={suggestions.length > 0}
            aria-controls="command-suggestions"
            aria-activedescendant={active >= 0 ? `command-suggestion-${active}` : undefined}
            disabled={busy}
            onInput={(e) => edit((e.target as HTMLInputElement).value)}
            onKeyDown={onKeyDown}
            onBlur={() => setDismissed(true)}
          />
          {suggestions.length > 0 && (
            <ul class="command-suggestions" id="command-suggestions" role="listbox">
              {suggestions.map((c, i) => (
                <li key={c.name} id={`command-suggestion-${i}`} role="option"
                    aria-selected={i === active}
                    class={i === active ? "picked" : ""}
                    // mousedown, not click: the input keeps its focus.
                    onMouseDown={(e) => { e.preventDefault(); accept(c); }}
                    onMouseEnter={() => setPicked(i)}>
                  <span class="mono command-name">{c.name}</span>
                  {c.args && <span class="mono muted command-args">{c.args}</span>}
                  <span class="muted command-help">{c.help}</span>
                  <span class="command-source"
                        title={c.plugin ? `Shine's ${c.plugin} plugin` : undefined}>
                    {SOURCES[c.source] ?? c.source}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
        <button class="btn" disabled={busy || command.trim() === ""}
                onClick={() => void submit()}>
          Run
        </button>
      </div>
      {current && (
        <div class="command-hint muted">
          <span class="mono">{current.name}{current.args ? ` ${current.args}` : ""}</span>
          {current.help && <> &mdash; {current.help}</>}
          {current.plugin && <> (Shine, {current.plugin})</>}
        </div>
      )}
      {last && (
        <div class={last.tone === "error" ? "console-status tone-error" : "console-status"}>
          <span class="mono">{last.command}</span>{" "}
          {last.output.length > 0 ? "printed:" : last.note}
          {last.output.length > 0 && (
            <pre class="command-output">{last.output.join("\n")}</pre>
          )}
        </div>
      )}
    </div>
  );
}

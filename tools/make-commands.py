#!/usr/bin/env python3
"""Regenerate panel/src/commands.json, what the command line suggests as it is typed.

Read from the Lua the server runs, not from documentation:

  * the game's admin commands: every CreateServerAdminCommand in the vanilla
    Lua, with the help string the game itself prints for it;
  * Shine's: every BindCommand in its server-side plugins, with the
    parameters and help Shine's own sh_help prints. Commands that do nothing
    without a player behind them (votes, ready, unstuck, the MOTD) are left
    out: a command run from the panel has no player;
  * the engine's: a short hand-kept list (ENGINE below), from the beta
    CHANGELOGs, since engine commands are C++ and not in any Lua.

The list is a suggestion, not a gate: the command line runs whatever is typed.
Shine's plugins vary by server, so its commands are suggested only when the
server says Shine is loaded, and each names its plugin.

Usage: tools/make-commands.py --lua DIR --shine DIR [--out FILE]
  --lua    the game's ns2/lua directory, in a server install
  --shine  Shine's lua/shine directory (Workshop item 117887554)
Then rebuild the panel.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Engine commands and variables a server operator uses. Wording from the beta
# CHANGELOGs (engine-binaries/, docs/beta-engine.md) and Shine's wrappers.
ENGINE = [
    ("tickrate", "<rate>", "Sets the server tick rate. Not saved; Shine's sh_tickrate saves it."),
    ("sendrate", "<rate>", "Sets how many updates a second are sent to each client. Not saved."),
    ("mr", "<rate>", "Sets the move rate (at most the tick rate). Not saved."),
    ("interp", "<seconds>", "Sets the interpolation delay, in seconds. Not saved."),
    ("bwlimit", "<bytes/s>", "Sets the bandwidth limit per player, in bytes a second. Not saved."),
    ("tickstat", "<seconds>", "Logs tick-rate stability every N seconds; 0 turns it off. Beta engine."),
    ("perfmon", "", "The server performance score and its parts. Beta engine."),
    ("net_interpstats", "[reset]", "How interpolation and movement handle each connection. Beta engine."),
    ("sv_rateadapt", "<0/1>", "Lower a player's update rate when bwlimit chokes it. Beta engine."),
    ("sv_interpadapt", "<0/1>", "Per-player interpolation delay; 0 puts everyone on interp. Beta engine."),
    ("sv_maxtimecredit", "<seconds>", "How much queued movement replays at once; 0 is the old behaviour. Beta engine."),
    ("sv_movetimeslack", "<0/1>", "Movement timing check; 0 restores the old behaviour. Beta engine."),
    ("sv_maxrewind", "<seconds>", "The longest lag-compensation rewind. Beta engine."),
    ("sv_defercreations", "<0/1>", "Let new objects arrive a few updates later under bwlimit. Beta engine."),
    ("sv_lagcompkeepclean", "<0/1>", "Skip re-posing what a rewind did not change. Beta engine."),
    ("sv_lagcomplazy", "<0/1>", "Rewind only when a move needs a collision check. Beta engine."),
    ("sv_hitreglog", "<0/1>", "Log every hit scored during a rewound shot. Beta engine."),
]

# Shine commands that return at once without a player calling them.
PLAYER_ONLY = {
    "sh_vote", "sh_nominate", "sh_votemap", "sh_ready", "sh_unready", "sh_unstuck",
    "sh_motd", "sh_acceptmotd", "sh_switchserver", "sh_votesurrender", "sh_voterandom",
    "sh_goto", "sh_goto_location", "sh_bring",          # move the caller
}

LUA_STRING = r'"((?:[^"\\]|\\.)*)"'


def unquote(s):
    return s.encode().decode("unicode_escape") if "\\" in s else s


def vanilla(lua_dir):
    out = []
    call = re.compile(r'CreateServerAdminCommand\(\s*"Console_(\w+)"\s*,.*?,\s*' + LUA_STRING, re.S)
    for path in sorted(lua_dir.rglob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in call.finditer(text):
            name, help_ = m.group(1), unquote(m.group(2)).strip()
            # The game's convention: "<args>, What it does" or "<args>. What".
            args = ""
            am = re.match(r"^((?:\[?<[^>]*>\]?[ ,]*)+)[,.]?\s*(.*)$", help_)
            if am:
                args, help_ = am.group(1).strip(" ,"), am.group(2)
            help_ = re.sub(r"^-\s*", "", help_)
            out.append({"name": name, "args": args, "help": help_, "source": "vanilla"})
    return out


def braced(text, start):
    """The text of the {...} or (...) that opens at `start`."""
    open_, close = text[start], {"{": "}", "(": ")"}[text[start]]
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_:
            depth += 1
        elif text[i] == close:
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return text[start + 1:]


def param_synopsis(body):
    kind = re.search(r'Type\s*=\s*"(\w+)"', body)
    label = re.search(r'Help\s*=\s*' + LUA_STRING, body)
    word = label.group(1) if label else (kind.group(1) if kind else "arg")
    if kind and not label:
        word = {"client": "player", "clients": "players"}.get(word, word)
    optional = re.search(r'Optional\s*=\s*true', body)
    return f"[{word}]" if optional else f"<{word}>"


def help_text(body):
    m = re.match(r'\s*(?:StringFormat\(\s*)?' + LUA_STRING, body)
    if not m:
        return ""
    # "%s" is a plugin's suffix; a leading "<players> " repeats the synopsis.
    text = re.sub(r"\s*%s", "", unquote(m.group(1))).strip()
    return re.sub(r"^<[^>]*>\s*", "", text)


def shine(shine_dir):
    out = {}
    bind = re.compile(
        r'(?:local\s+(\w+)\s*=\s*)?self:BindCommand\(\s*'
        r'(?:"(\w+)"|self\.CommandNames\.(\w+)\[\s*1\s*\])')
    for path in sorted((shine_dir / "extensions").rglob("*.lua")):
        if path.name in ("client.lua", "shared.lua") or "/lib/" in str(path):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(shine_dir / "extensions")
        plugin = rel.parts[0] if len(rel.parts) > 1 else rel.stem
        names = dict(re.findall(r'(\w+)\s*=\s*\{\s*"(sh_\w+)"', text))   # CommandNames
        binds = list(bind.finditer(text))
        for i, m in enumerate(binds):
            var, lit, key = m.groups()
            name = lit or names.get(key)
            if not name or name in PLAYER_ONLY:
                continue
            end = binds[i + 1].start() if i + 1 < len(binds) else len(text)
            region = text[m.start():end]
            if var:
                pat = re.compile(r'\b' + re.escape(var) + r'\s*:\s*(AddParam|Help)\s*([{(])')
            else:
                pat = re.compile(r'^\s*:\s*(AddParam|Help)\s*([{(])', re.M)
            args, help_ = [], ""
            for pm in pat.finditer(region):
                body = braced(region, pm.end() - 1)
                if pm.group(1) == "AddParam":
                    args.append(param_synopsis(body))
                else:
                    help_ = help_text(body)
            out[name] = {"name": name, "args": " ".join(args), "help": help_,
                         "source": "shine", "plugin": plugin}
        # basecommands builds its all-talk commands in a loop.
        for m in re.finditer(r'GenerateAllTalkCommand\(\s*"(\w+)"[^)]*?' + LUA_STRING + r'\s*\)', text):
            out[m.group(1)] = {"name": m.group(1), "args": "[boolean]",
                               "help": f"Enables or disables {m.group(2)}.",
                               "source": "shine", "plugin": plugin}
    return list(out.values())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--lua", type=Path, required=True,
                    help="the game's ns2/lua directory, in a server install")
    ap.add_argument("--shine", type=Path, required=True,
                    help="Shine's lua/shine directory (Workshop item 117887554)")
    ap.add_argument("--out", type=Path, default=ROOT / "panel/src/commands.json")
    a = ap.parse_args()
    for d in (a.lua, a.shine):
        if not d.is_dir():
            sys.exit(f"not a directory: {d}")

    commands = vanilla(a.lua) + shine(a.shine) + [
        {"name": n, "args": args, "help": h, "source": "engine"} for n, args, h in ENGINE]
    seen, unique = set(), []
    for c in commands:
        if c["name"] not in seen:
            seen.add(c["name"])
            unique.append({k: v for k, v in c.items() if v != ""})
    unique.sort(key=lambda c: c["name"])

    lines = ",\n".join("  " + json.dumps(c, ensure_ascii=False) for c in unique)
    a.out.write_text("[\n" + lines + "\n]\n", encoding="utf-8")
    by = {}
    for c in unique:
        by[c["source"]] = by.get(c["source"], 0) + 1
    print(f"{a.out}: {len(unique)} commands {by}")


if __name__ == "__main__":
    main()

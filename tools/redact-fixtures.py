#!/usr/bin/env python3
"""Redact captured live responses into committable fixtures.

fixtures/live/ holds raw captures from a real server: player names, SteamIDs
and IP addresses. Those must never be committed. This rewrites them into
fixtures/ with stable fakes, so a given real value always maps to the same
fake one and cross-references between fixtures survive.

Only player data is touched. A `name` field is redacted when the record
it sits in is a player (it has a `steamid`) or a ban (it has a `reason`),
and so is a recent player's `names` list of former names;
map names, mod titles and workshop author IDs are public catalogue data
and are left exactly as captured.

A getlog line's text is the server's log verbatim, so it is rewritten too:
every Steam id form, names where the log states them, IPs, and the capturing
machine's paths. `--path OLD=NEW` (repeatable) maps a directory, such as the
server's install, to a neutral one; any home directory left after that
becomes `/home/user`, so a forgotten mapping never publishes a user name.
A line keeps its `off`: like a fake name or `0.0.0.0`, a rewritten path can
change the text's length, and the offsets stay the server's.

Ban ids arrive as numbers from a vanilla server and as digit strings from one
running Shine's ban plugin; both are remapped, and keep their type.

A production server's ban reasons are free text written by admins, and they
name players and carry links. `--reasons` replaces each with filler of the
same length, so layout tests still see the real length spread. The rig's own
captures do not need it.

Usage: tools/redact-fixtures.py [--src DIR] [--out DIR] [--reasons]
                                [--path OLD=NEW ...]
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIVE = ROOT / "fixtures" / "live"
OUT = ROOT / "fixtures"

FAKE_NAMES = ["Skulkovich", "Onosaurus", "Gorgeous", "Lerkwarm", "Fadeaway",
              "Marine Alpha", "Marine Bravo", "Commander Cee"]

# Real value -> fake. Populated as values are met, so the same player keeps
# the same fake identity across every fixture.
names: dict[str, str] = {}
steamids: dict[int, int] = {}

# Bots are already anonymous (steamid 0, ip 0.0.0.0) but their names are real
# community nicknames, so they get redacted too.
BOT_RE = re.compile(r"^\[BOT\]\s*(.+)$")


def fake_name(real: str) -> str:
    if real in names:
        return names[real]
    bot = BOT_RE.match(real)
    base = FAKE_NAMES[len(names) % len(FAKE_NAMES)]
    suffix = "" if len(names) < len(FAKE_NAMES) else f" {len(names)}"
    names[real] = f"[BOT] {base}{suffix}" if bot else f"{base}{suffix}"
    return names[real]


def fake_steamid(real: int) -> int:
    if real == 0:              # bots and panel-originated messages
        return 0
    if real not in steamids:
        steamids[real] = 10000000 + len(steamids)
    return steamids[real]


REDACT_REASONS = False
FILLER = "Reason text redacted from a production server. "

# getlog serves the server's log verbatim, and on a populated server its lines
# carry names, every Steam id form and IP:port (a live round, 2026-09-08:
# `steam user 7656...`, `name[123] ran command`, `Client Authed. Steam ID: n`,
# `Chat All - name: text`, `Client connecting (IP:port)`). A log line is a
# record with `off` and `text`; its text is rewritten with the same stable
# fakes as everything else. Loopback addresses are the server's own and stay.
STEAM64_BASE = 76561197960265728
LOG_RULES = [
    (re.compile(r"\b7656119\d{10}\b"),
     lambda m: str(STEAM64_BASE + fake_steamid(int(m.group(0)) - STEAM64_BASE))),
    (re.compile(r"\bSTEAM_([0-5]):([01]):(\d+)\b"),
     lambda m: "STEAM_0:0:0" if m.group(3) == "0" else
     (lambda a: f"STEAM_{m.group(1)}:{a % 2}:{a // 2}")(
         fake_steamid(int(m.group(3)) * 2 + int(m.group(2))))),
    (re.compile(r"\[U:1:(\d+)\]"), lambda m: f"[U:1:{fake_steamid(int(m.group(1)))}]"),
    (re.compile(r"(Steam ID: )(\d+)"), lambda m: m.group(1) + str(fake_steamid(int(m.group(2))))),
    (re.compile(r"^((?:\[\d\d:\d\d:\d\d\])?)(.+?)\[(\d+)\]( ran command )"),
     lambda m: f"{m.group(1)}{fake_name(m.group(2))}[{fake_steamid(int(m.group(3)))}]{m.group(4)}"),
    (re.compile(r"^((?:\[\d\d:\d\d:\d\d\])?Chat (?:All|Team \d+) - )(.+?)(: )"),
     lambda m: m.group(1) + (m.group(2) if m.group(2) == "Admin" else fake_name(m.group(2))) + m.group(3)),
    (re.compile(r"^(sv - )(.+?)( - )(\d+)(: : )"),
     lambda m: m.group(1) + (m.group(2) if m.group(2) == "Admin" else fake_name(m.group(2)))
     + m.group(3) + m.group(4) + m.group(5)),
    (re.compile(r"^((?:\[\d\d:\d\d:\d\d\])?)(.+) was killed by (.+)$"),
     lambda m: f"{m.group(1)}{fake_name(m.group(2))} was killed by {fake_name(m.group(3))}"),
    (re.compile(r"^(?!Client )(.+) connected\.$"), lambda m: f"{fake_name(m.group(1))} connected."),
    (re.compile(r"^(.+) is now known as (.+)\.$"),
     lambda m: f"{fake_name(m.group(1))} is now known as {fake_name(m.group(2))}."),
    (re.compile(r"\b(?!127\.)\d{1,3}(?:\.\d{1,3}){3}\b"), lambda m: "0.0.0.0"),
]


# --path OLD=NEW, longest OLD first, so a server's directory wins over the
# home directory it sits in.
PATH_MAP: list[tuple[str, str]] = []
HOME_RE = re.compile(r"(?<![\w.])(/home/|/Users/)[^/\s'\"]+")


def redact_paths(text: str) -> str:
    for old, new in PATH_MAP:
        text = text.replace(old, new)
    return HOME_RE.sub(lambda m: m.group(1) + "user", text)


def redact_log_text(text: str) -> str:
    text = redact_paths(text)
    for rule, repl in LOG_RULES:
        text = rule.sub(repl, text)
    return text


def fake_reason(real: str) -> str:
    return (FILLER * (len(real) // len(FILLER) + 1))[:len(real)]


def walk(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "player" and isinstance(v, str) and v:
                out[k] = fake_name(v)              # chat entries
            elif (k == "name" and isinstance(v, str) and v
                  and ("steamid" in node or "reason" in node)):
                out[k] = fake_name(v)              # a player or a ban record
            elif k == "names" and isinstance(v, list) and "steamid" in node:
                out[k] = [fake_name(x) if isinstance(x, str) and x else x
                          for x in v]              # a recent player's former names

            elif k in ("steamid", "steamId", "id") and isinstance(v, int) and k != "id":
                out[k] = fake_steamid(v)
            elif k == "id" and isinstance(v, int) and "reason" in node:
                out[k] = fake_steamid(v)      # ban records key on the SteamID
            elif (k == "id" and isinstance(v, str) and v.isdigit()
                  and "reason" in node):
                out[k] = str(fake_steamid(int(v)))   # Shine's string ids
            elif k == "reason" and isinstance(v, str) and REDACT_REASONS:
                out[k] = fake_reason(v)
            elif k == "ipaddress":
                out[k] = "0.0.0.0"
            elif k == "server_name":
                out[k] = "Example NS2 Server"
            elif k == "webdomain":
                out[k] = "127.0.0.1"
            elif k == "text" and isinstance(v, str) and "off" in node:
                out[k] = redact_log_text(v)        # a line of getlog
            else:
                out[k] = walk(v)
        return out
    if isinstance(node, list):
        return [walk(x) for x in node]
    return node


def main() -> int:
    global REDACT_REASONS
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=pathlib.Path, default=LIVE)
    ap.add_argument("--out", type=pathlib.Path, default=OUT)
    ap.add_argument("--reasons", action="store_true",
                    help="replace ban reasons with same-length filler")
    ap.add_argument("--path", action="append", default=[], metavar="OLD=NEW",
                    help="rewrite a directory in log lines, e.g. "
                         "--path /home/me/ns2-rig=/srv/ns2 (repeatable)")
    args = ap.parse_args()
    REDACT_REASONS = args.reasons
    for spec in args.path:
        old, sep, new = spec.partition("=")
        if not sep or not old:
            ap.error(f"--path needs OLD=NEW, got {spec!r}")
        PATH_MAP.append((old.rstrip("/"), new.rstrip("/")))
    PATH_MAP.sort(key=lambda p: -len(p[0]))
    if not args.src.is_dir():
        print(f"no captures in {args.src}", file=sys.stderr)
        return 1
    args.out.mkdir(exist_ok=True)
    written = 0
    for src in sorted(args.src.glob("*.json")):
        if src.stat().st_size == 0:
            continue
        try:
            data = json.loads(src.read_text())
        except json.JSONDecodeError:
            print(f"  skip  {src.name} (not JSON)")
            continue
        (args.out / src.name).write_text(json.dumps(walk(data), indent=2) + "\n")
        written += 1
        print(f"  ok    {src.name}")
    print(f"\n{written} fixtures written to {args.out}")
    print(f"identities remapped: {len(names)} names, {len(steamids)} SteamIDs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

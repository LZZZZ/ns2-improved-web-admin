#!/usr/bin/env python3
"""Regenerate panel/src/whitelist.json, the ranked-mod whitelist the panel ships.

The panel asks the server first: the mod's `getwhitelist` reads the list from
Steam (docs/CONSTRAINTS.md item 17). This file is what the panel falls back on when it cannot --
a stock server, or a server that could not reach Steam -- so it carries the
date it was read, and the panel shows it.

The whitelist is the "Required items" of the unlisted Workshop item
2909200101; the hotfix mods, which the engine never checks, are those of
2633436686. Both ids are hard-coded in libSpark_Network.so
(ModServices::s_LiveModIds). Steam's keyless API answers "not found" for
unlisted items, so this reads the items' public pages, as the mod's Lua does,
and needs no API key.

Needs curl. Usage: tools/make-whitelist.py [--out panel/src/whitelist.json]
Then rebuild the panel.
"""

import argparse
import html
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PAGE = "https://steamcommunity.com/sharedfiles/filedetails/?id="
WHITELIST_ID = "2909200101"
HOTFIX_LIST_ID = "2633436686"

# Each item is <a href=".../filedetails/?id=N"><div class="requiredItem">title
# </div></a>, back to back after the block's opening tag; the first thing that
# is not one ends the list. The same walk as ParseRequiredItems in the Lua.
BLOCK = re.compile(r'id="RequiredItems"[^>]*>')
ITEM = re.compile(r'\s*<a [^>]*?filedetails/\?id=(\d+)"[^>]*>\s*'
                  r'<div class="requiredItem">(.*?)</div>\s*</a>', re.S)


def required_items(item_id):
    # Through curl, not urllib: on 2026-10-08 Steam Community answered urllib
    # 429 Too Many Requests over and over while curl, from the same address
    # and with the same User-Agent, got 200. The engine's HTTP is libcurl too.
    # A real 429 (a burst of requests) clears within a minute.
    for attempt in range(4):
        res = subprocess.run(
            ["curl", "-sS", "--max-time", "30", "-w", "\n%{http_code}", PAGE + item_id],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        if res.returncode != 0:
            sys.exit(f"item {item_id}: curl failed: {res.stderr.strip()}")
        page, _, status = res.stdout.rpartition("\n")
        if status == "200":
            break
        if status != "429" or attempt == 3:
            sys.exit(f"item {item_id}: Steam answered HTTP {status}")
        print(f"item {item_id}: 429, waiting 30 s", file=sys.stderr)
        time.sleep(30)
    block = BLOCK.search(page)
    if not block:
        sys.exit(f"item {item_id}: the page has no Required items ({len(page)} bytes)")
    items, pos = [], block.end()
    while (m := ITEM.match(page, pos)):
        items.append({"id": m.group(1), "name": html.unescape(m.group(2)).strip()})
        pos = m.end()
    if not items:
        sys.exit(f"item {item_id}: Required items is empty")
    return items


def main():
    ap = argparse.ArgumentParser()
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--out", default=root / "panel" / "src" / "whitelist.json", type=Path)
    args = ap.parse_args()

    whitelist = required_items(WHITELIST_ID)
    time.sleep(2)
    hotfix = required_items(HOTFIX_LIST_ID)
    doc = {
        "read_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "branch": "live",
        "whitelist_id": WHITELIST_ID,
        "hotfix_list_id": HOTFIX_LIST_ID,
        "whitelist": whitelist,
        "hotfix": hotfix,
    }
    # One item per line, so a regeneration diffs as the mods that changed.
    lines = ["{"]
    for key in ("read_at", "branch", "whitelist_id", "hotfix_list_id"):
        lines.append(f"  {json.dumps(key)}: {json.dumps(doc[key])},")
    for key in ("whitelist", "hotfix"):
        lines.append(f"  {json.dumps(key)}: [")
        body = [f"    {json.dumps(i, ensure_ascii=False)}" for i in doc[key]]
        lines.append(",\n".join(body))
        lines.append("  ]," if key == "whitelist" else "  ]")
    lines.append("}")
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    json.loads(args.out.read_text(encoding="utf-8"))
    print(f"wrote {args.out}: {len(whitelist)} whitelisted, {len(hotfix)} hotfix mods, "
          f"read {doc['read_at']}")


if __name__ == "__main__":
    main()

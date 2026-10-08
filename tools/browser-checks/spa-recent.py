#!/usr/bin/env python3
"""Gate: the Recent players tab, driven in a real browser against three mocks.

The tab exists so a player who has already left can still be found and
banned. So the checks are about finding and banning, and about the tab
saying plainly what it cannot know:

  * stock      the tab explains that the server keeps no such list, and
               never asks for one
  * --mod      the window and capacity are stated from the server's reply;
               search finds a player by part of a name, by a former name, by
               a STEAM_X:Y:Z id and by IP; IPs are shown and Steam ids masked,
               beside links to the player's Steam profile and ns2panel.com;
               a kicked player turns from connected to "left"; Ban sends
               sv_ban with `;` stripped and reports what the server printed;
               a banned row disables Ban and says why; a torn, unreadable or
               failing save file is reported; sort and filter survive a poll
  * --shine    a player Shine already bans is marked, and Ban goes out as
               sh_banid and is stored under the player's name, where vanilla
               keeps "Unknown"

and on all of them: no uncaught exceptions, nothing fetched from a third
party.

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8094 --web web --mod
    node mock/server.js --port 8096 --web web --mod --shine
"""
import asyncio, json, os, sys, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
SHINE = os.environ.get("SHINE_URL", "http://127.0.0.1:8096")
PORT = 9230

ROWS = "document.querySelectorAll('.recent-table tbody tr[data-steamid]')"
TAB = "Recent players"
results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<58} {detail}")
    return ok


def control(base, path):
    with urllib.request.urlopen(f"{base}/__mock/{path}", timeout=5) as r:
        r.read()


def command(base, cmd):
    q = urllib.parse.urlencode({"request": "runcommand", "cmd": cmd})
    with urllib.request.urlopen(f"{base}/?{q}", timeout=5) as r:
        r.read()


async def type_into(c, selector, text):
    await c.eval("(()=>{const i=document.querySelector(%s);i.value=%s;"
                 "i.dispatchEvent(new Event('input',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(text)))


async def choose(c, selector, value):
    await c.eval("(()=>{const s=document.querySelector(%s);s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(value)))


async def open_tab(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await asyncio.sleep(3)
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={json.dumps(TAB)}).click()")
    await asyncio.sleep(1.5)


async def click_tab(c, label):
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={json.dumps(label)}).click()")
    await asyncio.sleep(1.5)


async def ban_name(c, steam_id):
    """The name the Bans tab shows for a ban, then back to this tab."""
    await click_tab(c, "Bans")
    name = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"%s\"]')"
                        "?.querySelector('.name-cell').textContent||''" % steam_id)
    await click_tab(c, TAB)
    return str(name)


async def row_ids(c):
    return str(await c.eval(f"[...{ROWS}].map(r=>r.dataset.steamid).join(',')"))


def row(steam_id):
    return f"document.querySelector('.recent-table tr[data-steamid=\"{steam_id}\"]')"


async def cell(c, steam_id, index):
    return str(await c.eval(f"{row(steam_id)}?.cells[{index}].textContent||''"))


async def search(c, text):
    await type_into(c, ".recent-tab input[type=search]", text)
    await asyncio.sleep(0.3)
    return await row_ids(c)


async def last_activity(c):
    cmd = await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''")
    note = await c.eval("document.querySelector('.cmd-confirm .note')?.textContent||''")
    return str(cmd), str(note)


async def ban_row(c, steam_id, duration="1440", reason=""):
    await c.eval(f"{row(steam_id)}.querySelector('.ban').click()")
    await asyncio.sleep(0.3)
    await choose(c, ".ban-row select[name=duration]", duration)
    await type_into(c, ".ban-row input[name=reason]", reason)
    await asyncio.sleep(0.2)
    await c.eval("document.querySelector('.ban-row button[type=submit]').click()")
    await asyncio.sleep(1.5)


async def notes(c):
    return str(await c.eval("[...document.querySelectorAll('.storage-note')]"
                            ".map(n=>n.textContent).join('|')"))


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    control(STOCK, "reset")
    mark = len(c.events)
    await open_tab(c, STOCK)
    banner = str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                              ".map(h=>h.textContent).join('|')"))
    check("the tab explains the stock server keeps no list",
          "keeps no list of recent players" in banner, banner[:60])
    asked = [e for e in c.events[mark:] if e["method"] == "Network.requestWillBeSent"
             and "getrecentplayers" in e["params"]["request"]["url"]]
    check("and never asks for one", not asked, f"{len(asked)} requests")


async def mod(c):
    print(f"\n== --mod ({MOD})")
    control(MOD, "reset")
    await open_tab(c, MOD)

    count = str(await c.eval("document.querySelector('.recent-count').textContent"))
    check("window and capacity are stated",
          "last 24 hours" in count and "up to 100" in count, count)
    check("the count is the server's", count.startswith("7 of 7 players"), count)
    ids = await row_ids(c)
    check("connected first, then most recently left",
          ids.startswith("10000000,10000020,10000021,"), ids)
    check("the connected player says so", (await cell(c, 10000000, 3)).startswith("connected"),
          await cell(c, 10000000, 3))
    icon = json.loads(await c.eval(
        f"JSON.stringify((s=>s&&[!!s.querySelector('svg'),s.title])"
        f"({row(10000000)}?.cells[3].querySelector('.status-icon')))"))
    check("as an icon, its word on hover", icon and icon[0] and icon[1].startswith("connected"),
          str(icon))
    align = await c.eval(f"getComputedStyle({row(10000000)}.cells[5]).textAlign")
    check("Played is left-aligned, like its header", align in ("left", "start"), align)
    check("a player who left says when", (await cell(c, 10000020, 3)).startswith("left 5m ago"),
          await cell(c, 10000020, 3))

    check("IPs are shown in the clear", await cell(c, 10000020, 2) == "192.0.2.10",
          await cell(c, 10000020, 2))
    masked = await cell(c, 10000020, 1)
    check("Steam ids are masked by default", "10000020" not in masked, masked)
    links = json.loads(await c.eval(
        f"JSON.stringify([...{row(10000020)}.cells[1].querySelectorAll('a')]"
        ".map(a=>[a.href,a.rel,a.target]))"))
    check("the player links to Steam by SteamID64 and to ns2panel.com",
          [l[0] for l in links] == ["https://steamcommunity.com/profiles/76561197970265748",
                                    "https://ns2panel.com/player/10000020"], str(links)[:90])
    check("both in a new tab, without a referrer",
          all("noreferrer" in l[1] and l[2] == "_blank" for l in links))
    check("a name with markup is text", "Commander <Cee>" in await cell(c, 10000024, 0),
          await cell(c, 10000024, 0))
    check("a player with no name seen says so",
          "(no name seen)" in await cell(c, 10000023, 0), await cell(c, 10000023, 0))
    check("former names are shown", "was Gorge Us, gorgeous_1" in await cell(c, 10000020, 0),
          await cell(c, 10000020, 0))

    check("part of a name finds the player", await search(c, "GORG") == "10000020")
    check("a former name finds the player", await search(c, "noobsl") == "10000022")
    # Account 10000020 is STEAM_0:0:5000010: Y*2+X.
    check("a STEAM_X:Y:Z id finds the player",
          await search(c, "STEAM_0:0:5000010") == "10000020")
    check("part of an IP finds the players",
          await search(c, "198.51.100.") == "10000021,10000024")
    check("a filter that matches nobody says so",
          await search(c, "zzzz") == "" and "No players match" in str(
              await c.eval("document.querySelector('.recent-table tbody').textContent")))
    await search(c, "")

    await ban_row(c, 10000021, duration="60", reason="alt; sv_cheats 1")
    cmd, note = await last_activity(c)
    check("Ban is sent as sv_ban with the row's id",
          cmd.startswith("sv_ban 10000021 60 "), cmd)
    check("`;` never reaches the command line", ";" not in cmd, cmd)
    check("and reports what the server printed",
          "Player with SteamId 10000021 has been banned" in note, note[:60])
    check("the ban form closes", await c.eval("!document.querySelector('.ban-row')") is True)
    tag = await cell(c, 10000021, 3)
    check("the row is marked banned", "banned" in tag, tag)
    disabled = await c.eval(f"{row(10000021)}.querySelector('.ban').disabled")
    title = str(await c.eval(f"{row(10000021)}.querySelector('.ban').title"))
    check("and its Ban is disabled with the reason",
          disabled is True and "Unban from the Bans tab" in title, title)
    name = await ban_name(c, 10000021)
    check("vanilla still records an absent player as Unknown (by decision)",
          name == "Unknown", name)

    # Sort by name and filter, then let a poll land and a player leave.
    await c.eval("[...document.querySelectorAll('.recent-table thead th')]"
                 ".find(t=>t.textContent.startsWith('Player')).click()")
    await search(c, "a")
    before = await row_ids(c)
    command(MOD, "sv_kick 10000000")
    await asyncio.sleep(11.5)      # past one 10 s poll
    check("filter and sort survive a poll",
          await row_ids(c) == before and await c.eval(
              "document.querySelector('.recent-tab input[type=search]').value") == "a",
          before)
    await search(c, "")
    status = await cell(c, 10000000, 3)
    check("a kicked player turns from connected to left", status.startswith("left"), status)

    check("no storage note while the file is fine", await notes(c) == "")
    control(MOD, "recent-load?status=fallback")
    await open_tab(c, MOD)
    check("a torn save is reported", "was torn" in await notes(c), (await notes(c))[:60])
    control(MOD, "recent-load?status=unreadable")
    await open_tab(c, MOD)
    check("an unreadable save is reported", "could not be read" in await notes(c),
          (await notes(c))[:60])
    control(MOD, "recent-load?status=ok&error=disk%20full")
    await open_tab(c, MOD)
    check("a failing save is reported, with its reason",
          "not being saved (disk full)" in await notes(c), (await notes(c))[:60])


async def shine(c):
    print(f"\n== --mod --shine ({SHINE})")
    control(SHINE, "reset")
    await open_tab(c, SHINE)
    tag = await cell(c, 10000011, 3)
    check("a player Shine already bans is marked", "banned" in tag, tag)
    check("and cannot be banned again",
          await c.eval(f"{row(10000011)}.querySelector('.ban').disabled") is True)
    await c.eval(f"{row(10000020)}.querySelector('.ban').click()")
    await asyncio.sleep(0.3)
    hint = str(await c.eval("document.querySelector('.ban-row .form-hint')?.textContent||''"))
    check("the form says it goes through Shine", "sh_banid" in hint, hint)
    await c.eval(f"{row(10000020)}.querySelector('.ban').click()")   # close it again
    await ban_row(c, 10000020)
    cmd, note = await last_activity(c)
    check("Ban is sent as sh_banid", cmd.startswith("sh_banid 10000020 1440 "), cmd)
    check("and reports Shine's line", "Console[N/A] banned <unknown>[10000020]" in note,
          note[:90])
    check("and says the ban was named from recent players",
          note.startswith('Named the ban of 10000020 "Gorgeous", from recent players.'),
          note[:70])
    name = await ban_name(c, 10000020)
    check("the Bans tab shows the name, not <unknown>", name == "Gorgeous", name)


async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('improved-webadmin.settings'); } catch {}")
            await stock(c)
            await mod(c)
            await shine(c)

            print("\n== every server")
            exceptions = [e for e in c.events if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions", not exceptions, str(len(exceptions)))
            urls = [e["params"]["request"]["url"] for e in c.events
                    if e["method"] == "Network.requestWillBeSent"]
            foreign = sorted({u for u in urls if not u.startswith((STOCK, MOD, SHINE))})
            check("every request went to the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

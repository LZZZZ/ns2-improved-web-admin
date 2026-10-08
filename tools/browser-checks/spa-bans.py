#!/usr/bin/env python3
"""Gate: the Bans tab, driven in a real browser against four mocks.

A ban list is where the old panel lied most quietly: it listed bans that had
expired, offered an Unban that could never match, and on a Shine server it
had no idea whose list it was showing. So the checks are about what the tab
claims, per kind of server:

  * stock      expired bans hidden, Unban disabled with its reason, a ban
               reported as unverified
  * --mod      a ban reports what the server printed, an unban that removed
               something says it printed nothing, an unban of a ban that is
               already gone says so, Steam ids parse from any common form
  * --shine    Shine's list with who banned and when, 6e+24 read as
               permanent, bans and unbans sent as sh_banid / sh_unban (a
               vanilla sv_ban of an absent id is a phantom ban there), and the
               Players tab's Ban 24h going the same way
  * stock + Shine   the list arrives in a new order on every poll; the rows
               must not move

and on all of them: Steam ids masked until asked, `;` never reaching the
command line, no uncaught exceptions, nothing fetched from a third party.

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8094 --web web --mod
    node mock/server.js --port 8096 --web web --mod --shine
    node mock/server.js --port 8098 --web web --shine
"""
import asyncio, json, os, sys, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
SHINE = os.environ.get("SHINE_URL", "http://127.0.0.1:8096")
STOCK_SHINE = os.environ.get("STOCK_SHINE_URL", "http://127.0.0.1:8098")
PORT = 9228

ROWS = "document.querySelectorAll('.bans-table tbody tr[data-steamid]')"
results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<58} {detail}")
    return ok


def http(base, query):
    with urllib.request.urlopen(f"{base}/?{urllib.parse.urlencode(query)}",
                                timeout=5) as r:
        return json.loads(r.read())


def reset(base):
    with urllib.request.urlopen(f"{base}/__mock/reset", timeout=5) as r:
        r.read()


async def type_into(c, selector, text):
    await c.eval("(()=>{const i=document.querySelector(%s);i.value=%s;"
                 "i.dispatchEvent(new Event('input',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(text)))


async def choose(c, selector, value):
    await c.eval("(()=>{const s=document.querySelector(%s);s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(value)))


async def open_tab(c, base, label):
    await c.send("Page.navigate", url=base + "/index.html")
    await asyncio.sleep(3)
    await click_tab(c, label)


async def click_tab(c, label):
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={json.dumps(label)}).click()")
    await asyncio.sleep(1.5)


async def row_ids(c):
    return await c.eval(f"[...{ROWS}].map(r=>r.dataset.steamid).join(',')")


async def last_activity(c):
    cmd = await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''")
    note = await c.eval("document.querySelector('.cmd-confirm .note')?.textContent||''")
    return str(cmd), str(note)


async def ban_via_form(c, steam_id, duration="1440", reason=""):
    await type_into(c, "input[name=steamid]", steam_id)
    await choose(c, "select[name=duration]", duration)
    await type_into(c, "input[name=reason]", reason)
    await asyncio.sleep(0.2)
    await c.eval("document.querySelector('.bans-tab form button[type=submit]').click()")
    await asyncio.sleep(1.5)


async def unban_row(c, steam_id):
    await c.eval(f"document.querySelector('.bans-table tr[data-steamid=\"{steam_id}\"] .unban')"
                 ".click()")
    await asyncio.sleep(1.5)


async def common(c, base):
    """What must hold on every server."""
    masked = await c.eval(f"[...{ROWS}].map(r=>r.cells[1].textContent).join('|')")
    ids = str(await row_ids(c)).split(",")
    check("Steam ids are masked by default",
          not any(i and i in str(masked) for i in ids), str(masked)[:40])


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    reset(STOCK)
    await open_tab(c, STOCK, "Bans")
    raw = http(STOCK, {"request": "getbanlist"})
    check("the stock server still lists an expired ban", len(raw) == 1, f"{len(raw)} listed")
    check("the tab hides it", await c.eval(f"{ROWS}.length") == 0,
          str(await c.eval("document.querySelector('.bans-count').textContent")))
    banner = str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                              ".map(h=>h.textContent).join('|')"))
    check("stock banner is shown", "Stock server Lua" in banner, banner)

    await ban_via_form(c, "99999991", reason="evil; sv_cheats 1")
    cmd, note = await last_activity(c)
    check("a ban is sent as sv_ban", cmd.startswith("sv_ban 99999991 1440 "), cmd)
    check("`;` never reaches the command line", ";" not in cmd, cmd)
    check("and is reported as unverified, not as success",
          "unverified" in note.lower() and "success" not in note.lower(), note[:60])
    await asyncio.sleep(1)
    button = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"99999991\"] .unban')"
                          "?.disabled")
    check("the new ban is listed, with Unban disabled", button is True)
    reason = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"99999991\"] .unban')"
                          "?.title||''")
    check("and the button says why", "stock" in str(reason).lower(), str(reason)[:50])
    await common(c, STOCK)


async def mod(c):
    print(f"\n== --mod ({MOD})")
    reset(MOD)
    await open_tab(c, MOD, "Bans")
    banner = str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                              ".map(h=>h.textContent).join('|')"))
    check("no stock banner", "Stock server Lua" not in banner, banner or "(none)")
    check("says whose list it is", "the game's ban list" in str(
        await c.eval("document.querySelector('.bans-count').textContent")))

    # STEAM_0:1:49999995 is account 99999991: Y*2+X.
    await ban_via_form(c, "STEAM_0:1:49999995")
    cmd, note = await last_activity(c)
    check("STEAM_0:X:Y is parsed to the account id", cmd.startswith("sv_ban 99999991 1440"), cmd)
    check("the ban reports what the server printed",
          "Player with SteamId 99999991 has been banned" in note, note[:60])
    expires = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"99999991\"]')"
                           "?.querySelector('.expires-cell').textContent||''")
    check("its expiry reads as time left", str(expires).startswith("in "), str(expires))

    await ban_via_form(c, "76561198060265720", duration="0")   # a SteamID64
    cmd, _ = await last_activity(c)
    check("a SteamID64 is parsed to the account id", cmd.startswith("sv_ban 99999992 0"), cmd)
    expires = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"99999992\"]')"
                           "?.querySelector('.expires-cell').textContent||''")
    check("a permanent ban reads Permanent", expires == "Permanent", str(expires))

    await unban_row(c, "99999991")
    cmd, note = await last_activity(c)
    check("unban is sent as sv_unban", cmd == "sv_unban 99999991", cmd)
    check("a working unban says it printed nothing, not success",
          "printed nothing" in note and "success" not in note.lower(), note[:60])
    gone = await c.eval("!document.querySelector('.bans-table tr[data-steamid=\"99999991\"]')")
    check("and the row is gone", gone is True)

    # Remove the ban behind the panel's back, then press its stale Unban.
    http(MOD, {"request": "runcommand", "cmd": "sv_unban 99999992"})
    await unban_row(c, "99999992")
    _, note = await last_activity(c)
    check("an unban of a ban already gone says so",
          "No matching Steam Id in ban list: 99999992" in note, note[:60])
    await common(c, MOD)


async def shine(c):
    print(f"\n== --mod --shine ({SHINE})")
    reset(SHINE)
    await open_tab(c, SHINE, "Bans")
    check("says the list is Shine's", "Shine's ban list" in str(
        await c.eval("document.querySelector('.bans-count').textContent")))
    heads = str(await c.eval("[...document.querySelectorAll('.bans-table thead th')]"
                             ".map(t=>t.textContent).join('|')"))
    check("Banned by and Issued columns are shown",
          "Banned by" in heads and "Issued" in heads, heads)
    check("newest first by default", str(await row_ids(c)).startswith("10000013,"),
          str(await row_ids(c)))
    six = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"10000011\"]')"
                       "?.querySelector('.expires-cell').textContent||''")
    check("the 6e+24 ban reads Permanent", six == "Permanent", str(six))
    by = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"10000011\"]')"
                      ".cells[4].textContent")
    check("who banned is shown", by == "Adminator", str(by))
    tag = await c.eval("[...document.querySelectorAll('.stats .tag')]"
                       ".map(t=>t.textContent).join('|')")
    check("the header says Shine is loaded", "SHINE" in str(tag), str(tag))

    await ban_via_form(c, "99999991", reason="alt; sv_cheats 1")
    cmd, note = await last_activity(c)
    check("a ban is sent as sh_banid, not sv_ban",
          cmd.startswith("sh_banid 99999991 1440 "), cmd)
    check("`;` never reaches the command line", ";" not in cmd, cmd)
    check("and reports Shine's line, without its receipt",
          note.startswith("Console[N/A] banned <unknown>[99999991] for 1 day.")
          and "ran command" not in note, note[:70])
    check("the ban is listed", await c.eval(
        "!!document.querySelector('.bans-table tr[data-steamid=\"99999991\"]')") is True)

    await unban_row(c, "99999991")
    cmd, note = await last_activity(c)
    check("unban is sent as sh_unban", cmd == "sh_unban 99999991", cmd)
    check("and reports Shine's line", note == "Console[N/A] unbanned 99999991.", note)
    await common(c, SHINE)

    await click_tab(c, "Players")
    await c.eval("[...document.querySelectorAll('table tbody tr')]"
                 ".find(r=>!r.textContent.includes('BOT'))"
                 ".querySelectorAll('.actions button')[1].click()")
    await asyncio.sleep(1.5)
    cmd, _ = await last_activity(c)
    check("Players' Ban 24h goes through sh_banid too",
          cmd.startswith("sh_banid ") and " 1440 WebUI" in cmd, cmd)


async def stock_shine(c):
    print(f"\n== stock server running Shine ({STOCK_SHINE})")
    reset(STOCK_SHINE)
    orders = {",".join(b["id"] for b in http(STOCK_SHINE, {"request": "getbanlist"}))
              for _ in range(6)}
    check("the server's own order changes between calls", len(orders) > 1,
          f"{len(orders)} orders in 6 calls")
    await open_tab(c, STOCK_SHINE, "Bans")
    first = await row_ids(c)
    await asyncio.sleep(11)      # past one 10 s poll
    await c.eval("document.querySelector('.statusbar .btn').click()")
    await asyncio.sleep(1)
    check("the rows do not move across polls", await row_ids(c) == first, str(first))
    six = await c.eval("document.querySelector('.bans-table tr[data-steamid=\"10000011\"]')"
                       "?.querySelector('.expires-cell').textContent||''")
    check("6e+24 reads Permanent on the stock path too", six == "Permanent", str(six))


async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            # Every destructive action asks first; answer yes without a human.
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('webadmin-spa.settings'); } catch {}")
            await stock(c)
            await mod(c)
            await shine(c)
            await stock_shine(c)

            print("\n== every server")
            exceptions = [e for e in c.events if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions", not exceptions, str(len(exceptions)))
            urls = [e["params"]["request"]["url"] for e in c.events
                    if e["method"] == "Network.requestWillBeSent"]
            ours = (STOCK, MOD, SHINE, STOCK_SHINE)
            foreign = sorted({u for u in urls if not u.startswith(ours)})
            check("every request went to the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

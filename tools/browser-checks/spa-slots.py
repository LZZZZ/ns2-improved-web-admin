#!/usr/bin/env python3
"""Gate: the Reserved Slots tab, driven in a real browser against the mock.

The 2012 panel's Reserved Slots tab never worked -- its one request is broken
in the stock Lua (docs/CONSTRAINTS.md item 7) and answered 200 anyway. So the
checks are about what this one claims:

  * stock      the amount is set through sv_reserved_slots, which works there,
               and reported as unverified; the removal bug is disclosed
  * --mod      the amount is capped at max players (the server ignores more
               without a word), a set reports what the server printed and
               reads back, a slot name loses its `;` and spaces before it
               becomes a console argument, a duplicate name is flagged, and a
               removal says what it removed
  * --shine=…,reservedslots   Shine owns the count: it is shown and set with
               sh_setresslots, and the vanilla list is read-only

and on all of them: Steam ids masked until asked, no uncaught exceptions,
nothing fetched from a third party.

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8094 --web web --mod
    node mock/server.js --port 8097 --web web --mod --shine=ban,reservedslots,mapvote
"""
import asyncio, json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
SHINE_SLOTS = os.environ.get("SHINE_SLOTS_URL", "http://127.0.0.1:8097")
PORT = 9229

ROWS = "document.querySelectorAll('.slots-table tbody tr[data-steamid]')"
results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<58} {detail}")
    return ok


def reset(base):
    with urllib.request.urlopen(f"{base}/__mock/reset", timeout=5) as r:
        r.read()


async def type_into(c, selector, text):
    await c.eval("(()=>{const i=document.querySelector(%s);i.value=%s;"
                 "i.dispatchEvent(new Event('input',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(text)))


async def open_slots(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await asyncio.sleep(3)
    await c.eval("[...document.querySelectorAll('.tab')]"
                 ".find(t=>t.textContent.trim()==='Reserved Slots').click()")
    await asyncio.sleep(1.5)


async def last_activity(c):
    cmd = await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''")
    note = await c.eval("document.querySelector('.cmd-confirm .note')?.textContent||''")
    return str(cmd), str(note)


async def count(c):
    return str(await c.eval(
        "document.querySelector('.slot-count')?.firstChild?.textContent||''"))


async def set_amount(c, value):
    await type_into(c, "input[name=amount]", value)
    await asyncio.sleep(0.2)
    await c.eval("document.querySelector('input[name=amount]').form"
                 ".querySelector('button[type=submit]').click()")
    await asyncio.sleep(1.5)


async def add_slot(c, name, steam_id):
    await type_into(c, "input[name=slotname]", name)
    await type_into(c, "input[name=slotid]", steam_id)
    await asyncio.sleep(0.2)
    await c.eval("document.querySelector('input[name=slotname]').form"
                 ".querySelector('button[type=submit]').click()")
    await asyncio.sleep(1.5)


async def banners(c):
    return str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                            ".map(h=>h.textContent).join('|')"))


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    reset(STOCK)
    await open_slots(c, STOCK)
    b = str(await c.eval("[...document.querySelectorAll('.slots-tab .banner p')]"
                         ".map(p=>p.textContent).join('|')"))
    check("the stock removal bug is disclosed", "restart" in b, b[:60])
    await set_amount(c, "3")
    cmd, note = await last_activity(c)
    check("the amount is sent as sv_reserved_slots", cmd == "sv_reserved_slots 3", cmd)
    check("and reported as unverified, not as success",
          "unverified" in note.lower() and "success" not in note.lower(), note[:60])
    check("and it took: the command works on a stock server", await count(c) == "3",
          await count(c))


async def mod(c):
    print(f"\n== --mod ({MOD})")
    reset(MOD)
    await open_slots(c, MOD)
    check("no stock or Shine banner", await banners(c) == "", await banners(c) or "(none)")
    await type_into(c, "input[name=amount]", "99")
    await asyncio.sleep(0.2)
    disabled = await c.eval("document.querySelector('input[name=amount]').form"
                            ".querySelector('button[type=submit]').disabled")
    hint = str(await c.eval("document.querySelector('.slots-tab .form-hint').textContent"))
    check("an amount above max players cannot be sent", disabled is True)
    check("and the hint says why", "At most 16" in hint, hint[:60])

    await set_amount(c, "4")
    cmd, note = await last_activity(c)
    check("a set reports what the server printed",
          cmd == "sv_reserved_slots 4" and note == "Reserved slot amount set to 4",
          f"{cmd} -> {note}")
    check("and the count reads back", await count(c) == "4", await count(c))

    await type_into(c, "input[name=slotname]", "Two Words;x")
    await asyncio.sleep(0.2)
    hint = str(await c.eval("document.querySelector('input[name=slotname]').form"
                            ".querySelector('.form-hint').textContent"))
    check("the form says the name will change", "Two_Words_x" in hint, hint[:70])
    await add_slot(c, "Two Words;x", "99999992")
    cmd, note = await last_activity(c)
    check("the name loses `;` and spaces before the command line",
          cmd == "sv_add_reserved_slot Two_Words_x 99999992", cmd)
    check("and the add reports what the server printed",
          note == "Added reserved slot for Two_Words_x with Id 99999992", note)
    check("the slot is listed", await c.eval(f"{ROWS}.length") == 1)
    masked = str(await c.eval(f"[...{ROWS}].map(r=>r.cells[1].textContent).join('|')"))
    check("its Steam id is masked by default", "99999992" not in masked, masked)

    await type_into(c, "input[name=slotname]", "Two_Words_x")
    await asyncio.sleep(0.2)
    hint = str(await c.eval("document.querySelector('input[name=slotname]').form"
                            ".querySelector('.form-hint').textContent"))
    check("a duplicate name is flagged before it replaces a slot",
          "will be replaced" in hint, hint[:60])
    await type_into(c, "input[name=slotname]", "")

    await c.eval(f"{ROWS}[0].querySelector('.btn-danger').click()")
    await asyncio.sleep(1.5)
    cmd, note = await last_activity(c)
    check("a removal says what it removed",
          cmd == "sv_remove_reserved_slot 99999992"
          and note == "Removed reserved slot for Two_Words_x", f"{cmd} -> {note}")
    check("and the row is gone", await c.eval(f"{ROWS}.length") == 0)


async def shine(c):
    print(f"\n== --mod --shine=ban,reservedslots,mapvote ({SHINE_SLOTS})")
    reset(SHINE_SLOTS)
    # A slot in the vanilla list, to show it cannot be edited here.
    with urllib.request.urlopen(
            f"{SHINE_SLOTS}/?request=runcommand&cmd=sv_add_reserved_slot%20Old%2010000000",
            timeout=5) as r:
        r.read()
    await open_slots(c, SHINE_SLOTS)
    check("the Shine banner is shown", "Shine decides reserved slots" in await banners(c),
          await banners(c))
    check("the count shown is Shine's", await count(c) == "2", await count(c))
    removable = await c.eval(f"[...{ROWS}].some(r=>!r.querySelector('.btn-danger').disabled)")
    check("the vanilla list is read-only", removable is False)
    check("and has no add form",
          await c.eval("!document.querySelector('input[name=slotname]')") is True)
    await set_amount(c, "5")
    cmd, note = await last_activity(c)
    check("the count is set with sh_setresslots", cmd == "sh_setresslots 5", cmd)
    check("and reports Shine's line, without its receipt",
          note == "Console[N/A] set reserved slot count to 5", note)
    check("and reads back", await count(c) == "5", await count(c))


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
            foreign = sorted({u for u in urls if not u.startswith((STOCK, MOD, SHINE_SLOTS))})
            check("every request went to the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

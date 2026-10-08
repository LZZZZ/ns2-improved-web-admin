#!/usr/bin/env python3
"""Gate: the Maps tab, driven in a real browser against the mock.

The 2012 panel's map cycle editor rebuilt the cycle from its own fields on
every save, so anything it did not know -- Shine's per-map options, map groups
-- was lost, and it read back nothing. So the checks are about what this one
claims:

  * stock      the tab explains what a stock server cannot confirm; a change
               is a POST with everything in its body, and is reported as the
               server's copy, not the file
  * --mod      each change is written and read back; Undo writes the previous
               cycle; time and drag reorder write; the available maps are only
               those not in the cycle, one dragged in lands where it is
               dropped and a cycle map dragged out is removed; a cycle
               changed behind the panel is not overwritten; a refused write
               says why and the view goes back to the server's; a duplicate
               (a hand edit) is flagged; Change to reports what the server
               said, with no `;` on the command line
  * --mod --shine=ban,reservedslots,mapvote --maps=modded
               a modded cycle: a stock map's minimap on hover, fetched
               only then, and a mod map saying it has none; the mapvote banner
               and round limit,
               mode disabled with its reason, Shine's next map, a mod map
               added with its mod, a stock map as a name, the vote's pending
               options, a missing mod flagged and fixed, a map the server does
               not have flagged, and Shine's options and groups surviving

and on all of them: no uncaught exceptions, nothing fetched from a third party.

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8094 --web web --mod
    node mock/server.js --port 8099 --web web --mod --shine=ban,reservedslots,mapvote --maps=modded
"""
import asyncio, json, os, sys, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
SHINE = os.environ.get("SHINE_MAPS_URL", "http://127.0.0.1:8099")
PORT = 9231

ROWS = "document.querySelectorAll('.cycle-table tbody tr[data-index]')"
results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<62} {detail}")
    return ok


def get(base, path):
    with urllib.request.urlopen(f"{base}{path}", timeout=5) as r:
        return r.read().decode()


def reset(base):
    get(base, "/__mock/reset")


def edit_file(base, **kw):
    get(base, "/__mock/cycle-file?" + urllib.parse.urlencode(kw))


def server_cycle(base):
    """What getmapcycle says now: the file on the mod, memory on stock."""
    return json.loads(get(base, "/?request=getmapcycle"))


def name(entry):
    return entry if isinstance(entry, str) else entry.get("map")


async def wait_for(c, expr, timeout=5.0):
    for _ in range(int(timeout / 0.1)):
        if await c.eval(expr):
            return True
        await asyncio.sleep(0.1)
    return False


async def open_maps(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await wait_for(c, "!!document.querySelector('.tab')")
    await asyncio.sleep(0.5)
    await c.eval("[...document.querySelectorAll('.tab')]"
                 ".find(t=>t.textContent.trim()==='Maps').click()")
    await wait_for(c, f"{ROWS}.length > 0")
    await wait_for(c, "document.querySelectorAll('.available-table tbody tr').length > 0")


async def settled(c):
    """The write finished: the status line no longer says Writing."""
    await asyncio.sleep(0.2)
    await wait_for(c, "!document.querySelector('.cycle-settings .form-hint')"
                      "?.textContent.startsWith('Writing')")
    await asyncio.sleep(0.2)


async def last_activity(c):
    cmd = await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''")
    note = await c.eval("document.querySelector('.cmd-confirm .note')?.textContent||''")
    return str(cmd), str(note)


async def rows(c):
    return json.loads(await c.eval(f"JSON.stringify([...{ROWS}].map(r=>r.dataset.map))"))


async def click_row(c, index, label):
    """Buttons are icons; their words are hidden text, which starts with `label`."""
    await c.eval(f"[...{ROWS}[{index}].querySelectorAll('button')]"
                 f".find(b=>b.textContent.trim().startsWith({json.dumps(label)})).click()")
    await settled(c)


async def click_available(c, map_name, label):
    await c.eval(f"[...document.querySelector('.available-table tr[data-map=\"{map_name}\"]')"
                 f".querySelectorAll('button')].find(b=>b.textContent.trim().startsWith({json.dumps(label)})).click()")
    await settled(c)


async def available(c):
    return json.loads(await c.eval(
        "JSON.stringify([...document.querySelectorAll('.available-table tbody tr[data-map]')]"
        ".map(r=>r.dataset.map))"))


async def drag(c, handle, target, frac=0.5):
    """Press on the `handle` element, move in steps, release over `target` at
    `frac` of its height (a row's lower half drops after it)."""
    box = json.loads(await c.eval(
        f"JSON.stringify((()=>{{const h={handle}.getBoundingClientRect(),"
        f"t={target}.getBoundingClientRect();"
        f"return [h.x+h.width/2, h.y+h.height/2, t.x+Math.min(t.width/2,40), t.y+t.height*{frac}]}})())"))
    x0, y0, x1, y1 = box
    await c.send("Input.dispatchMouseEvent", type="mousePressed", x=x0, y=y0,
                 button="left", clickCount=1)
    for k in range(1, 9):
        await c.send("Input.dispatchMouseEvent", type="mouseMoved",
                     x=x0 + (x1 - x0) * k / 8, y=y0 + (y1 - y0) * k / 8,
                     button="left", buttons=1)
        await asyncio.sleep(0.04)
    await c.send("Input.dispatchMouseEvent", type="mouseReleased", x=x1, y=y1,
                 button="left", clickCount=1)
    await settled(c)


async def banners(c):
    return str(await c.eval("[...document.querySelectorAll('.maps-tab .banner')]"
                            ".map(b=>b.textContent).join('|')"))


async def hover(c, selector):
    box = json.loads(await c.eval(
        f"JSON.stringify((r=>[r.x+r.width/2,r.y+r.height/2])({selector}.getBoundingClientRect()))"))
    await c.send("Input.dispatchMouseEvent", type="mouseMoved", x=box[0], y=box[1])
    await asyncio.sleep(0.5)


async def notes(c, index):
    """A row's warnings and kept options: icons, whose words are hidden text."""
    return str(await c.eval(f"{ROWS}[{index}].querySelector('.row-notes')?.textContent||''"))


def posts(c, since):
    """setmapcycle requests the page made since event index `since`."""
    out = []
    for e in c.events[since:]:
        if e["method"] != "Network.requestWillBeSent":
            continue
        req = e["params"]["request"]
        if req.get("method") == "POST":
            out.append(req)
    return out


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    reset(STOCK)
    await open_maps(c, STOCK)
    b = await banners(c)
    check("the stock banner says what a stock server cannot confirm",
          "Stock server Lua" in b and "hand edit" in b, b[:60])
    before = await rows(c)
    check("the cycle renders from getmapcycle", len(before) == 17, f"{len(before)} rows")

    mark = len(c.events)
    await click_row(c, 1, "Move")
    sent = posts(c, mark)
    body = urllib.parse.parse_qs(sent[0].get("postData", "")) if sent else {}
    check("a change is one POST", len(sent) == 1, f"{len(sent)} POSTs")
    check("with request and data in the body and nothing in the URL",
          sent and sent[0]["url"].rstrip("/").endswith(STOCK.split("//")[1])
          and body.get("request") == ["setmapcycle"] and "data" in body,
          sent[0]["url"] if sent else "")
    after = [name(m) for m in server_cycle(STOCK)["maps"]]
    check("the move reached the server", after[:2] == [before[1], before[0]], str(after[:2]))
    cmd, note = await last_activity(c)
    check("reported as the server's copy, not the file",
          cmd.startswith("setmapcycle (move") and "cannot say whether MapCycle.json" in note,
          note[:70])

    await click_row(c, 3, "Change to")
    cmd, note = await last_activity(c)
    check("Change to sends sv_changemap, unverified",
          cmd == f"sv_changemap {before[3]}" and "unverified" in note, f"{cmd} -> {note[:30]}")


async def mod(c):
    print(f"\n== --mod ({MOD})")
    reset(MOD)
    await open_maps(c, MOD)
    b = await banners(c)
    check("no stock or Shine banner", b == "", b[:40] or "(none)")
    before = await rows(c)
    next_map = str(await c.eval("document.querySelector('.next-map b').textContent"))
    check("the next map is the one after the current map", next_map == "ns2_tanith", next_map)

    await click_row(c, len(before) - 1, "Remove")
    file = server_cycle(MOD)
    cmd, note = await last_activity(c)
    check("Remove writes the cycle without that map",
          [name(m) for m in file["maps"]] == before[:-1], f"{len(file['maps'])} maps")
    check("and says the file read back as sent",
          cmd == f"setmapcycle (remove {before[-1]})"
          and note == "written; MapCycle.json reads back as sent.", note)

    await c.eval("[...document.querySelectorAll('.cycle-settings button')]"
                 ".find(b=>b.textContent.trim()==='Undo last change').click()")
    await settled(c)
    check("Undo writes the previous cycle back",
          [name(m) for m in server_cycle(MOD)["maps"]] == before and await rows(c) == before,
          f"{len(await rows(c))} rows")

    await c.eval("(()=>{const i=document.querySelector('input[name=cycletime]');"
                 "i.value='25';i.dispatchEvent(new Event('input',{bubbles:true}));"
                 "i.dispatchEvent(new Event('change',{bubbles:true}));})()")
    await settled(c)
    check("the time is written on change", server_cycle(MOD)["time"] == 25,
          str(server_cycle(MOD)["time"]))

    # Drag the first map's handle onto the third row's lower half.
    await drag(c, f"{ROWS}[0].querySelector('.drag-handle')", f"{ROWS}[2]", 0.75)
    dragged = [name(m) for m in server_cycle(MOD)["maps"]]
    check("dragging the first map below the third moves it there",
          dragged[:3] == [before[1], before[2], before[0]], str(dragged[:3]))

    empty = str(await c.eval("document.querySelector('.available-table tbody').textContent"))
    check("the available maps are only those not in the cycle: here, none",
          await available(c) == [] and "Every map on the server is in the cycle" in empty,
          empty[:40])
    leaving = dragged[1]
    await drag(c, f"{ROWS}[1].querySelector('.drag-handle')", "document.querySelector('.available-table')")
    now = [name(m) for m in server_cycle(MOD)["maps"]]
    check("a cycle map dragged onto the available maps is removed",
          now == dragged[:1] + dragged[2:] and await available(c) == [leaving],
          f"{len(now)} maps")
    await drag(c, f"document.querySelector('.available-table tr[data-map=\"{leaving}\"] .drag-handle')",
               f"{ROWS}[3]", 0.25)
    now = [name(m) for m in server_cycle(MOD)["maps"]]
    cmd, note = await last_activity(c)
    check("an available map dragged into the cycle lands where it is dropped",
          now[3] == leaving and len(now) == len(dragged)
          and cmd == f"setmapcycle (add {leaving} at 4)", cmd)
    check("and leaves the available list", await available(c) == [])

    # A hand edit behind the panel's back: the next change must not land.
    edit_file(MOD, time=45)
    order = [name(m) for m in server_cycle(MOD)["maps"]]
    await click_row(c, 2, "Move")
    cmd, note = await last_activity(c)
    check("a cycle changed on the server is not overwritten",
          [name(m) for m in server_cycle(MOD)["maps"]] == order
          and server_cycle(MOD)["time"] == 45, note[:50])
    b = await banners(c)
    check("and the tab says so, with a reload", "changed on the server" in b, b[:50])
    await c.eval("[...document.querySelectorAll('.maps-tab .banner button')]"
                 ".find(b=>b.textContent.includes('Reload')).click()")
    await wait_for(c, "document.querySelector('input[name=cycletime]').value==='45'")
    check("Reload shows the server's cycle and lifts the lock",
          str(await c.eval("document.querySelector('input[name=cycletime]').value")) == "45"
          and "changed on the server" not in await banners(c))

    # A junk id written by hand: the next write carries it, and is refused.
    edit_file(MOD, mod="zzzz")
    await c.eval("[...document.querySelectorAll('.cycle-settings button')]"
                 ".find(b=>b.textContent.trim()==='Reload').click()")
    await asyncio.sleep(0.5)
    shown = await rows(c)
    await click_row(c, 1, "Move")
    cmd, note = await last_activity(c)
    check("a refused write says why", "refused, nothing written: mods[1] is not a hex mod id: zzzz"
          in note, note[:60])
    check("and the view goes back to the server's", await rows(c) == shown
          and [name(m) for m in server_cycle(MOD)["maps"]] == shown)
    reset(MOD)
    await open_maps(c, MOD)

    # The panel adds only maps the cycle lacks, so a duplicate is a hand edit.
    edit_file(MOD, append=before[0])
    await c.eval("[...document.querySelectorAll('.cycle-settings button')]"
                 ".find(b=>b.textContent.trim()==='Reload').click()")
    await asyncio.sleep(0.5)
    n = await notes(c, len(before))
    check("a map listed twice is flagged", "Listed 2 times" in n, n[:40])
    tip = str(await c.eval(f"{ROWS}[{len(before)}].querySelector('.row-notes .status-icon')?.title||''"))
    check("as an icon, its words on hover", "Listed 2 times" in tip, tip[:40])

    edit_file(MOD, append="ns2_x;sv_kick")
    await c.eval("[...document.querySelectorAll('.cycle-settings button')]"
                 ".find(b=>b.textContent.trim()==='Reload').click()")
    await asyncio.sleep(0.5)
    await click_row(c, len(before) + 1, "Change to")
    cmd, note = await last_activity(c)
    check("Change to strips `;` from the map name", cmd == "sv_changemap ns2_x sv_kick", cmd)
    check("and reports what the server printed", note == "ran, and printed nothing.", note)


async def shine(c):
    print(f"\n== --mod --shine=ban,reservedslots,mapvote --maps=modded ({SHINE})")
    reset(SHINE)
    edit_file(SHINE, append="ns2_veil_mmpg")
    edit_file(SHINE, append="ns2_nosuchmap")
    mark = len(c.events)
    await open_maps(c, SHINE)
    await wait_for(c, "document.querySelector('.mapvote-banner')")

    def minimaps(since):
        return [e["params"]["request"]["url"] for e in c.events[since:]
                if e["method"] == "Network.requestWillBeSent"
                and "/assets/ns2_" in e["params"]["request"]["url"]]
    check("no minimap fetched before a name is hovered", minimaps(mark) == [],
          str(len(minimaps(mark))))
    await hover(c, f"[...{ROWS}].find(r=>r.dataset.map==='ns2_veil').querySelector('.map-name')")
    img = json.loads(await c.eval(
        "JSON.stringify((i=>i&&[i.getAttribute('src'),i.naturalWidth,i.alt])"
        "(document.querySelector('.minimap-pop img')))"))
    check("hovering a stock map shows its minimap, from the game server",
          img and img[0].startswith("/assets/ns2_veil") and img[1] > 0
          and minimaps(mark) and all(u.startswith(SHINE) for u in minimaps(mark)),
          str(img)[:60])
    await hover(c, f"[...{ROWS}].find(r=>r.dataset.map==='ns2_veil_mmpg').querySelector('.map-name')")
    pop = str(await c.eval("document.querySelector('.minimap-pop')?.textContent||''"))
    check("a mod map says it has none", "No minimap" in pop
          and await c.eval("!document.querySelector('.minimap-pop img')"), pop[:40])
    await c.send("Input.dispatchMouseEvent", type="mouseMoved", x=5, y=5)
    await asyncio.sleep(0.2)
    check("and the popup goes with the pointer",
          await c.eval("!document.querySelector('.minimap-pop')"))
    b = await banners(c)
    check("the mapvote banner explains the vote and the round limit",
          "Shine's mapvote picks the next map" in b and "after 2 rounds" in b, b[:40])
    mode = json.loads(await c.eval(
        "JSON.stringify((s=>[s.disabled,s.title])(document.querySelector('select[name=cyclemode]')))"))
    check("the mode is disabled, with its reason", mode[0] is True and "not used" in mode[1],
          mode[1][:40])
    await wait_for(c, "document.querySelector('.next-map b').textContent!=='--'")
    next_map = str(await c.eval("document.querySelector('.next-map b').textContent"))
    check("the next map is Shine's", next_map == "ns2_jambi", next_map)
    first = await notes(c, 0)
    check("Shine's per-map option is shown as kept", "Shine options kept: min 12" in first, first[:40])
    title = str(await c.eval("document.querySelector('.section-title .tag')?.textContent||''"))
    check("and so are its map groups", "groups" in title, title)

    rows_now = await rows(c)
    veil = rows_now.index("ns2_veil_mmpg")
    n = await notes(c, veil)
    check("a mod map whose mod nothing loads is flagged", "Needs Mephs Mapping Playground" in n,
          n[:50])
    n = await notes(c, rows_now.index("ns2_nosuchmap"))
    check("a map the server does not have is flagged", "Not among the server's maps" in n, n[:40])
    await c.eval(f"{ROWS}[{veil}].querySelector('.row-notes button').click()")
    await settled(c)
    entry = server_cycle(SHINE)["maps"][veil]
    check("Load it with this map adds the mod to that entry",
          entry == {"map": "ns2_veil_mmpg", "mods": ["a80c2439"]}, json.dumps(entry))

    await click_available(c, "ns2_summit_mmpg", "Add")
    await click_available(c, "ns2_caged", "Add")
    file = server_cycle(SHINE)
    check("a mod map is added with its mod",
          file["maps"][-2] == {"map": "ns2_summit_mmpg", "mods": ["d372b93b"]},
          json.dumps(file["maps"][-2]))
    check("a stock map is added as a name", file["maps"][-1] == "ns2_caged",
          json.dumps(file["maps"][-1]))
    check("Shine's options and groups survived every write",
          file["maps"][0] == {"map": "ns2_veil", "min": 12}
          and file.get("groups") == [{"name": "small", "maps": ["ns2_veil", "ns2_summit"]}]
          and len(file["mods"]) == 22)
    await c.send("Page.reload")
    await asyncio.sleep(0.2)
    await open_maps(c, SHINE)
    await wait_for(c, "document.querySelector('.vote-pending')")
    pending = str(await c.eval("document.querySelector('.vote-pending')?.textContent||''"))
    check("the vote says which maps it offers only from the next map",
          "not yet in the vote" in pending and "ns2_caged" in pending, pending[:70])


async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Emulation.setDeviceMetricsOverride",
                         width=1280, height=1800, deviceScaleFactor=1, mobile=False)
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('webadmin-spa.settings'); } catch {}")
            await stock(c)
            await mod(c)
            await shine(c)

            print("\n== every server")
            exceptions = [e for e in c.events if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions", not exceptions,
                  str(len(exceptions)) + (f": {exceptions[0]['params']['exceptionDetails'].get('text')}"
                                          if exceptions else ""))
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

#!/usr/bin/env python3
"""Gate: the Mods tab (installed mods and the cycle's global mods), driven
in a real browser against the mock.

The 2012 panel showed installed mods with nothing to say which were loaded,
and searched the workshop on every page load, from Steam, for a tab nobody
had opened. So the checks are about what this one claims:

  * stock      the tab says a stock server cannot tell what is loaded and
               marks nothing loaded; a change is a POST with everything in its
               body, reported as the server's copy, not the file
  * --mod      loaded mods first; the hex id selectable and the workshop id
               right; Load with every map appends and says it loads at the next
               map change, which then shows it loaded; Stop loading says it
               unloads at the next one; Undo; a cycle changed behind the panel
               is not overwritten
  * --mod --shine=ban,reservedslots,mapvote --maps=modded
               a modded server's mods: the table in mount order (the engine's
               own two, then the cycle's, numbered), the engine's own two mods
               explained, a map mod left to the Maps tab, a global map mod
               whose maps would lose it asked about first, Shine's per-map
               option, the groups and the per-map mods surviving, and a cycle
               id the server has not installed shown in its place and removable

and the whitelist (docs/CONSTRAINTS.md item 17) on each: stock uses the list the panel ships and
says why; --mod starts on it while the server reads Steam's, then switches;
the modded config's 41 whitelisted, 2 hotfix and 6 others; and a read that
fails (--whitelist=fail) falls back to the shipped list with the reason.

and on all of them: no workshop search, no uncaught exceptions, nothing
fetched from a third party.

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8094 --web web --mod
    node mock/server.js --port 8099 --web web --mod --shine=ban,reservedslots,mapvote --maps=modded
    node mock/server.js --port 8103 --web web --mod --whitelist=fail --whitelist-delay 300
"""
import asyncio, json, os, sys, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
SHINE = os.environ.get("SHINE_MAPS_URL", "http://127.0.0.1:8099")
FAIL = os.environ.get("WHITELIST_FAIL_URL", "http://127.0.0.1:8103")
PORT = 9232

ROWS = "document.querySelectorAll('.mods-table tbody tr[data-mod]')"
# A workshop result the mock can install: "Combat Pistol 'Spitfire' Commando".
CATALOGUE_ID = "61a75aa"
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
    return json.loads(get(base, "/?request=getmapcycle"))


def install(base, modid):
    """installmod, then wait out the mock's download delay."""
    get(base, "/?" + urllib.parse.urlencode({"request": "installmod", "modid": modid}))
    for _ in range(50):
        if any(m["id"] == modid for m in json.loads(get(base, "/?request=getinstalledmodslist"))):
            return
        import time; time.sleep(0.1)
    raise RuntimeError(f"{modid} never appeared in the installed list")


async def wait_for(c, expr, timeout=5.0):
    for _ in range(int(timeout / 0.1)):
        if await c.eval(expr):
            return True
        await asyncio.sleep(0.1)
    return False


async def open_mods(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await wait_for(c, "!!document.querySelector('.tab')")
    await asyncio.sleep(0.5)
    await c.eval("[...document.querySelectorAll('.tab')]"
                 ".find(t=>t.textContent.trim()==='Mods').click()")
    await wait_for(c, f"{ROWS}.length > 0")
    await asyncio.sleep(0.5)


async def settled(c):
    await asyncio.sleep(0.2)
    await wait_for(c, "!document.querySelector('.cycle-settings .form-hint')"
                      "?.textContent.startsWith('Writing')")
    await asyncio.sleep(0.2)


async def last_activity(c):
    cmd = await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''")
    note = await c.eval("document.querySelector('.cmd-confirm .note')?.textContent||''")
    return str(cmd), str(note)


async def table(c, missing=False):
    """[id, active, status text, actions text, order] per row, in display order.
    Rows for cycle ids the server has not installed only when asked for."""
    rows = json.loads(await c.eval(
        f"JSON.stringify([...{ROWS}].map(r=>[r.dataset.mod, r.dataset.active,"
        "r.querySelector('.status-cell').textContent,"
        "r.querySelector('.actions').textContent, r.dataset.order,"
        "r.dataset.missing||'']))"))
    return [r[:5] for r in rows if missing or not r[5]]


async def row(c, modid):
    for r in await table(c):
        if r[0] == modid:
            return r
    return None


async def click_row(c, modid, label):
    await c.eval(f"[...document.querySelector('.mods-table tr[data-mod=\"{modid}\"]')"
                 f".querySelectorAll('button')].find(b=>b.textContent.trim()==={json.dumps(label)}).click()")
    await settled(c)


async def banners(c):
    return str(await c.eval("[...document.querySelectorAll('.mods-tab .banner')]"
                            ".map(b=>b.textContent).join('|')"))


async def wl_source(c):
    """[data-source, text] of the tab's whitelist line."""
    return json.loads(await c.eval(
        "JSON.stringify((p=>p?[p.dataset.source,p.textContent]:['',''])"
        "(document.querySelector('.mods-tab .whitelist-source')))"))


async def wl_title(c, modid):
    """The whitelist icon's words and tooltip on a row."""
    return json.loads(await c.eval(
        f"JSON.stringify((s=>s?[s.querySelector('.sr-only').textContent,s.title]:['',''])"
        f"([...document.querySelectorAll('.mods-table tr[data-mod=\"{modid}\"] .status-icon')]"
        ".find(s=>/whitelist/.test(s.title))))"))


def posts(c, since):
    return [e["params"]["request"] for e in c.events[since:]
            if e["method"] == "Network.requestWillBeSent"
            and e["params"]["request"].get("method") == "POST"]


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    reset(STOCK)
    install(STOCK, CATALOGUE_ID)
    await open_mods(c, STOCK)
    b = await banners(c)
    check("the stock banner says loaded mods cannot be told",
          "Stock server Lua" in b and "does not say which mods are loaded" in b, b[:60])
    t = await table(c)
    check("the installed list renders", len(t) == 3, f"{len(t)} rows")
    check("and nothing is marked loaded, or not loaded",
          all(r[1] == "" and "loaded now" not in r[2] for r in t))
    counts = str(await c.eval("document.querySelector('.mod-counts').textContent"))
    check("the counts do not claim a loaded number", "loaded" not in counts, counts)
    src = await wl_source(c)
    check("whitelist: the shipped copy, dated, and why",
          src[0] == "shipped" and "stock server cannot read Steam's" in src[1]
          and "(115 mods)" in src[1] and "whitelisted since then" in src[1], src[1][:70])
    hot = await wl_title(c, "d41d68cd")
    check("a hotfix mod counts as whitelisted, and says why",
          hot[0] == "whitelisted" and "hotfix mods" in hot[1], hot[1][:50])
    other = await wl_title(c, CATALOGUE_ID)
    check("a mod not on the list says so, and that the list may be old",
          other[0] == "not whitelisted" and "ranking off" in other[1]
          and "shipped with the panel" in other[1] and "unless it was whitelisted since" in other[1],
          other[1][:50])

    mark = len(c.events)
    await click_row(c, CATALOGUE_ID, "Load with every map")
    sent = posts(c, mark)
    body = urllib.parse.parse_qs(sent[0].get("postData", "")) if sent else {}
    check("a change is one POST, everything in the body",
          len(sent) == 1 and body.get("request") == ["setmapcycle"] and "data" in body
          and "?" not in sent[0]["url"], f"{len(sent)} POSTs")
    check("the id reached the cycle's mods", server_cycle(STOCK).get("mods") == [CATALOGUE_ID],
          json.dumps(server_cycle(STOCK).get("mods")))
    cmd, note = await last_activity(c)
    check("reported as the server's copy, not the file",
          cmd.startswith("setmapcycle (load ") and "cannot say whether MapCycle.json" in note,
          note[:60])


async def mod(c):
    print(f"\n== --mod ({MOD})")
    reset(MOD)
    install(MOD, CATALOGUE_ID)
    await open_mods(c, MOD)
    check("no stock banner", await banners(c) == "")
    t = await table(c)
    check("loaded mods come first", [r[1] for r in t] == ["true", "true", "false"],
          str([r[1] for r in t]))
    hotfix = await row(c, "d41d68cd")
    check("an engine-mounted mod says so, and offers nothing",
          "Mounted by the server itself" in hotfix[2] and "mounts it anyway" in hotfix[3],
          hotfix[2][-40:])
    sel = str(await c.eval("getComputedStyle(document.querySelector("
                           "'tr[data-mod=\"d41d68cd\"] .selectable')).userSelect"))
    check("the hex id selects whole", sel == "all", sel)
    link = json.loads(await c.eval(
        "JSON.stringify((a=>[a.textContent,a.href,a.rel,a.target])"
        "(document.querySelector('tr[data-mod=\"d41d68cd\"] a')))"))
    check("the workshop id is right, and links out",
          link[0] == "3558697165" and link[1].endswith("?id=3558697165")
          and "noreferrer" in link[2] and link[3] == "_blank", link[0])

    await click_row(c, CATALOGUE_ID, "Load with every map")
    cmd, note = await last_activity(c)
    check("Load with every map writes the id",
          server_cycle(MOD).get("mods") == [CATALOGUE_ID]
          and note == "written; MapCycle.json reads back as sent.", note)
    r = await row(c, CATALOGUE_ID)
    check("and says it loads at the next map change, not now",
          r[1] == "false" and "loads at the next map change" in r[2], r[2][-45:])

    get(MOD, "/?" + urllib.parse.urlencode({"request": "runcommand", "cmd": "sv_changemap ns2_veil"}))
    ok = await wait_for(c, f"document.querySelector('tr[data-mod=\"{CATALOGUE_ID}\"]')"
                           "?.dataset.active==='true'", timeout=8)
    r = await row(c, CATALOGUE_ID)
    check("after the map change it reads loaded", ok and "loaded now" in r[2]
          and "next map change" not in r[2], r[2][:40])

    await click_row(c, CATALOGUE_ID, "Stop loading with every map")
    r = await row(c, CATALOGUE_ID)
    check("Stop loading says it unloads at the next map change",
          server_cycle(MOD).get("mods") == [] and "unloads at the next map change" in r[2],
          r[2][-45:])

    await c.eval("[...document.querySelectorAll('.cycle-settings button')]"
                 ".find(b=>b.textContent.trim()==='Undo last change').click()")
    await settled(c)
    check("Undo writes the id back", server_cycle(MOD).get("mods") == [CATALOGUE_ID],
          json.dumps(server_cycle(MOD).get("mods")))

    edit_file(MOD, time=45)
    await click_row(c, CATALOGUE_ID, "Stop loading with every map")
    check("a cycle changed on the server is not overwritten",
          server_cycle(MOD).get("mods") == [CATALOGUE_ID] and server_cycle(MOD)["time"] == 45)
    check("and the tab says so", "changed on the server" in await banners(c))
    disabled = await c.eval(f"document.querySelector('tr[data-mod=\"{CATALOGUE_ID}\"] button').disabled")
    check("with the row's action disabled until a reload", disabled is True)


async def mod_whitelist(c):
    print(f"\n== --mod, the whitelist read ({MOD})")
    reset(MOD)
    mark = len(c.events)
    await c.send("Page.navigate", url=MOD + "/index.html")
    await wait_for(c, "!!document.querySelector('.tab')")
    await c.eval("[...document.querySelectorAll('.tab')]"
                 ".find(t=>t.textContent.trim()==='Mods').click()")
    seen = []
    for _ in range(60):
        s = await wl_source(c)
        if s[0] and (not seen or seen[-1] != s):
            seen.append(s)
        if s[0] == "server":
            break
        await asyncio.sleep(0.1)
    check("first the shipped copy, saying the server is reading Steam's",
          len(seen) >= 2 and seen[0][0] == "shipped"
          and "the server is reading Steam's now" in seen[0][1], seen[0][1][:70] if seen else "")
    check("then Steam's, as the server read it",
          seen and seen[-1][0] == "server" and "Steam's, read by the server" in seen[-1][1]
          and "(115 mods)" in seen[-1][1], seen[-1][1][:60] if seen else "")
    asked = [e["params"]["request"]["url"] for e in c.events[mark:]
             if e["method"] == "Network.requestWillBeSent"
             and "request=getwhitelist" in e["params"]["request"]["url"]]
    check("asked again soon while the read ran, not every second", 2 <= len(asked) <= 4,
          f"{len(asked)} requests")
    other = await wl_title(c, "d41d68cd")
    check("the hotfix mod is still whitelisted on Steam's list", other[0] == "whitelisted")


async def failing(c):
    print(f"\n== --mod --whitelist=fail ({FAIL})")
    reset(FAIL)
    await open_mods(c, FAIL)
    ok = await wait_for(c, "document.querySelector('.mods-tab .whitelist-source')"
                           "?.textContent.includes('could not read')", timeout=4)
    src = await wl_source(c)
    check("a failed read: the shipped copy, with the server's reason",
          ok and src[0] == "shipped" and "could not read Steam's: Steam could not be reached: "
          "Could not resolve host" in src[1], src[1][40:120])
    hot = await wl_title(c, "acd4ecf3")
    check("and the verdicts still come from it", hot[0] == "whitelisted")


async def shine(c):
    print(f"\n== --mod --shine=ban,reservedslots,mapvote --maps=modded ({SHINE})")
    reset(SHINE)
    edit_file(SHINE, mod="deadbeef")
    before = server_cycle(SHINE)
    await open_mods(c, SHINE)
    t = await table(c)
    check("all 49 installed", len(t) == 49, f"{len(t)} rows")
    full = await table(c, missing=True)
    numbered = [r[0] for r in full if r[4]]
    expected_order = ["acd4ecf3", "d41d68cd"] + [str(m).lower() for m in before["mods"]]
    check("mount order first: the engine's two, then the cycle's, numbered",
          numbered == expected_order
          and [r[4] for r in full[:len(numbered)]] == [str(i + 1) for i in range(len(numbered))],
          f"{len(numbered)} numbered")
    rest = [r[1] for r in full[len(numbered):]]
    check("and the rest after them, loaded ones first",
          all(not r[4] for r in full[len(numbered):])
          and rest == sorted(rest, key=lambda a: a != "true"), f"{rest.count('true')} loaded")
    mephs = await row(c, "a80c2439")
    check("a map mod is left to the Maps tab",
          "Maps tab loads it" in mephs[3] and "and 7 more" in mephs[2], mephs[2][:50])

    ghost = next((r for r in full if r[0] == "deadbeef"), None)
    check("a cycle id the server has not installed is shown, in its place",
          ghost is not None and "not installed" in ghost[2] and "Remove" in ghost[3]
          and ghost[4] == str(len(numbered)), (ghost or ["", "", ""])[2][:40])
    await click_row(c, "deadbeef", "Remove")
    await settled(c)
    after = server_cycle(SHINE)
    check("and Remove takes only it out", after["mods"] == before["mods"][:-1],
          f"{len(after['mods'])} mods")

    await c.eval("window.__confirms = []")
    await click_row(c, "b0ab9e7e", "Stop loading with every map")
    asked = json.loads(await c.eval("JSON.stringify(window.__confirms)"))
    check("stopping a map mod its cycle maps depend on asks first",
          len(asked) == 1 and "ns2_mineral_nsl" in asked[0], (asked or [""])[0][:60])
    after = server_cycle(SHINE)
    expected = [m for m in before["mods"][:-1] if m != "b0ab9e7e"]
    check("and removes only that id, the order kept", after["mods"] == expected,
          f"{len(after['mods'])} mods")

    await click_row(c, "582e77fa", "Load with every map")
    after = server_cycle(SHINE)
    check("Load with every map appends it last", after["mods"] == expected + ["582e77fa"],
          after["mods"][-1])
    statuses = [r[2] for r in await table(c)]
    nots = sum("not whitelisted" in s for s in statuses)
    wls = sum("whitelisted" in s and "not whitelisted" not in s for s in statuses)
    check("the whitelist: 43 whitelisted (2 of them hotfix mods), 6 not",
          wls == 43 and nots == 6, f"{wls} whitelisted, {nots} not")
    combat = await wl_title(c, "1e62a2ce")
    panel = await wl_title(c, "aa473d86")
    check("Combat Fix is not, NS2Panel is",
          combat[0] == "not whitelisted" and panel[0] == "whitelisted"
          and "Steam's whitelist, read by the server" in panel[1], panel[1][:50])
    check("Shine's option, the groups and the per-map mods survived",
          after["maps"][0] == {"map": "ns2_veil", "min": 12}
          and after.get("groups") == before.get("groups")
          and [m for m in after["maps"] if isinstance(m, dict)]
          == [m for m in before["maps"] if isinstance(m, dict)])


async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Emulation.setDeviceMetricsOverride",
                         width=1280, height=1800, deviceScaleFactor=1, mobile=False)
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = (m) => { (window.__confirms ||= []).push(m);"
                                " return true; };"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('webadmin-spa.settings'); } catch {}")
            await stock(c)
            await mod_whitelist(c)
            await mod(c)
            await shine(c)
            await failing(c)

            print("\n== every server")
            exceptions = [e for e in c.events if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions", not exceptions,
                  str(len(exceptions)) + (f": {exceptions[0]['params']['exceptionDetails'].get('text')}"
                                          if exceptions else ""))
            urls = [e["params"]["request"]["url"] for e in c.events
                    if e["method"] == "Network.requestWillBeSent"]
            check("no workshop search, on load or on the tab",
                  not any("request=getmods" in u for u in urls))
            check("a stock server is never asked for the whitelist",
                  not any(u.startswith(STOCK) and "request=getwhitelist" in u for u in urls))
            foreign = sorted({u for u in urls if not u.startswith((STOCK, MOD, SHINE, FAIL))})
            check("every request went to the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

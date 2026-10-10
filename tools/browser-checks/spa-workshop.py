#!/usr/bin/env python3
"""Gate: the Workshop tab (search, details, install), driven in a real
browser against the mock.

The 2012 panel searched Steam on every page load, for a tab nobody had
opened, offered Next and Previous over a search that has no pages, showed
similar-looking results with no details, and "subscribed" with a toggle that
downloaded and said nothing more. So the checks are about what this one
claims:

  * stock      no search before the tab is opened, one when it is, and no
               polling once it settles; the first-50 cap stated, with the
               Steam Workshop offered for the rest (no referrer); an empty
               result said to be no matches or no Steam; install asks first
               (download only, no delete, ranking), is one POST with the id
               in its body, reported as unverified, shown downloading and
               then installed once the installed list has it, and Open in
               Mods filters that tab to it; a search that never answers given
               up at 35 s with the stock caveat
  * --mod      a mod's details: its description as text, markup and BBCode
               included and nothing run; its ids, author, size, requirements
               and Steam's problem flag; a search the server gave up on shown
               with Retry, and Retry working; an offline server's empty
               result; an install that never arrives never reported as
               installed; thumbnails fetched by default, without a referrer,
               and none once Settings turns them off (the tab has no switch)
  * --mod --shine=ban,reservedslots,mapvote --maps=modded
               a result installed and loaded now, and one installed but not
               loaded, marked so, with Open in Mods instead of Install

and on all of them: no uncaught exceptions, and nothing fetched from a third
party except the thumbnails (blocked here, so the gate does not reach Steam
either).

Not covered: the 3-minute "not installed" state, which would need a
3-minute wait.

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
PORT = 9233

ROWS = "document.querySelectorAll('.workshop-table tbody tr[data-mod]')"
# Made-up results the mock adds to its catalogue (mock/state.js).
SMALL = "5ea0001"        # "Halcyon Tweaks"; "halcyon" finds three
WHITELISTED = "b7149f9"  # "Badges+" (191973881), on the whitelist
MARKUP = "5ea0004"       # markup in title and description, Steam result 9
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


def workshop(base, **kw):
    get(base, "/__mock/workshop?" + urllib.parse.urlencode(kw))


def installed_ids(base):
    return [m["id"] for m in json.loads(get(base, "/?request=getinstalledmodslist"))]


async def wait_for(c, expr, timeout=5.0):
    for _ in range(int(timeout / 0.1)):
        if await c.eval(expr):
            return True
        await asyncio.sleep(0.1)
    return False


def requests(c, since=0):
    return [e["params"]["request"] for e in c.events[since:]
            if e["method"] == "Network.requestWillBeSent"]


def searches(c, since=0):
    return [urllib.parse.parse_qs(urllib.parse.urlparse(r["url"]).query)
            for r in requests(c, since) if "request=getmods" in r["url"]]


async def load(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await wait_for(c, "!!document.querySelector('.tab')")
    await asyncio.sleep(0.5)


async def open_tab(c, label):
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={json.dumps(label)}).click()")
    await asyncio.sleep(0.2)


async def toggle_thumbnails(c):
    """Through Settings, the only place the switch is, and back. Coming back
    shows the last result without searching again."""
    await open_tab(c, "Settings")
    await c.eval("document.querySelector('.settings-tab input[name=\"thumbnails\"]').click()")
    await asyncio.sleep(0.2)
    await open_tab(c, "Workshop")


async def settled(c, timeout=5.0):
    """Wait for a search to leave `loading`."""
    await asyncio.sleep(0.2)
    return await wait_for(c, "(s=>s&&!s.textContent.startsWith('Searching'))"
                             "(document.querySelector('.search-status'))", timeout)


async def status(c):
    return str(await c.eval("document.querySelector('.search-status')?.textContent||''"))


async def search(c, text):
    await c.eval(f"""(()=>{{const i=document.querySelector('input[name="workshop-query"]');
        i.value={json.dumps(text)}; i.dispatchEvent(new Event('input',{{bubbles:true}}));
        i.form.requestSubmit();}})()""")
    await settled(c)


async def table(c):
    """[id, title, status text, actions text] per row."""
    return json.loads(await c.eval(
        f"JSON.stringify([...{ROWS}].map(r=>[r.dataset.mod,"
        "r.querySelector('.name-cell').textContent,"
        "r.querySelector('.status-cell').textContent,"
        "r.querySelector('.actions').textContent]))"))


async def row(c, modid):
    for r in await table(c):
        if r[0] == modid:
            return r
    return None


async def click_row(c, modid, label):
    await c.eval(f"[...document.querySelector('.workshop-table tr[data-mod=\"{modid}\"]')"
                 f".querySelectorAll('button')].find(b=>b.textContent.trim()==={json.dumps(label)}).click()")
    await asyncio.sleep(0.3)


async def last_activity(c):
    cmd = await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''")
    note = await c.eval("document.querySelector('.cmd-confirm .note')?.textContent||''")
    return str(cmd), str(note)


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    reset(STOCK)
    mark = len(c.events)
    await load(c, STOCK)
    await asyncio.sleep(1.0)
    check("no workshop search before the tab is opened", searches(c, mark) == [])

    await open_tab(c, "Workshop")
    await settled(c)
    s = searches(c, mark)
    check("opening the tab searches, for everything",
          len(s) >= 1 and all(q.get("searchtext", [""]) == [""] for q in s), f"{len(s)} polls")
    t = await table(c)
    st = await status(c)
    check("the first 50 are shown, and the cap is stated",
          len(t) == 50 and "Only the first 50" in st and "Steam Workshop" in st, f"{len(t)} rows")
    links = json.loads(await c.eval(
        "JSON.stringify([...document.querySelectorAll('.workshop-tab a')]"
        ".filter(a=>a.textContent==='Steam Workshop').map(a=>[a.href,a.rel,a.target]))"))
    check("which links to the workshop, out of the panel and without a referrer",
          len(links) == 2 and all(l[0] == "https://steamcommunity.com/app/4920/workshop/"
                                  and "noreferrer" in l[1] and l[2] == "_blank" for l in links),
          f"{len(links)} links")

    await asyncio.sleep(0.2)
    mark = len(c.events)
    await asyncio.sleep(2.0)
    check("no polling once settled", searches(c, mark) == [], f"{len(searches(c, mark))} polls")

    await search(c, "halcyon")
    t = await table(c)
    st = await status(c)
    check("a narrow search: three results, no cap note",
          [r[0] for r in t] == ["5ea0001", "5ea0002", "5ea0003"]
          and st.startswith("3 results for halcyon") and "first 50" not in st, st[:40])
    nav = await c.eval("[...document.querySelectorAll('.workshop-tab button')]"
                       ".some(b=>/next|previous|page/i.test(b.textContent))")
    check("no paging offered: the engine has none", nav is False)
    maxlen = await c.eval("document.querySelector('input[name=\"workshop-query\"]').maxLength")
    check("the search text is capped", maxlen == 200, str(maxlen))

    await search(c, "zzqqxx")
    st = await status(c)
    check("an empty result says no matches or no Steam",
          "Nothing found" in st and "could not reach Steam" in st, st[:50])

    await search(c, "halcyon")
    r = await row(c, SMALL)
    check("an uninstalled result offers Install", "not installed" in r[2] and "Install" in r[3])
    check("and says, before installing, that it is not whitelisted",
          "not whitelisted" in r[2], r[2][:40])
    src = json.loads(await c.eval(
        "JSON.stringify((p=>p?[p.dataset.source,p.textContent]:['',''])"
        "(document.querySelector('.workshop-tab .whitelist-source')))"))
    check("from the shipped whitelist, dated, on a stock server",
          src[0] == "shipped" and "stock server cannot read Steam's" in src[1], src[1][:60])
    await c.eval("window.__confirms = []")
    mark = len(c.events)
    await click_row(c, SMALL, "Install")
    asked = json.loads(await c.eval("JSON.stringify(window.__confirms)"))
    check("Install asks first, with what it does and costs",
          len(asked) == 1 and "only downloads it" in asked[0]
          and "can delete" in asked[0]
          and "It is not whitelisted: loading it turns ranking off." in asked[0],
          (asked or [""])[0][:40])
    posted = [r for r in requests(c, mark) if r.get("method") == "POST"]
    body = urllib.parse.parse_qs(posted[0].get("postData", "")) if posted else {}
    check("one POST, the id in the body",
          len(posted) == 1 and body == {"request": ["installmod"], "modid": [SMALL]}
          and "?" not in posted[0]["url"], f"{len(posted)} POSTs")
    cmd, note = await last_activity(c)
    check("reported as unverified", cmd == f"installmod {SMALL}"
          and "does not answer" in note, note[:50])
    r = await row(c, SMALL)
    check("shown downloading, not installed", "Downloading" in r[2] and "installed" not in r[2],
          r[2][:40])
    ok = await wait_for(c, f"document.querySelector('tr[data-mod=\"{SMALL}\"] .status-cell')"
                           "?.textContent.includes('installed')", timeout=8)
    r = await row(c, SMALL)
    check("installed once the server lists it", ok and SMALL in installed_ids(STOCK)
          and "Open in Mods" in r[3] and "loaded now" not in r[2], r[2][:30])
    cmd, note = await last_activity(c)
    check("and the arrival is reported", "is installed: the server lists it now" in note, note[:50])

    await click_row(c, SMALL, "Open in Mods")
    await wait_for(c, "document.querySelectorAll('.mods-table tbody tr[data-mod]').length > 0")
    mods = json.loads(await c.eval(
        "JSON.stringify([document.querySelector('.tab[aria-selected=true]').textContent,"
        "document.querySelector('.mods-tab input[type=search]').value,"
        "[...document.querySelectorAll('.mods-table tbody tr[data-mod]')].map(r=>r.dataset.mod)])"))
    check("Open in Mods opens that tab filtered to it",
          mods[0] == "Mods" and mods[1] == SMALL and mods[2] == [SMALL], json.dumps(mods))
    await open_tab(c, "Workshop")
    await settled(c)
    await open_tab(c, "Mods")
    fil = await c.eval("document.querySelector('.mods-tab input[type=search]').value")
    check("and the filter does not stick to a plain tab click", fil == "", repr(fil))

    await open_tab(c, "Workshop")
    await settled(c)
    await search(c, "badges")
    r = await row(c, WHITELISTED)
    check("a whitelisted result says so",
          r and "whitelisted" in r[2] and "not whitelisted" not in r[2], (r or ["", "", ""])[2][:40])
    await search(c, "halcyon")
    back = await status(c)
    check("coming back shows the last search again", back.startswith("3 results"), back[:30])
    # Two: the stock Lua restarts it at 30 s, and Steam is still not answering.
    workshop(STOCK, search="hang", n=2)
    await search(c, "never answers")
    st = await status(c)
    check("a search that never answers keeps loading", st.startswith("Searching"), st[:30])
    ok = await settled(c, timeout=40)
    st = await status(c)
    check("is given up at 35 s, with the stock caveat",
          ok and "No answer" in st and "35 s" in st
          and "cannot tell a failed search from a slow one" in st, st[:60])
    await c.eval("[...document.querySelectorAll('.search-status button')]"
                 ".find(b=>b.textContent==='Retry').click()")
    await asyncio.sleep(0.3)
    st = await status(c)
    check("and Retry searches again", st.startswith("Searching"), st[:30])


async def mod(c):
    print(f"\n== --mod ({MOD})")
    reset(MOD)
    await load(c, MOD)
    await open_tab(c, "Workshop")
    await settled(c)
    await search(c, "markup")
    t = await table(c)
    check("the markup result is found", [r[0] for r in t] == [MARKUP], json.dumps([r[0] for r in t]))
    title = await c.eval(f"(c=>[c.textContent, c.querySelectorAll('b,i').length])"
                         f"(document.querySelector('tr[data-mod=\"{MARKUP}\"] .link-button'))")
    check("its title is text, markup and all",
          title == ["Markup <b>test</b> & <i>friends</i>", 0], json.dumps(title))
    check("Steam's problem with it is flagged", "Steam problem" in t[0][1])
    ok = await wait_for(c, "document.querySelector('.workshop-tab .whitelist-source')"
                           "?.dataset.source==='server'", timeout=5)
    check("with the mod, the whitelist is Steam's, as the server read it", ok)

    await click_row(c, MARKUP, "Details")
    detail = json.loads(await c.eval(
        "JSON.stringify((d=>({text:d.querySelector('.description').textContent,"
        "elements:d.querySelectorAll('.description *').length,"
        "facts:d.querySelector('.detail-facts').textContent,"
        "links:[...d.querySelectorAll('a')].map(a=>[a.textContent,a.href,a.rel,a.target])}))"
        "(document.querySelector('.detail-row')))"))
    text = detail["text"]
    check("the description is text: markup shown, nothing run",
          "<script>window.__xss = 1</script>" in text and detail["elements"] == 0
          and await c.eval("window.__xss === undefined"), text[:40])
    check("BBCode read as text: tags gone, link kept, image dropped",
          "[b]" not in text and "[h1]" not in text and "Heading" in text and "bold" in text
          and "a link (https://example.com)" in text and "banner.png" not in text
          and "• one" in text, text[-50:].replace("\n", " "))
    ws = str(int(MARKUP, 16))
    check("the workshop id, decimal and hex, links out",
          [ws, f"https://steamcommunity.com/sharedfiles/filedetails/?id={ws}",
           "noreferrer noopener", "_blank"] in detail["links"] and MARKUP in detail["facts"], ws)
    check("the author is the raw id, linked to the profile",
          ["76561197960287930", "https://steamcommunity.com/profiles/76561197960287930",
           "noreferrer noopener", "_blank"] in detail["links"])
    check("size, requirements and Steam's result are stated",
          "2.0 KB" in detail["facts"] and "2 other workshop items" in detail["facts"]
          and "result 9" in detail["facts"], detail["facts"][-60:])
    await click_row(c, MARKUP, "Hide details")
    check("Hide details closes it", await c.eval("!document.querySelector('.detail-row')"))

    workshop(MOD, search="hang", timeout=2)
    await search(c, "timeout test")
    ok = await settled(c, timeout=6)
    st = await status(c)
    check("a search the server gave up on shows its error, with Retry",
          ok and "failed: The workshop search had no answer after 2 s." in st
          and "Retry" in st and "stock" not in st, st[:70])
    await c.eval("[...document.querySelectorAll('.search-status button')]"
                 ".find(b=>b.textContent==='Retry').click()")
    await settled(c)
    st = await status(c)
    check("and Retry searches again, and settles", "failed" not in st
          and not st.startswith("Searching"), st[:40])
    workshop(MOD, timeout=30)

    workshop(MOD, search="offline")
    await search(c, "combat offline")
    st = await status(c)
    check("an offline server's search: nothing found, both reasons",
          "Nothing found" in st and "could not reach Steam" in st, st[:40])

    await search(c, "halcyon")
    workshop(MOD, install="never")
    await click_row(c, "5ea0002", "Install")
    cmd, note = await last_activity(c)
    check("the mod's answer is reported", note == "download asked for. Waiting for the "
          "server to list it.", note[:50])
    await asyncio.sleep(5)
    r = await row(c, "5ea0002")
    check("an install that never arrives is never called installed",
          "Downloading" in r[2] and "installed" not in r[2].replace("not listed", ""),
          r[2][:50])

    thumbs = [u for u in requests(c) if "steamusercontent" in u["url"]]
    check("thumbnails are on by default: one per result is fetched from Steam, without a referrer",
          {u["url"].split("/")[-2] for u in thumbs} >= {"5ea0001", "5ea0002", "5ea0003"}
          # Chrome lists the header, empty, under the no-referrer policy.
          and all(u.get("referrerPolicy") == "no-referrer"
                  and not u.get("headers", {}).get("Referer") for u in thumbs),
          f"{len(thumbs)} requests")
    check("and one that fails to load is hidden, not shown broken", await c.eval(
        "document.querySelectorAll('.workshop-table img').length") == 0)
    check("the tab has no thumbnail switch",
          await c.eval("!document.querySelector('.workshop-tab input[name=\"thumbnails\"]')"))
    await toggle_thumbnails(c)
    await asyncio.sleep(0.3)
    blocked = len(c.events)
    await search(c, "halcyon")
    await asyncio.sleep(0.8)
    thumbs = [u for u in requests(c, blocked) if "steamusercontent" in u["url"]]
    check("turned off in Settings, none fetched", thumbs == [], f"{len(thumbs)}")
    check("and the table has no thumbnail column", await c.eval(
        "!document.querySelector('.workshop-table th[aria-label=Thumbnail]')"))
    await toggle_thumbnails(c)


async def shine(c):
    print(f"\n== --mod --shine=ban,reservedslots,mapvote --maps=modded ({SHINE})")
    reset(SHINE)
    await load(c, SHINE)
    await open_tab(c, "Workshop")
    await settled(c)
    await search(c, "combat")
    fix = await row(c, "1e62a2ce")
    check("a result loaded now says installed and loaded",
          fix and "installed" in fix[2] and "loaded now" in fix[2]
          and "Open in Mods" in fix[3] and "Install" not in fix[3], (fix or ["", "", ""])[2])
    ns2c = await row(c, "8ae61f8f")
    check("an installed one not in the cycle says installed only",
          ns2c and "installed" in ns2c[2] and "loaded now" not in ns2c[2]
          and "Open in Mods" in ns2c[3], (ns2c or ["", "", ""])[2])


async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            # Thumbnails are requested, and recorded, but never leave this box.
            await c.send("Network.setBlockedURLs", urls=["*steamusercontent.com*"])
            await c.send("Emulation.setDeviceMetricsOverride",
                         width=1280, height=1800, deviceScaleFactor=1, mobile=False)
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = (m) => { (window.__confirms ||= []).push(m);"
                                " return true; };"
                                "try { localStorage.removeItem('improved-webadmin.settings'); } catch {}")
            await stock(c)
            await mod(c)
            await shine(c)

            print("\n== every server")
            exceptions = [e for e in c.events if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions", not exceptions,
                  str(len(exceptions)) + (f": {exceptions[0]['params']['exceptionDetails'].get('text')}"
                                          if exceptions else ""))
            urls = [r["url"] for r in requests(c)]
            foreign = sorted({u for u in urls if not u.startswith((STOCK, MOD, SHINE))
                              and "steamusercontent.com" not in u})
            check("nothing else went anywhere but the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

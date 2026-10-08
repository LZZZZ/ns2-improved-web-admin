#!/usr/bin/env python3
"""Gate: the Performance tab, driven in a real browser against the mock.

The 2012 tab drew, and drew wrong: every poll re-appended the whole window
(CURRENT-UI defect 2). So the checks are about the data as much as the chart:

  * nothing is polled before the tab opens, or after it closes
  * on the mod, getperf is read with a cursor and the page holds exactly the
    windows the server served -- none twice; a history longer than a reply's
    60 is fetched page after page at once, not one page a poll
  * the y axis follows the configured tickrate (the mock runs 60, not 30)
  * a bad score is shown as bad, in words as well as colour, and an interp
    fail is flagged
  * a map change keeps the earlier map's windows
  * drag-to-zoom zooms every chart, and hovering one shows the same moment in
    the others
  * a theme switch rebuilds the charts cleanly
  * on a stock server only getperfdata is asked, and a refresh replaces the
    window instead of appending to it
  * nothing is fetched from anywhere but the server
  * tickrate, the slowest tick, score and players are four lines on one
    chart with one unitless axis (F1, as settled on the rig), the units in
    the legend
  * the engine's tickstat, from the log: off until the Settings switch turns
    it on (F2), which moves only once the server's log confirms it; its
    charts join the same grid and hold exactly the lines served; its latest
    line joins the window's in one summary, and the status line goes while
    it logs; a snapshot p99 over what bwlimit allows is an error with the
    bwlimit that fixes it; the engine's bwlimit warning is shown; a map
    change keeps the earlier lines; turning it off is confirmed the same way
  * no table view and no history line (Performance review, 2026-10-08)
  * a server whose log the mod cannot read says why, here and in Settings;
    a stock server's Settings says the switch needs the mod

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8094 --web web --mod --perf-window 2
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8100 --web web --mod --log=off
"""
import asyncio, json, os, sys, urllib.request
from urllib.parse import parse_qs, urlparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
LOGOFF = os.environ.get("LOGOFF_URL", "http://127.0.0.1:8100")
PORT = 9231

results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<58} {detail}")
    return ok


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.read().decode()


def server_windows(base):
    """Every window the server holds, following getperf's pages."""
    since, windows = 0, []
    for _ in range(20):
        r = json.loads(get(f"{base}/?request=getperf&since={since}&esince=999999"))
        windows += r["windows"]
        since = r["last_id"]
        if not r.get("more"):
            break
    r["windows"] = windows
    return r


def requests_of(c, kind, since=0):
    """Every request=<kind> the page sent after event index `since`, as
    (url, params). CDP.take_events keeps what it returns, so a check that
    wants "from now on" takes len(c.events) first and passes it here."""
    out = []
    for e in c.events[since:]:
        if e["method"] != "Network.requestWillBeSent":
            continue
        url = e["params"]["request"]["url"]
        q = parse_qs(urlparse(url).query)
        if q.get("request", [None])[0] == kind:
            out.append((url, q))
    return out


async def open_tab(c, base, name):
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={name!r}).click()")
    await asyncio.sleep(1.5)


async def window_points(c):
    """The windows the page holds: the headline chart's tickrate points."""
    return int(await chart(c, "Tickrate", "points") or 0)


async def click(c, text):
    return await c.eval("(()=>{const b=[...document.querySelectorAll('.perf-tab .btn')]"
                        f".find(b=>b.textContent.trim()==={text!r});if(b)b.click();return !!b;}})()")


async def attr(c, selector, name):
    return await c.eval(f"document.querySelector({selector!r})?.dataset[{name!r}] ?? null")


async def text(c, selector):
    return str(await c.eval(f"document.querySelector({selector!r})?.textContent||''"))


def engine_of(base):
    """getperf's engine report, every record it holds, following its pages."""
    esince, held = 0, {"tickstats": [], "perfmon": [], "events": []}
    for _ in range(20):
        e = json.loads(get(f"{base}/?request=getperf&since=999999&esince={esince}"))["engine"]
        for k in held:
            held[k] += e[k]
        esince = e["last_id"]
        if not e.get("more"):
            break
    e.update(held)
    return e


async def chart(c, title_start, attr):
    return await c.eval(
        "(()=>{const f=[...document.querySelectorAll('.perf-chart')]"
        f".find(f=>f.querySelector('figcaption').textContent.startsWith({title_start!r}));"
        f"return f ? f.dataset[{attr!r}] : null;}})()")


async def drag(c, title_start, x1, x2):
    """Mouse drag across a chart's plot area, from x1 to x2 (fractions)."""
    box = await c.eval(
        "(()=>{const f=[...document.querySelectorAll('.perf-chart')]"
        f".find(f=>f.querySelector('figcaption').textContent.startsWith({title_start!r}));"
        "f.scrollIntoView({block:'center'});"
        "const r=f.querySelector('.u-over').getBoundingClientRect();"
        "return [r.left,r.top,r.width,r.height];})()")
    left, top, width, height = box
    y = top + height / 2
    await c.send("Input.dispatchMouseEvent", type="mouseMoved",
                 x=left + width * x1, y=y)
    await c.send("Input.dispatchMouseEvent", type="mousePressed",
                 x=left + width * x1, y=y, button="left", clickCount=1)
    for i in range(1, 11):
        await c.send("Input.dispatchMouseEvent", type="mouseMoved", button="left",
                     x=left + width * (x1 + (x2 - x1) * i / 10), y=y)
    await c.send("Input.dispatchMouseEvent", type="mouseReleased",
                 x=left + width * x2, y=y, button="left", clickCount=1)
    await asyncio.sleep(0.5)
    return box


async def after_regular_line():
    """Wait for the mock's own 10 s tickstat line, so a forced one sent now is
    the newest for the next 10 s: the summary shows only the latest line."""
    n = len(engine_of(MOD)["tickstats"])
    for _ in range(60):
        await asyncio.sleep(0.2)
        if len(engine_of(MOD)["tickstats"]) != n:
            return


async def flip_tickstat(c):
    """Click the Settings switch and wait for its outcome; (commands sent, outcome)."""
    await open_tab(c, MOD, "Settings")
    await c.eval("document.querySelector('[data-tickstat-outcome]')?.remove()")
    mark = len(c.events)
    await c.eval("document.querySelector('input[name=tickstat]').click()")
    outcome = None
    for _ in range(20):
        await asyncio.sleep(0.5)
        outcome = await attr(c, "[data-tickstat-outcome]", "tickstatOutcome")
        if outcome:
            break
    sent = [q.get("cmd", [""])[0] for _, q in requests_of(c, "runcommand", mark)]
    return sent, outcome


async def tickstat_checks(c):
    print("\n== tickstat, from the server's log")
    await open_tab(c, MOD, "Performance")
    await asyncio.sleep(1)
    check("the engine status reads the log",
          await attr(c, ".perf-engine", "engine") == "log")
    status = await text(c, ".tickstat-status")
    check("no tickstat yet, it says a restart turns it off, and where to turn it on",
          await attr(c, ".perf-engine", "tickstatState") == "none"
          and "off after every restart" in status and "Settings turns it on" in status, status[:60])
    check("the tab has no tickstat button of its own (F2)",
          not await c.eval("[...document.querySelectorAll('.perf-tab .btn')]"
                           ".some(b=>b.textContent.includes('tickstat'))"))

    await open_tab(c, MOD, "Settings")
    check("Settings shows the server's tickstat, off",
          await attr(c, "[data-tickstat-switch]", "tickstatSwitch") == "log"
          and await c.eval("document.querySelector('input[name=tickstat]').checked") is False)
    sent, outcome = await flip_tickstat(c)
    check("its switch runs tickstat 10", sent == ["tickstat 10"], sent)
    check("and says it is on only once the server's log says so",
          outcome == "confirmed", f"{outcome}: {await text(c, '[data-tickstat-outcome]')}")
    check("the switch reads on", await c.eval("document.querySelector('input[name=tickstat]').checked") is True)
    await open_tab(c, MOD, "Performance")
    check("the state reads starting, or the line is gone because it is on",
          await attr(c, ".perf-engine", "tickstatState") in ("starting", None))

    for _ in range(3):
        get(f"{MOD}/__mock/tickstat?emit=1")
        await asyncio.sleep(0.3)
    await asyncio.sleep(2.6)
    check("seven more charts once lines arrive, in the same grid",
          await c.eval("document.querySelectorAll('.perf-grid .perf-chart').length") == 12)
    check("logging, the tab says nothing of it (the status line is gone)",
          await c.eval("document.querySelector('.perf-engine')") is None)
    strip = await text(c, ".perf-strip")
    check("the latest line joins the window's, in one summary, delivered against the target",
          await c.eval("document.querySelectorAll('.perf-strip').length") == 1
          and "tickrate" in strip and "/ 60 Hz" in strip and "tickstat's" in strip
          and "--" not in strip and await c.eval(
              "document.querySelector('.perf-strip').compareDocumentPosition("
              "document.querySelector('.perf-grid')) & Node.DOCUMENT_POSITION_FOLLOWING"),
          strip[:50])
    y_max = float(await chart(c, "Snapshot size", "yMax") or 0)
    budget = 131072 // 60
    check("the snapshot axis reaches what bwlimit allows", y_max >= budget * 1.15 - 1,
          f"y max {y_max:.0f}, allows {budget}")

    # The mock also logs a line of its own every 10 s: read until the page has
    # caught up with what the server serves, then compare.
    for _ in range(8):
        await asyncio.sleep(1)
        served = len(engine_of(MOD)["tickstats"])
        points = int(await chart(c, "Tick spacing", "points") or 0)
        if points == served:
            break
    check("the page holds exactly the lines served, each once",
          points == served, f"{points} points, {served} served")

    print("\n== bwlimit and choke")
    await after_regular_line()
    get(f"{MOD}/__mock/tickstat?snap_p99_bytes=4000&choked_pct=12.5&emit=1")
    await asyncio.sleep(2.6)
    fix = await attr(c, "[data-bwlimit-fix]", "bwlimitFix")
    note = await text(c, "[data-bwlimit-fix]")
    check("a snapshot p99 over what bwlimit allows is an error",
          await attr(c, "[data-snap-over]", "snapOver") == "1"
          and "tone-error" in str(await c.eval(
              "document.querySelector('[data-snap-over] b').className")))
    check("with the bwlimit that fixes it: p99 x sendrate",
          fix == str(4000 * 60) and "at least 240000" in note, note[:80])
    check("and the choke as a warning", await attr(c, "[data-choked]", "choked") == "12.5")
    get(f"{MOD}/?request=runcommand&cmd=bwlimit%2010000")
    await asyncio.sleep(2.6)
    warn = await text(c, "[data-bwlimit-warning]")
    check("the engine's bwlimit warning, with its suggestion",
          await attr(c, "[data-bwlimit-warning]", "bwlimitWarning") == "10000"
          and "bwlimit 122880 or more" in warn, warn[:60])
    await after_regular_line()
    get(f"{MOD}/__mock/tickstat?snap_p99_bytes=900&emit=1")
    await asyncio.sleep(2.6)
    fix = await attr(c, "[data-bwlimit-fix]", "bwlimitFix")
    note = await text(c, "[data-bwlimit-fix]")
    check("with the engine's warning out, the fix is its full-game floor when higher",
          fix == str(2048 * 60) and "a full game needs" in note and str(900 * 60) in note,
          note[:90])
    get(f"{MOD}/?request=runcommand&cmd=bwlimit%20131072")
    await asyncio.sleep(2.6)
    check("and it goes once bwlimit is changed",
          await c.eval("document.querySelector('[data-bwlimit-warning]')") is None)

    print("\n== a map change, then Stop")
    before = int(await chart(c, "Tick spacing", "points") or 0)
    get(f"{MOD}/?request=runcommand&cmd=sv_changemap%20ns2_tram")
    await asyncio.sleep(2.6)
    get(f"{MOD}/__mock/tickstat?emit=1")
    for _ in range(8):
        await asyncio.sleep(1)
        after = int(await chart(c, "Tick spacing", "points") or 0)
        served = len(engine_of(MOD)["tickstats"])
        if after == before + served and served > 0:
            break
    check("the earlier map's lines are kept, the new map's added",
          after == before + served and served > 0,
          f"{before} -> {after} points, {served} served on ns2_tram")

    await c.eval("window.__asked = 0; window.confirm = () => (window.__asked++, true)")
    sent, outcome = await flip_tickstat(c)
    check("turning it off asks first, for every admin",
          await c.eval("window.__asked") == 1, str(await c.eval("window.__asked")))
    check("and runs tickstat 0, confirmed by the log",
          sent == ["tickstat 0"] and outcome == "confirmed", f"{sent} {outcome}")
    await open_tab(c, MOD, "Performance")
    check("and the state reads off", await attr(c, ".perf-engine", "tickstatState") == "off")

    exceptions = c.take_events("Runtime.exceptionThrown")
    check("no uncaught exceptions with tickstat", not exceptions,
          [e["params"]["exceptionDetails"].get("text", "") for e in exceptions][:2])


async def main():
    for base in (MOD, STOCK, LOGOFF):
        get(f"{base}/__mock/reset")

    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Emulation.setDeviceMetricsOverride",
                         width=1400, height=1400, deviceScaleFactor=1, mobile=False)
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('improved-webadmin.settings'); } catch {}")

            print("\n== against a server carrying the mod's Lua")
            await c.send("Page.navigate", url=MOD + "/index.html")
            await asyncio.sleep(3.5)
            check("no getperf before the tab is opened",
                  len(requests_of(c, "getperf")) == 0)

            await open_tab(c, MOD, "Performance")
            await asyncio.sleep(4.5)   # two more 2 s windows, two more polls
            polls = requests_of(c, "getperf")
            first = polls[0][1].get("since", ["0"])[0] if polls else None
            later = [q.get("since", ["0"])[0] for _, q in polls[1:]]
            check("the first getperf starts from 0", first == "0", f"since={first}")
            check("later ones carry the cursor",
                  later and all(int(s) > 0 for s in later), f"since={later}")
            # The mock holds 180+ windows: the first poll is 0, 60, 120, ...
            # within the time a single poll interval would take.
            sinces = [int(q.get("since", ["0"])[0]) for _, q in polls]
            check("a long history comes in pages of 60, one after another",
                  sinces[:3] == [0, 60, 120], f"since={sinces[:5]}")
            replies = [json.loads(get(f"{MOD}/?request=getperf&since={n}&esince=999999"))
                       for n in (0, 60)]
            check("each page holds 60 and says there is more",
                  all(len(r["windows"]) == 60 and r["more"] is True for r in replies)
                  and replies[0]["last_id"] == 60, f"last_id {replies[0]['last_id']}")
            check("five charts on the mod",
                  await c.eval("document.querySelectorAll('.perf-chart').length") == 5)
            legend = json.loads(await c.eval(
                "JSON.stringify([...document.querySelector('.perf-chart.perf-wide')"
                ".querySelectorAll('.u-series .u-label')].map(l=>l.textContent))"))
            check("tickrate, slowest tick, score and players: four lines on one chart (F1)",
                  legend[1:] == ["tickrate", "slowest tick", "score", "players"], str(legend))
            check("the full width of the grid",
                  await c.eval("(f=>getComputedStyle(f).gridColumnStart)"
                               "(document.querySelector('.perf-chart.perf-wide'))") == "1")
            rates = str(await c.eval("document.querySelector('.perf-rates')?.textContent||''"))
            check("the configured rates are shown", "tick 60" in rates and "interp 85 ms" in rates,
                  rates[:60])

            check("no table view and no history line",
                  not await c.eval("[...document.querySelectorAll('.perf-tab .btn')]"
                                   ".some(b=>b.textContent.includes('table'))")
                  and not await c.eval("document.querySelector('.perf-tab table')")
                  and "windows. The server keeps" not in await text(c, ".perf-tab"))
            ok = False
            for _ in range(4):
                served = len(server_windows(MOD)["windows"])
                await asyncio.sleep(0.2)
                rows = await window_points(c)
                if rows == served:
                    ok = True
                    break
                await asyncio.sleep(1)
            check("the chart holds exactly the windows served, each once", ok,
                  f"{rows} points, {served} served")

            await asyncio.sleep(4.5)
            served2 = len(server_windows(MOD)["windows"])
            rows2 = await window_points(c)
            check("new windows are appended, not the window again",
                  abs(rows2 - served2) <= 1 and rows2 > rows, f"{rows} -> {rows2}, served {served2}")

            y_max = float(await chart(c, "Tickrate", "yMax") or 0)
            check("the tickrate axis follows the configured 60, not 30",
                  y_max >= 60 * 1.15 - 0.01, f"y max {y_max:.1f}")
            strip = str(await c.eval("document.querySelector('.perf-strip')?.textContent||''"))
            check("the strip compares against the configured rate", "/ 60" in strip, strip[:40])

            print("\n== a bad window is shown as bad")
            get(f"{MOD}/__mock/perf?score=-30&interp_fails=3&emit=1")
            await asyncio.sleep(2.6)
            score = await c.eval("document.querySelector('[data-score]')?.dataset.score")
            score_text = str(await c.eval(
                "document.querySelector('[data-score] b')?.textContent||''"))
            score_class = str(await c.eval(
                "document.querySelector('[data-score] b')?.className||''"))
            check("a score of -30 reads 'bad'", score == "bad" and "bad" in score_text,
                  score_text)
            check("in the error colour, beside the word", "tone-error" in score_class)
            fails = str(await c.eval(
                "document.querySelector('[data-interp-fails]')?.textContent||''"))
            check("interp fails are flagged", "3 fail" in fails and "past interp" in fails,
                  fails[:50])

            print("\n== zoom and a shared cursor")
            x_before = (float(await chart(c, "Entities", "xMin")),
                        float(await chart(c, "Entities", "xMax")))
            await drag(c, "Tickrate", 0.3, 0.6)
            x_after = (float(await chart(c, "Entities", "xMin")),
                       float(await chart(c, "Entities", "xMax")))
            check("dragging one chart zooms another",
                  x_after[1] - x_after[0] < (x_before[1] - x_before[0]) * 0.5,
                  f"{x_before[1]-x_before[0]:.0f}s -> {x_after[1]-x_after[0]:.0f}s")
            check("and offers Reset zoom", await c.eval(
                "[...document.querySelectorAll('.perf-tab .btn')]"
                ".some(b=>b.textContent==='Reset zoom')"))
            box = await c.eval(
                "(()=>{const r=document.querySelector('.perf-chart .u-over')"
                ".getBoundingClientRect();return [r.left,r.top,r.width,r.height];})()")
            await c.send("Input.dispatchMouseEvent", type="mouseMoved",
                         x=box[0] + box[2] * 0.5, y=box[1] + box[3] * 0.5)
            await asyncio.sleep(0.4)
            other = str(await c.eval(
                "(()=>{const f=[...document.querySelectorAll('.perf-chart')]"
                ".find(f=>f.querySelector('figcaption').textContent.startsWith('Entities'));"
                "return f.querySelector('.u-series:nth-child(2) .u-value').textContent;})()"))
            check("hovering one chart reads out the same moment in another",
                  other not in ("", "--"), f"entities {other}")
            await c.eval("[...document.querySelectorAll('.perf-tab .btn')]"
                         ".find(b=>b.textContent==='Reset zoom').click()")
            await asyncio.sleep(0.5)

            print("\n== a map change")
            before = await window_points(c)
            get(f"{MOD}/?request=runcommand&cmd=sv_changemap%20ns2_veil")
            await asyncio.sleep(6.5)
            after = await window_points(c)
            served_new = server_windows(MOD)["windows"]
            check("the earlier map's windows are kept, the new map's read from id 1",
                  abs(after - before - len(served_new)) <= 1 and served_new
                  and served_new[0]["id"] == 1,
                  f"{before} -> {after} points, {len(served_new)} served on ns2_veil")

            print("\n== theme switch and leaving the tab")
            await c.eval("(()=>{const s=[...document.querySelectorAll('.statusbar select')]"
                         ".find(s=>[...s.options].some(o=>o.value==='light'));"
                         "s.value='light';s.dispatchEvent(new Event('change',{bubbles:true}));})()")
            await asyncio.sleep(1)
            check("the charts are rebuilt in the light theme",
                  await c.eval("document.querySelectorAll('.perf-chart canvas').length") == 5
                  and await c.eval("document.documentElement.dataset.theme") == "light")
            await open_tab(c, MOD, "Players")
            mark = len(c.events)
            await asyncio.sleep(5)
            check("no getperf once the tab is closed", len(requests_of(c, "getperf", mark)) == 0)

            await tickstat_checks(c)

            exceptions = c.take_events("Runtime.exceptionThrown")
            stock_mark = len(c.events)
            check("no uncaught exceptions on the mod", not exceptions,
                  [e["params"]["exceptionDetails"].get("text", "") for e in exceptions][:2])

            print("\n== against a stock server")
            await c.send("Page.navigate", url=STOCK + "/index.html")
            await asyncio.sleep(3.5)
            mark = len(c.events)
            await open_tab(c, STOCK, "Performance")
            await asyncio.sleep(1)
            banners = str(await c.eval(
                "[...document.querySelectorAll('.banner h2')].map(e=>e.textContent).join(' | ')"))
            check("the tab explains the one-a-minute readings", "one reading a minute" in banners,
                  banners[-40:])
            check("two charts on stock",
                  await c.eval("document.querySelectorAll('.perf-chart').length") == 2)
            check("no engine section on stock",
                  await c.eval("document.querySelector('.perf-engine')") is None)
            await open_tab(c, STOCK, "Settings")
            said = await text(c, "[data-tickstat-switch]")
            check("Settings says tickstat needs the mod",
                  await attr(c, "[data-tickstat-switch]", "tickstatSwitch") == "stock"
                  and "Needs this panel's mod" in said, said[:50])
            await open_tab(c, STOCK, "Performance")
            for _ in range(3):
                await c.eval("[...document.querySelectorAll('.perf-tab .btn')]"
                             ".find(b=>b.textContent==='Refresh').click()")
                await asyncio.sleep(0.6)
            served = len(json.loads(get(f"{STOCK}/?request=getperfdata")))
            rows = await window_points(c)
            check("four reads later the window is replaced, not appended",
                  rows == served, f"{rows} points, {served} served")
            check("only getperfdata was asked", len(requests_of(c, "getperf", mark)) == 0
                  and len(requests_of(c, "getperfdata", mark)) >= 4)

            third = []
            for e in c.events:
                if e["method"] == "Network.requestWillBeSent":
                    url = e["params"]["request"]["url"]
                    if not (url.startswith(MOD) or url.startswith(STOCK)
                            or url.startswith("data:") or url == "about:blank"):
                        third.append(url)
            check("nothing fetched from a third party", not third, third[:2])
            exceptions = [e for e in c.events[stock_mark:]
                          if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions on stock", not exceptions,
                  [e["params"]["exceptionDetails"].get("text", "") for e in exceptions][:2])

            print("\n== a server whose log the mod cannot read")
            await c.send("Page.navigate", url=LOGOFF + "/index.html")
            await asyncio.sleep(3.5)
            await open_tab(c, LOGOFF, "Performance")
            await asyncio.sleep(1)
            said = await text(c, "[data-engine-error]")
            check("the engine section says the log is not readable, and why",
                  await attr(c, ".perf-engine", "engine") == "none"
                  and "not readable" in said and "No such file" in said, said[:70])
            check("and offers no tickstat button",
                  not await c.eval("[...document.querySelectorAll('.perf-tab .btn')]"
                                   ".some(b=>b.textContent.includes('tickstat'))"))
            await open_tab(c, LOGOFF, "Settings")
            await asyncio.sleep(1)
            said = await text(c, "[data-tickstat-switch]")
            check("and Settings offers no switch, saying why",
                  await attr(c, "[data-tickstat-switch]", "tickstatSwitch") == "none"
                  and "not readable" in said
                  and not await c.eval("document.querySelector('input[name=tickstat]')"), said[:60])
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

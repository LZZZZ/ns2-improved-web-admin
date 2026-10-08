#!/usr/bin/env python3
"""The 2012 Performance tab, in a real browser.

Loads the shipped 2012 panel from the live rig in headless Chrome and
checks, in order:
  1. is $.jqplot actually defined?           (CURRENT-UI.md defect 1)
  2. does the chart render?
  3. does the lastPerfTIme typo re-append every sample?  (defect 2)
  4. is the retry branch dead?                           (defect 3)
  5. does the page reach fonts.googleapis.com?           (defect 11)
"""
import asyncio, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

USER = os.environ["WEBUSER"]; PASS = os.environ["WEBPASS"]
BASE = "http://127.0.0.1:" + os.environ["WEBPORT"] + "/index.html"


def show(label, value):
    print(f"   {label:<44} {value}")


async def main():
    proc, _ = launch_chrome()
    try:
        async with CDP(page_target()) as c:
            await c.send("Runtime.enable"); await c.send("Log.enable")
            await c.send("Page.enable"); await c.send("Network.enable")
            await c.send("Fetch.enable", handleAuthRequests=True,
                         patterns=[{"urlPattern": "*"}])

            async def pump():
                seen = 0
                while True:
                    await asyncio.sleep(0.01)
                    while seen < len(c.events):
                        e = c.events[seen]; seen += 1
                        try:
                            if e["method"] == "Fetch.requestPaused":
                                await c.send("Fetch.continueRequest",
                                             requestId=e["params"]["requestId"])
                            elif e["method"] == "Fetch.authRequired":
                                await c.send("Fetch.continueWithAuth",
                                             requestId=e["params"]["requestId"],
                                             authChallengeResponse={
                                                 "response": "ProvideCredentials",
                                                 "username": USER, "password": PASS})
                        except Exception:
                            pass
            t = asyncio.create_task(pump())

            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(6)

            print("== 1. is jqPlot on the page?")
            show("typeof $.jqplot", await c.eval("typeof $.jqplot"))
            show("typeof $.jqplot.DateAxisRenderer",
                 await c.eval("typeof $.jqplot.DateAxisRenderer"))
            show("$.fn.jquery", await c.eval("$.fn.jquery"))
            show("<script src> tags", await c.eval(
                "[...document.scripts].map(s=>s.getAttribute('src')).filter(Boolean).join(', ')"))

            print("\n== 2. open the Performance tab")
            mark = len(c.events)
            await c.eval("[...document.querySelectorAll('#tabs > li')]"
                         ".find(l=>l.textContent.trim()==='Performance').click()")
            await asyncio.sleep(2)
            show("#performancecontent visible",
                 await c.eval("document.getElementById('performancecontent').offsetParent!==null"))
            show("#perfchart child elements",
                 await c.eval("document.getElementById('perfchart').children.length"))
            show("canvas elements inside #perfchart",
                 await c.eval("document.querySelectorAll('#perfchart canvas').length"))
            show("chart title text",
                 await c.eval("(document.querySelector('#perfchart .jqplot-title')||{}).textContent"))
            show("legend labels",
                 await c.eval("[...document.querySelectorAll("
                              "'#perfchart table.jqplot-table-legend tr')]"
                              ".map(r=>r.cells[1].textContent).join(', ')"))
            errors = [e for e in c.events[mark:] if e["method"] == "Runtime.exceptionThrown"]
            show("uncaught exceptions during the click", len(errors))
            for e in errors:
                d = e["params"]["exceptionDetails"]
                print(f"      {d.get('text')} :: "
                      f"{d.get('exception',{}).get('description','').splitlines()[0]}")

            print("\n== 3. the lastPerfTIme typo (defect 2)")
            show("samples getperfdata returns",
                 await c.eval("(async()=>(await (await fetch('/?request=getperfdata')).json()).length)()",
                              await_promise=True))
            before = await c.eval("performance_data[0].length")
            show("performance_data[0].length after load", before)
            show("window.lastPerfTime  (read by the guard)", await c.eval("window.lastPerfTime"))
            show("window.lastPerfTIme  (written by the typo)", await c.eval("window.lastPerfTIme"))
            for n in (1, 2, 3):
                await c.eval("refreshPerformance()")
                await asyncio.sleep(1.5)
                show(f"performance_data[0].length after poll {n}",
                     await c.eval("performance_data[0].length"))
            show("lastPerfTime still 0?", await c.eval("window.lastPerfTime === 0"))

            print("\n== 4. the dead retry branch (defect 3)")
            show("performance_data.length (tested against 0)",
                 await c.eval("performance_data.length"))
            show("`performance_data.length == 0` can ever be true",
                 await c.eval("performance_data.length == 0"))

            print("\n== 5. outbound requests off the server (defect 11)")
            urls = sorted({e["params"]["request"]["url"]
                           for e in c.events if e["method"] == "Network.requestWillBeSent"})
            for u in urls:
                if "127.0.0.1" not in u:
                    show("EXTERNAL", u)
            show("total distinct requests", len(urls))
            show("requests to fonts.googleapis.com",
                 sum(1 for u in urls if "fonts.googleapis.com" in u))
            failed = [(e["params"].get("errorText"), e["params"].get("type"))
                      for e in c.events if e["method"] == "Network.loadingFailed"]
            show("failed loads", failed or "none")
            t.cancel()
    finally:
        proc.kill()

asyncio.run(main())

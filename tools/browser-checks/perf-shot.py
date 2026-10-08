#!/usr/bin/env python3
"""Screenshot the Performance tab of the shipped panel, and read the chart's
own state, so the "does it render?" question is answered by a picture as
well as by a property check."""
import asyncio, base64, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

USER = os.environ["WEBUSER"]; PASS = os.environ["WEBPASS"]
BASE = "http://127.0.0.1:" + os.environ["WEBPORT"] + "/index.html"
PORT = 9223

async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Emulation.setDeviceMetricsOverride",
                         width=1280, height=900, deviceScaleFactor=1, mobile=False)
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
                                await c.send("Fetch.continueRequest", requestId=e["params"]["requestId"])
                            elif e["method"] == "Fetch.authRequired":
                                await c.send("Fetch.continueWithAuth",
                                    requestId=e["params"]["requestId"],
                                    authChallengeResponse={"response":"ProvideCredentials",
                                                           "username":USER,"password":PASS})
                        except Exception:
                            pass
            t = asyncio.create_task(pump())
            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(6)
            await c.eval("[...document.querySelectorAll('#tabs > li')]"
                         ".find(l=>l.textContent.trim()==='Performance').click()")
            await asyncio.sleep(2)

            for label, expr in [
                ("$.jqplot.version", "$.jqplot.version"),
                ("plot object exists", "!!(window._perfplot)"),
                ("series count", "document.querySelectorAll('#perfchart canvas.jqplot-series-canvas').length"),
                ("axis tick labels (x)", "[...document.querySelectorAll('#perfchart .jqplot-xaxis-tick')].map(e=>e.textContent).join(' | ')"),
                ("axis tick labels (y)", "[...document.querySelectorAll('#perfchart .jqplot-yaxis-tick')].map(e=>e.textContent).join(' | ')"),
                ("legend rows", "document.querySelectorAll('#perfchart .jqplot-table-legend tr').length"),
                ("legend html", "(document.querySelector('#perfchart .jqplot-table-legend')||{}).outerHTML"),
                ("chart px size", "(r=>r.width+'x'+r.height)(document.getElementById('perfchart').getBoundingClientRect())"),
                ("points plotted", "performance_data.map(s=>s.length).join(' / ')"),
            ]:
                print(f"   {label:<24} {await c.eval(expr)}")

            shot = await c.send("Page.captureScreenshot", format="png",
                                clip={"x":0,"y":0,"width":1280,"height":760,"scale":1})
            open("perf-tab.png","wb").write(base64.b64decode(shot["data"]))
            print("\n   wrote perf-tab.png")
            t.cancel()
    finally:
        proc.kill()

asyncio.run(main())

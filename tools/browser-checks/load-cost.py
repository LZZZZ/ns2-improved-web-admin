#!/usr/bin/env python3
"""What one page load of the shipped panel actually costs, with no tab
clicked -- the baseline the replacement's size budget is measured against."""
import asyncio, os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

USER = os.environ["WEBUSER"]; PASS = os.environ["WEBPASS"]
BASE = "http://127.0.0.1:" + os.environ["WEBPORT"] + "/index.html"
PORT = 9224

async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Network.setCacheDisabled", cacheDisabled=True)
            await c.send("Fetch.enable", handleAuthRequests=True, patterns=[{"urlPattern": "*"}])
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
                                await c.send("Fetch.continueWithAuth", requestId=e["params"]["requestId"],
                                    authChallengeResponse={"response":"ProvideCredentials","username":USER,"password":PASS})
                        except Exception: pass
            t = asyncio.create_task(pump())
            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(20)     # let the load settle; no tab is clicked

            local = collections.Counter(); remote = collections.Counter()
            lbytes = collections.Counter(); rbytes = collections.Counter()
            urls = {}
            for e in c.events:
                if e["method"] == "Network.requestWillBeSent":
                    urls[e["params"]["requestId"]] = e["params"]["request"]["url"]
                elif e["method"] == "Network.loadingFinished":
                    u = urls.get(e["params"]["requestId"], "")
                    host = u.split("/")[2] if "//" in u else "?"
                    n = e["params"].get("encodedDataLength", 0)
                    if "127.0.0.1" in host:
                        local[host] += 1; lbytes[host] += n
                    else:
                        remote[host] += 1; rbytes[host] += n
            print("one page load of the shipped panel, no tab clicked, cache off\n")
            print(f"  from the game server : {sum(local.values()):3d} requests"
                  f"  {sum(lbytes.values())/1024:8.1f} KB")
            for h, n in local.most_common():
                print(f"      {h:<34} {n:3d}  {lbytes[h]/1024:8.1f} KB")
            print(f"\n  from the internet    : {sum(remote.values()):3d} requests"
                  f"  {sum(rbytes.values())/1024:8.1f} KB")
            for h, n in remote.most_common():
                print(f"      {h:<34} {n:3d}  {rbytes[h]/1024:8.1f} KB")
            hidden = await c.eval(
                "document.getElementById('modscontent').offsetParent === null")
            rows = await c.eval('document.querySelectorAll("#modbrowser_mods > *").length')
            print(f"\n  Mods tab still hidden    : {hidden}")
            print(f"  mod rows rendered anyway : {rows}")
            t.cancel()
    finally:
        proc.kill()

asyncio.run(main())

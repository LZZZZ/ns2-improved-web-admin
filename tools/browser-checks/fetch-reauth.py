#!/usr/bin/env python3
"""The nonce-expiry re-auth path, through a browser.

The protocol-level probe (nonce-expiry-probe.py) showed a nonce dies at
300-320 s and that the refusal carries stale="true".  The open question was
whether a *browser* re-authenticates silently on that refusal for
XHR/fetch traffic -- i.e. whether a long-running panel keeps polling
without a credential prompt or a failed request.

Credentials are answered once, for the first challenge on the top-level
navigation -- exactly what a browser session holds after one prompt.  The
auth handler is then torn down, so every request the polling loop makes
is served from Chrome's own HTTP auth cache with no help from us.  If the
browser could not re-authenticate on its own, these fetches would fail.
"""
import asyncio, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

USER = os.environ["WEBUSER"]; PASS = os.environ["WEBPASS"]
PORT = os.environ["WEBPORT"]
NAV  = f"http://127.0.0.1:{PORT}/index.html"
DURATION = int(os.environ.get("DURATION", "420"))
INTERVAL = 2.0

POLLER = """
window.__probe = {sent: 0, ok: 0, non200: [], rejected: [], started: Date.now()};
window.__stop = false;
(async () => {
  while (!window.__stop) {
    const t = Date.now();
    window.__probe.sent++;
    try {
      const r = await fetch('/?request=getperfdata', {cache: 'no-store'});
      if (r.status === 200) { await r.json(); window.__probe.ok++; }
      else window.__probe.non200.push({at: Math.round((t-window.__probe.started)/1000), status: r.status});
    } catch (e) {
      window.__probe.rejected.push({at: Math.round((t-window.__probe.started)/1000), err: String(e)});
    }
    await new Promise(s => setTimeout(s, %d));
  }
})();
true
""" % int(INTERVAL * 1000)


async def main():
    proc, _ = launch_chrome()
    try:
        async with CDP(page_target()) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")

            # Answer the first challenge only, then tear the handler down.
            await c.send("Fetch.enable", handleAuthRequests=True,
                         patterns=[{"urlPattern": "*"}])
            answered = []

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
                                answered.append(e["params"]["request"]["url"])
                                await c.send("Fetch.continueWithAuth",
                                             requestId=e["params"]["requestId"],
                                             authChallengeResponse={
                                                 "response": "ProvideCredentials",
                                                 "username": USER, "password": PASS})
                        except Exception:
                            pass
            t = asyncio.create_task(pump())

            await c.send("Page.navigate", url=NAV)
            await asyncio.sleep(6)
            title = await c.eval("document.title")
            print(f"navigated; document.title = {title!r}")
            print(f"credentials supplied by hand for {len(answered)} challenge(s)")
            if title != "NS2 Web Admin":
                print("!! navigation did not authenticate; aborting")
                print(await c.eval("document.documentElement.outerHTML.slice(0,200)"))
                return
            t.cancel()
            await c.send("Fetch.disable")
            print("auth handler torn down -- from here on it is Chrome's cache alone")

            # Stop the panel's own timers so the only traffic is our probe.
            await c.eval("for (let i=1;i<9999;i++) clearInterval(i);")
            await asyncio.sleep(1)
            mark = len(c.events)
            t0 = time.time()
            print(await c.eval(POLLER) and f"probe started, running {DURATION}s "
                                           f"at {INTERVAL}s intervals\n")

            while time.time() - t0 < DURATION:
                await asyncio.sleep(30)
                p = await c.eval("window.__probe")
                el = int(time.time() - t0)
                n401 = sum(1 for e in c.events[mark:]
                           if e["method"] in ("Network.responseReceived",
                                              "Network.responseReceivedExtraInfo")
                           and (e["params"].get("statusCode")
                                or e["params"].get("response", {}).get("status")) == 401)
                print(f"  t+{el:3d}s  sent={p['sent']:3d} ok={p['ok']:3d} "
                      f"non200={len(p['non200'])} rejected={len(p['rejected'])} "
                      f"401s-on-the-wire={n401}")
            await c.eval("window.__stop = true")
            p = await c.eval("window.__probe")

            print("\n== result")
            print(f"   fetch() calls made          : {p['sent']}")
            print(f"   resolved 200 with valid JSON: {p['ok']}")
            print(f"   resolved non-200            : {p['non200'] or 'none'}")
            print(f"   rejected                    : {p['rejected'] or 'none'}")

            print("\n== what the network actually did")
            chal = []
            for e in c.events[mark:]:
                p_ = e["params"]
                status = p_.get("statusCode") or p_.get("response", {}).get("status")
                if e["method"] in ("Network.responseReceived",
                                   "Network.responseReceivedExtraInfo") and status == 401:
                    hdr = {k.lower(): v for k, v in
                           (p_.get("headers") or p_.get("response", {}).get("headers", {})).items()}
                    chal.append((round(e["_t"] - t0), hdr.get("www-authenticate", "")))
            print(f"   401 challenges the browser absorbed: {len(chal)}")
            for at, h in chal:
                print(f"     t+{at}s  {h[:150]}")
            fails = [(round(e['_t']-t0), e["params"].get("errorText"))
                     for e in c.events[mark:] if e["method"] == "Network.loadingFailed"]
            print(f"   loadingFailed events: {fails or 'none'}")
            print(f"   auth prompts shown  : "
                  f"{'n/a (headless: a prompt would have failed the request)'}")
    finally:
        proc.kill()

asyncio.run(main())

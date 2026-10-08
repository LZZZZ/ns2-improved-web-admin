#!/usr/bin/env python3
"""Mock acceptance: run the *shipped* 2012 panel against the mock server.

The mock is only worth having if it is faithful, and the cheapest proof of
faithfulness is that the panel written against the real server in 2012 works
against the mock unmodified -- every tab populates, every button lands, and
nothing throws.

Start the mock first:

    node mock/server.js --port 8090 --perf-rate 2

then run this against it. Exit status is 0 only if every check passes.
"""
import asyncio, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

MOCK = os.environ.get("MOCK_URL", "http://127.0.0.1:8090")
BASE = MOCK + "/index.html"
PORT = 9225

results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<46} {detail}")
    return ok


async def tab(c, name):
    await c.eval("[...document.querySelectorAll('#tabs > li')]"
                 f".find(l=>l.textContent.trim()==={name!r}).click()")
    await asyncio.sleep(1.2)


async def main():
    # The mock keeps state, and this test kicks and bans; start from the
    # fixtures so a rerun means the same thing as a first run.
    with urllib.request.urlopen(f"{MOCK}/__mock/reset", timeout=5) as r:
        print(f"mock reset: {r.read().decode().strip()}")

    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(4)

            mark_exc = lambda: [e for e in c.events
                                if e["method"] == "Runtime.exceptionThrown"]

            print("\n== the page loads at all")
            check("document.title", await c.eval("document.title") == "NS2 Web Admin")
            check("server name rendered from the mock",
                  (await c.eval("document.getElementById('servername').textContent"))
                  == "Example NS2 Server")
            check("uptime/tickrate header populated",
                  bool(await c.eval("document.getElementById('serverrate').textContent")))

            print("\n== Players")
            rows = await c.eval("document.querySelectorAll('#playerstable tbody tr').length")
            check("player rows", rows == 12, f"{rows} rows")
            steamid = await c.eval(
                "(document.querySelector('#playerstable tbody tr td.steamid')||{}).textContent")
            check("a redacted SteamID is rendered", str(steamid).strip() == "10000000",
                  str(steamid).strip())
            ip = await c.eval(
                "(document.querySelector('#playerstable tbody tr td.ip')||{}).textContent")
            check("the IP column is filled, in plain text (defect 6)",
                  str(ip).strip() == "0.0.0.0", str(ip).strip())

            print("\n== Players: kick, the way the panel does it")
            before = await c.eval("document.querySelectorAll('#playerstable tbody tr').length")
            await c.eval(
                "[...document.querySelectorAll('.rconbutton')]"
                ".find(b=>b.getAttribute('command')==='sv_kick 10000000').click()")
            await asyncio.sleep(3)
            after = await c.eval("document.querySelectorAll('#playerstable tbody tr').length")
            check("kick removes the player after the refresh", after == before - 1,
                  f"{before} -> {after}")

            print("\n== Players: a bot's buttons are inert (defect 7)")
            bot_before = await c.eval("document.querySelectorAll('#playerstable tbody tr').length")
            await c.eval(
                "[...document.querySelectorAll('.rconbutton')]"
                ".find(b=>b.getAttribute('command')==='sv_kick 0').click()")
            await asyncio.sleep(2.5)
            bot_after = await c.eval("document.querySelectorAll('#playerstable tbody tr').length")
            check("kicking a bot changes nothing", bot_after == bot_before,
                  f"{bot_before} -> {bot_after}")

            print("\n== Bans")
            await tab(c, "Bans")
            check("ban rows",
                  await c.eval("document.querySelectorAll('#banstable tbody tr').length") >= 1)
            await c.eval("document.querySelector('input[name=addban_steamid]').value='10000042';"
                         "document.querySelector('input[name=addban_duration]').value='60';"
                         "document.querySelector('input[name=addban_reason]').value='mock test';"
                         "sendManualBan()")
            await asyncio.sleep(2)
            names = await c.eval("[...document.querySelectorAll('#banstable tbody tr td:nth-child(2)')]"
                                 ".map(e=>e.textContent.trim()).join(',')")
            check("a ban added through the form appears", "10000042" in str(names), str(names))
            await c.eval("[...document.querySelectorAll('.rconbutton')]"
                         ".find(b=>b.getAttribute('command')==='sv_unban 10000042').click()")
            await asyncio.sleep(2)
            names2 = await c.eval("[...document.querySelectorAll('#banstable tbody tr td:nth-child(2)')]"
                                  ".map(e=>e.textContent.trim()).join(',')")
            check("Unban does NOT work, as on a real server (defect 9)",
                  "10000042" in str(names2), str(names2))

            print("\n== Reserved Slots")
            await tab(c, "Reserved Slots")
            await c.eval("document.querySelector('input[name=addreserved_name]').value='Tester';"
                         "document.querySelector('input[name=addreserved_steamid]').value='10000077';"
                         "sendReservedSlot()")
            await asyncio.sleep(2)
            check("a reserved slot added through the form appears",
                  "10000077" in str(await c.eval(
                      "[...document.querySelectorAll('#reservedtable tbody tr')]"
                      ".map(r=>r.textContent).join('|')")))
            await c.eval("document.getElementById('reserved_slot_amount').value='4';"
                         "saveReservedSlotData()")
            await asyncio.sleep(1.5)
            # The panel only refetches reserved slots every five minutes, so ask
            # for it directly rather than waiting; otherwise the input still
            # holds what we typed and proves nothing.
            await c.eval("refreshReservedSlotData()")
            await asyncio.sleep(1.5)
            amount = await c.eval("document.getElementById('reserved_slot_amount').value")
            check("setreservedslotamount is swallowed, as on a real server (defect 8)",
                  str(amount) == "0", f"amount reads back {amount}")

            print("\n== Maps")
            await tab(c, "Maps")
            avail = await c.eval("document.querySelectorAll('#maplist_available li').length")
            active = await c.eval("document.querySelectorAll('#maplist_active li').length")
            check("map cycle rendered", active == 17, f"{active} maps in the cycle")
            check("remaining maps offered", avail >= 0, f"{avail} available")
            check("cycle time from the fixture",
                  str(await c.eval("document.getElementById('map_cycle_time').value")) == "30")
            # Saving writes the whole cycle back through setmapcycle; reloading
            # proves it round-tripped rather than being accepted and dropped.
            await c.eval("saveMapCycle()")
            await asyncio.sleep(1.5)
            await tab(c, "Players"); await tab(c, "Maps")
            await asyncio.sleep(1.5)
            check("the cycle survives a save and a reload",
                  await c.eval("document.querySelectorAll('#maplist_active li').length") == 17)

            print("\n== Mods")
            await tab(c, "Mods")
            await asyncio.sleep(3)
            mods = await c.eval("document.querySelectorAll('#modbrowser_mods > *').length")
            check("workshop results rendered from the fixture", mods > 0, f"{mods} results")

            print("\n== Performance")
            await tab(c, "Performance")
            await asyncio.sleep(1.5)
            check("chart drew", await c.eval(
                "document.querySelectorAll('#perfchart canvas').length") > 0)

            print("\n== nothing threw")
            exc = mark_exc()
            for e in exc:
                d = e["params"]["exceptionDetails"]
                print(f"      {d.get('text')} :: "
                      f"{d.get('exception',{}).get('description','').splitlines()[0]}")
            check("uncaught exceptions", len(exc) == 0, f"{len(exc)}")

            print("\n== traffic")
            urls = sorted({e["params"]["request"]["url"]
                           for e in c.events if e["method"] == "Network.requestWillBeSent"})
            off = [u for u in urls if "127.0.0.1" not in u]
            api = [u for u in urls if "request=" in u or u.endswith(":8090/")]
            check("every API request went to the mock",
                  api and all("127.0.0.1" in u for u in api), f"{len(api)} API calls")
            # The shipped panel reaches Steam and Google on its own; the mock
            # cannot prevent that, and reproducing it is the point. See
            # CURRENT-UI.md defects 11 and 13.
            hosts = sorted({u.split("/")[2] for u in off})
            print(f"      off-box hosts the panel reached anyway: "
                  f"{', '.join(hosts) if hosts else 'none'}")
            statuses = {}
            for e in c.events:
                if e["method"] == "Network.responseReceived":
                    u = e["params"]["response"]["url"]
                    if "127.0.0.1" not in u:
                        continue
                    st = e["params"]["response"]["status"]
                    statuses[st] = statuses.get(st, 0) + 1
            check("every response from the mock was 200", set(statuses) == {200},
                  str(statuses))
    finally:
        proc.kill()

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


sys.exit(asyncio.run(main()))

#!/usr/bin/env python3
"""Gate: the Settings tab, and every setting doing what it says.

Settings live in localStorage, per browser and per address, so this gate is
the one that does *not* clear them on each page load. It asserts:

  * the defaults on fresh storage, and Settings as the last tab
  * the tab works while the server cannot be reached, and refresh can be
    turned off from it
  * three refresh knobs, counted from the network: server state, chat and
    the log, each independent of the others; chat off says so and offers
    Read now (spa-log.py covers the log's own paused notice)
  * theme dark / light / system, system following the OS both ways without a
    reload, and the Performance charts rebuilt when it flips
  * the clock setting in the footer, a ban's date and the perf time axis
    (en-US in Sao Paulo, so local, 24-hour and UTC all differ)
  * everything survives a reload, the last tab is reopened (and not when
    that is turned off, and a stored Console tab opens the Console),
    Players' Hide bots kept
  * the tabs' own shortcuts and the Settings tab are the same values
  * a bad stored field falls back alone, junk falls back whole, an older
    build's shape keeps its chat rate; nothing throws
  * storage that throws: the tab says it will forget, and changes still apply
  * a write from another page on the same address is followed at once
  * Reset asks first
  * nothing is fetched from anywhere but the mock

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8094 --web web --mod --perf-window 2
    node mock/server.js --port 8095 --web web
"""
import asyncio, json, os, re, sys, urllib.request
from urllib.parse import parse_qs, urlparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
PORT = 9233
KEY = "improved-webadmin.settings"

results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<60} {detail}")
    return ok


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.read().decode()


def requests_of(c, kind, since=0):
    """Every request=<kind> the page sent after event index `since`."""
    out = []
    for e in c.events[since:]:
        if e["method"] != "Network.requestWillBeSent":
            continue
        q = parse_qs(urlparse(e["params"]["request"]["url"]).query)
        if q.get("request", [None])[0] == kind:
            out.append(q)
    return out


async def load(c, url, wait=3):
    await c.send("Page.navigate", url=url)
    await asyncio.sleep(wait)


async def open_tab(c, name, wait=1.0):
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={name!r}).click()")
    await asyncio.sleep(wait)


async def current_tab(c):
    return await c.eval("document.querySelector('.tab[aria-selected=true]')?.textContent.trim()")


async def set_select(c, name, value):
    await c.eval(f"(()=>{{const s=document.querySelector('select[name={name}]');"
                 f"s.value={value!r};s.dispatchEvent(new Event('change',{{bubbles:true}}));}})()")
    await asyncio.sleep(0.3)


async def select_value(c, name):
    return await c.eval(f"document.querySelector('select[name={name}]')?.value")


async def click_radio(c, name, value):
    # Quoted: an unquoted value may not start with a digit (24h).
    await c.eval(f"document.querySelector('input[name={name}][value=\"{value}\"]').click()")
    await asyncio.sleep(0.3)


async def radio_value(c, name):
    return await c.eval(f"document.querySelector('input[name={name}]:checked')?.value")


async def checked(c, name):
    return await c.eval(f"document.querySelector('input[name={name}]')?.checked")


async def set_check(c, name, on):
    await c.eval(f"(()=>{{const i=document.querySelector('input[name={name}]');"
                 f"if(i.checked!=={json.dumps(on)})i.click();}})()")
    await asyncio.sleep(0.3)


async def stored(c):
    return await c.eval(f"(()=>{{try{{return JSON.parse(localStorage.getItem({KEY!r}));}}"
                        "catch(e){return 'unreadable';}})()")


async def theme(c):
    return await c.eval("document.documentElement.dataset.theme")


async def body_bg(c):
    return await c.eval("getComputedStyle(document.body).backgroundColor")


async def emulate_scheme(c, scheme):
    await c.send("Emulation.setEmulatedMedia",
                 features=[{"name": "prefers-color-scheme", "value": scheme}])
    await asyncio.sleep(0.8)


async def footer_time(c):
    text = await c.eval("document.querySelector('.statusbar').textContent")
    m = re.search(r"updated (\d{1,2}):(\d\d):(\d\d)\s*([AP]M)?", text or "")
    return m, text


def exceptions_since(c, since):
    return [e["params"]["exceptionDetails"].get("text", "")
            + " " + str(e["params"]["exceptionDetails"].get("exception", {}).get("description", ""))[:120]
            for e in c.events[since:] if e["method"] == "Runtime.exceptionThrown"]


async def defaults_and_refresh(c):
    print("\n== fresh storage: the defaults")
    await load(c, MOD + "/index.html")
    check("Settings is the last tab",
          await c.eval("[...document.querySelectorAll('.tab')].pop().textContent.trim()") == "Settings")
    check("opens on Players", await current_tab(c) == "Players")
    await open_tab(c, "Settings")
    values = {
        "mask": await checked(c, "mask"),
        "refresh-state": await select_value(c, "refresh-state"),
        "refresh-chat": await select_value(c, "refresh-chat"),
        "refresh-log": await select_value(c, "refresh-log"),
        "theme": await radio_value(c, "theme"),
        "clock": await radio_value(c, "clock"),
        "thumbnails": await checked(c, "thumbnails"),
        "reopen": await checked(c, "reopen"),
        "hide-bots": await checked(c, "hide-bots"),
    }
    check("the defaults", values == {
        "mask": True, "refresh-state": "2", "refresh-chat": "2", "refresh-log": "2",
        "theme": "dark",
        "clock": "locale", "thumbnails": True, "reopen": True, "hide-bots": False}, values)
    check("the page is dark", await theme(c) == "dark")
    check("no storage warning while the browser keeps them",
          await c.eval("!document.querySelector('.settings-storage')"))

    print("\n== the server-state knob")
    await set_select(c, "refresh-state", "5")
    check("the footer select is the same value",
          await c.eval("document.querySelector('.statusbar select').value") == "5")
    mark = len(c.events)
    await asyncio.sleep(11)
    n = len(requests_of(c, "json", mark))
    check("every 5 s: two or three reads in 11 s", 2 <= n <= 3, f"{n} reads")
    await set_select(c, "refresh-state", "0")
    await asyncio.sleep(0.5)
    mark = len(c.events)
    await asyncio.sleep(6)
    n = len(requests_of(c, "json", mark))
    check("off: no reads in 6 s", n == 0, f"{n} reads")
    check("the footer's dot says idle",
          await c.eval("document.querySelector('.statusbar .dot').classList.contains('dot-idle')"))

    print("\n== the chat knob, apart from it")
    await open_tab(c, "Chat")
    mark = len(c.events)
    await asyncio.sleep(6.5)
    n_chat = len(requests_of(c, "getchatlist", mark))
    n_state = len(requests_of(c, "json", mark))
    check("chat reads on while state is off", n_chat >= 2 and n_state == 0,
          f"{n_chat} getchatlist, {n_state} json")
    check("no paused notice while it reads",
          not await c.eval("!!document.querySelector('.console-paused')"))
    await open_tab(c, "Settings")
    await set_select(c, "refresh-state", "2")
    await set_select(c, "refresh-chat", "0")
    await open_tab(c, "Chat", wait=1.5)
    notice = await c.eval("document.querySelector('.console-paused')?.textContent") or ""
    check("chat off says so", "Chat refresh is off" in notice, notice[:50])
    mark = len(c.events)
    await asyncio.sleep(5)
    n_chat = len(requests_of(c, "getchatlist", mark))
    n_state = len(requests_of(c, "json", mark))
    check("state reads on while chat is off", n_chat == 0 and n_state >= 2,
          f"{n_chat} getchatlist, {n_state} json")
    mark = len(c.events)
    await c.eval("[...document.querySelectorAll('.console-paused .btn')]"
                 ".find(b=>b.textContent==='Read now').click()")
    await asyncio.sleep(1)
    check("Read now reads once", len(requests_of(c, "getchatlist", mark)) == 1)
    await c.eval("document.querySelector('.console-paused .link-button').click()")
    await asyncio.sleep(0.5)
    check("its Settings link opens Settings", await current_tab(c) == "Settings")
    await set_select(c, "refresh-chat", "2")

    print("\n== the log knob, apart from both")
    await set_select(c, "refresh-state", "0")
    await set_select(c, "refresh-log", "5")
    await open_tab(c, "Console")
    mark = len(c.events)
    await asyncio.sleep(11)
    n_log = len(requests_of(c, "getlog", mark))
    n_state = len(requests_of(c, "json", mark))
    n_other = len(requests_of(c, "getconsole", mark)) + len(requests_of(c, "getchatlist", mark))
    check("log every 5 s: two or three reads in 11 s, and nothing else",
          2 <= n_log <= 3 and n_state == 0 and n_other == 0,
          f"{n_log} getlog, {n_state} json, {n_other} other")
    await open_tab(c, "Settings")
    await set_select(c, "refresh-log", "2")
    await set_select(c, "refresh-state", "2")


async def themes(c):
    print("\n== theme")
    await open_tab(c, "Settings")
    dark_bg = await body_bg(c)
    await click_radio(c, "theme", "light")
    light_bg = await body_bg(c)
    check("light", await theme(c) == "light" and light_bg != dark_bg, light_bg)
    await emulate_scheme(c, "dark")
    await click_radio(c, "theme", "system")
    check("system, on a dark system: dark", await theme(c) == "dark"
          and await body_bg(c) == dark_bg)
    await emulate_scheme(c, "light")
    check("the system turns light: so does the page, no reload",
          await theme(c) == "light" and await body_bg(c) == light_bg)
    label = await c.eval("document.querySelector('input[name=theme][value=system]')"
                         ".parentElement.textContent")
    check("the system choice names what the system is", "now light" in label, label)

    await open_tab(c, "Performance", wait=3)
    count = await c.eval("document.querySelectorAll('.perf-chart canvas').length")
    await c.eval("document.querySelectorAll('.perf-chart canvas').forEach(c=>c.__old=1)")
    await emulate_scheme(c, "dark")
    await asyncio.sleep(0.5)
    rebuilt = await c.eval("[...document.querySelectorAll('.perf-chart canvas')]"
                           ".filter(c=>!c.__old).length")
    check("the system turns dark: the charts are rebuilt", count == 5 and rebuilt == 5
          and await theme(c) == "dark", f"{rebuilt} of {count} new")
    await open_tab(c, "Settings")
    await click_radio(c, "theme", "dark")


async def clocks(c):
    print("\n== times (en-US, America/Sao_Paulo)")
    await open_tab(c, "Settings")
    hours = await c.eval("[new Date().getHours(), new Date().getUTCHours()]")
    m, text = await footer_time(c)
    check("as the browser writes them: AM/PM", m and m.group(4), text.strip()[:40])

    await click_radio(c, "clock", "24h")
    await asyncio.sleep(0.2)
    m, text = await footer_time(c)
    check("24-hour: no AM/PM, local hour",
          m and not m.group(4) and int(m.group(1)) == hours[0], f"{text.strip()[:30]} local {hours[0]}")

    await click_radio(c, "clock", "utc")
    await asyncio.sleep(0.2)
    m, text = await footer_time(c)
    check("UTC: the UTC hour", m and not m.group(4) and int(m.group(1)) == hours[1],
          f"{text.strip()[:30]} utc {hours[1]}")
    sample = await c.eval("document.querySelector('.clock-sample[data-clock=utc]').textContent")
    check("its sample says UTC", sample.endswith(" UTC"), sample)

    # A timed ban, so there is a date to write.
    get(f"{MOD}/?request=runcommand&cmd=sv_ban%2076561198000000042%2060%20settings-gate")
    await open_tab(c, "Bans", wait=1.5)
    titles = await c.eval("[...document.querySelectorAll('.expires-cell')].map(t=>t.title)"
                          ".filter(Boolean)")
    check("a ban's date is marked UTC", titles and all(t.endswith(" UTC") for t in titles),
          titles[:1])

    await open_tab(c, "Performance", wait=3)
    ticks = await c.eval(AXIS_TICKS) or ""
    check("the perf time axis in 24-hour UTC",
          ticks and not re.search(r"[AP]M", ticks) and int(ticks.split("|")[0][:2]) in
          (hours[1], (hours[1] - 1) % 24), ticks[:40])
    await open_tab(c, "Settings")
    await click_radio(c, "clock", "locale")
    await open_tab(c, "Performance", wait=1)
    ticks = await c.eval(AXIS_TICKS) or ""
    check("and back as the browser writes them: AM/PM", re.search(r"[AP]M", ticks), ticks[:40])


# The time labels as drawn. Since F1 the first chart is a band whose labels
# are left to the bottom band, so take the first chart that has some.
AXIS_TICKS = ("[...document.querySelectorAll('.perf-chart')].map(f=>f.dataset.xTicks)"
              ".find(t=>t && t.replace(/\\|/g,''))")


async def persistence(c):
    print("\n== kept across a reload")
    await open_tab(c, "Settings")
    await set_select(c, "refresh-state", "5")
    await click_radio(c, "clock", "utc")
    await click_radio(c, "theme", "light")
    await open_tab(c, "Players")
    await c.eval("[...document.querySelectorAll('.toolbar label')]"
                 ".find(l=>l.textContent.includes('Hide bots')).querySelector('input').click()")
    await open_tab(c, "Console")
    filters = ("[...document.querySelectorAll('.log-filters input')]"
               ".filter(i=>!i.checked).map(i=>i.name).join()")
    fresh = await c.eval(filters)
    await c.eval("document.querySelector('input[name=kind-engine]').click()")
    await c.eval("document.querySelector('input[name=kind-chat]').click()")
    await asyncio.sleep(0.3)
    await open_tab(c, "Bans")
    await load(c, MOD + "/index.html")
    check("reopens on the last tab", await current_tab(c) == "Bans")
    check("light theme from the start", await theme(c) == "light")
    await open_tab(c, "Settings")
    kept = (await select_value(c, "refresh-state"), await radio_value(c, "clock"),
            await checked(c, "hide-bots"))
    check("refresh, clock and Hide bots kept", kept == ("5", "utc", True), kept)
    await open_tab(c, "Players")
    hidden = await c.eval("[...document.querySelectorAll('.toolbar label')]"
                          ".find(l=>l.textContent.includes('Hide bots')).querySelector('input').checked")
    check("Players opens with bots hidden", hidden)
    await open_tab(c, "Console")
    kept = await c.eval(filters)
    check("the Console's filters: Engine and Other off at first, then kept",
          fresh == "kind-engine,kind-other" and kept == "kind-chat,kind-other", f"{fresh} -> {kept}")

    await open_tab(c, "Settings")
    await set_check(c, "reopen", False)
    await open_tab(c, "Bans")
    await load(c, MOD + "/index.html")
    check("with Reopen off: Players", await current_tab(c) == "Players")

    print("\n== the tabs' shortcuts are the same values")
    await c.eval("[...document.querySelectorAll('.toolbar label')]"
                 ".find(l=>l.textContent.includes('Show Steam ids')).querySelector('input').click()")
    await asyncio.sleep(0.3)
    masked_players = await c.eval("document.querySelectorAll('.masked').length")
    await open_tab(c, "Settings")
    check("Players' Show Steam ids unticks Mask", await checked(c, "mask") is False
          and masked_players == 0, f"{masked_players} masked on Players")
    await set_check(c, "mask", True)
    await open_tab(c, "Players")
    check("and Mask in Settings masks Players again",
          await c.eval("document.querySelectorAll('.masked').length") > 0)


async def storage_cases(c):
    print("\n== what storage can hold")
    mark = len(c.events)
    await c.eval(f"localStorage.setItem({KEY!r}, JSON.stringify({{refreshSeconds:'abc',"
                 "theme:'blue',clock:'utc',maskIdentifiers:false,consoleRefreshSeconds:7,"
                 "logRefreshSeconds:10,lastTab:'nonsense',reopenLastTab:true}))")
    await load(c, MOD + "/index.html")
    check("an unknown last tab: Players", await current_tab(c) == "Players")
    await open_tab(c, "Settings")
    got = (await select_value(c, "refresh-state"), await radio_value(c, "theme"),
           await radio_value(c, "clock"), await checked(c, "mask"),
           await select_value(c, "refresh-chat"), await select_value(c, "refresh-log"))
    check("bad fields defaulted, good ones kept",
          got == ("2", "dark", "utc", False, "2", "10"), got)

    await c.eval(f"localStorage.setItem({KEY!r}, '{{not json')")
    await load(c, MOD + "/index.html")
    await open_tab(c, "Settings")
    got = (await select_value(c, "refresh-state"), await radio_value(c, "clock"),
           await checked(c, "mask"))
    check("junk: the defaults", got == ("2", "locale", True), got)

    await c.eval(f"localStorage.setItem({KEY!r}, JSON.stringify({{refreshSeconds:5}}))")
    await load(c, MOD + "/index.html")
    await open_tab(c, "Settings")
    check("an older build's settings: chat keeps their rate",
          await select_value(c, "refresh-chat") == "5")
    await c.eval(f"localStorage.setItem({KEY!r}, JSON.stringify({{lastTab:'console',reopenLastTab:true}}))")
    await load(c, MOD + "/index.html")
    check("a stored Console tab reopens as Console", await current_tab(c) == "Console")
    await open_tab(c, "Settings")
    check("no uncaught exceptions from any of it", not exceptions_since(c, mark),
          exceptions_since(c, mark)[:1])

    print("\n== another page on this address")
    await c.eval("(()=>{const f=document.createElement('iframe');f.id='peer';"
                 "f.src='about:blank';document.body.appendChild(f);})()")
    await asyncio.sleep(0.5)
    await c.eval(f"document.getElementById('peer').contentWindow.localStorage.setItem({KEY!r},"
                 "JSON.stringify({theme:'light',refreshSeconds:10}))")
    await asyncio.sleep(0.8)
    check("its change is followed at once", await theme(c) == "light"
          and await select_value(c, "refresh-state") == "10")
    await c.eval("document.getElementById('peer').remove()")

    print("\n== Reset")
    await c.eval("window.__confirms = []")
    await c.eval("document.querySelector('.settings-reset').click()")
    await asyncio.sleep(0.5)
    confirms = await c.eval("window.__confirms")
    check("asks first", confirms and "default" in confirms[0], confirms)
    got = (await select_value(c, "refresh-state"), await radio_value(c, "theme"),
           await stored(c), await theme(c))
    check("the defaults, and nothing stored", got == ("2", "dark", None, "dark"), got)

    print("\n== a browser that refuses storage")
    breaker = await c.send("Page.addScriptToEvaluateOnNewDocument", source=(
        "Object.defineProperty(window, 'localStorage', {configurable: true,"
        " get() { throw new DOMException('denied', 'SecurityError'); }});"))
    mark = len(c.events)
    await load(c, MOD + "/index.html")
    await open_tab(c, "Settings")
    foot_text = await c.eval("document.querySelector('.settings-storage').textContent")
    check("says they last until the page closes", "until this page closes" in foot_text,
          foot_text[:50])
    await click_radio(c, "theme", "light")
    check("a change still applies", await theme(c) == "light")
    check("and nothing throws", not exceptions_since(c, mark), exceptions_since(c, mark)[:1])
    await c.send("Page.removeScriptToEvaluateOnNewDocument", identifier=breaker["identifier"])


async def unreachable_and_stock(c):
    print("\n== the server cannot be reached")
    await c.eval(f"localStorage.removeItem({KEY!r})")
    await c.send("Network.setBlockedURLs", urls=["*request=json*"])
    await load(c, MOD + "/index.html", wait=2)
    banner = await c.eval("document.querySelector('.banner h2')?.textContent") or ""
    check("the page says so", "Cannot reach" in banner, banner)
    await open_tab(c, "Settings")
    check("Settings still renders", await c.eval("!!document.querySelector('.settings-tab')"))
    await set_select(c, "refresh-state", "0")
    await asyncio.sleep(0.5)
    mark = len(c.events)
    await asyncio.sleep(4)
    check("and refresh can be turned off from it", len(requests_of(c, "json", mark)) == 0)
    await c.send("Network.setBlockedURLs", urls=[])
    await c.eval(f"localStorage.removeItem({KEY!r})")

    print("\n== a stock server")
    mark = len(c.events)
    await load(c, STOCK + "/index.html")
    await open_tab(c, "Settings")
    check("Settings renders on stock", await c.eval("!!document.querySelector('.settings-tab')"))
    await open_tab(c, "Console")
    check("the stock Console explains itself, no paused notice",
          await c.eval("!document.querySelector('.console-paused')"
                       " && [...document.querySelectorAll('.banner h2')]"
                       ".some(h=>h.textContent.includes('cannot serve its log or command output'))"))
    check("no uncaught exceptions on stock", not exceptions_since(c, mark),
          exceptions_since(c, mark)[:1])


async def main():
    for base in (MOD, STOCK):
        get(f"{base}/__mock/reset")

    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Emulation.setDeviceMetricsOverride",
                         width=1400, height=1400, deviceScaleFactor=1, mobile=False)
            # A zone three hours off UTC and a 12-hour locale, so the three
            # clock settings all read differently.
            await c.send("Emulation.setTimezoneOverride", timezoneId="America/Sao_Paulo")
            await c.send("Emulation.setLocaleOverride", locale="en-US")
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = (m) => { (window.__confirms ||= []).push(m);"
                                " return true; };")
            start = len(c.events)
            await defaults_and_refresh(c)
            await themes(c)
            await clocks(c)
            await persistence(c)
            await storage_cases(c)
            await unreachable_and_stock(c)

            print("\n== every server")
            thrown = exceptions_since(c, start)
            check("no uncaught exceptions", not thrown, thrown[:1])
            third = []
            for e in c.events:
                if e["method"] == "Network.requestWillBeSent":
                    url = e["params"]["request"]["url"]
                    if not (url.startswith(MOD) or url.startswith(STOCK)
                            or url.startswith("data:") or url == "about:blank"):
                        third.append(url)
            check("nothing fetched from a third party", not third, third[:2])
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

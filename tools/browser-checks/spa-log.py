#!/usr/bin/env python3
"""Gate: the Console tab's log, driven in a real browser against the mock.

The log is read by byte offset, and the checks are about exactly that as much
as about what is shown:

  * nothing is read before the tab opens, or after it closes; a stock server
    is never asked, and says why
  * the first read is the file's last 64 KB, starting at a line; Load earlier
    reaches the start of the file with every line exactly once
  * a line written elsewhere arrives by the next poll; an idle poll carries no
    lines; a line still being written is not shown until it is complete
  * a burst bigger than one reply is caught up with no gap and no duplicate,
    and a tab that was away while megabytes were written skips ahead and says so
  * a cut file and a new file (a restart) each say so and start over; a map
    change does neither
  * filters, their counts and search, Engine and Other off until ticked and
    the choice kept in the browser; the view follows the end only when the
    reader is there
  * chat in its speaker's team colour, with a chat mark, kept when the
    speaker switches teams; none for a speaker no longer on the server
  * Save writes every line read, of every kind, to a file named for the log
  * lines are verbatim: IPs and Steam ids unmasked (by design),
    and markup shown as text
  * a server whose log cannot be reached says why, and keeps the command line;
    a stale copy (one the server is not writing) is refused, not shown
  * with log refresh off, nothing is read until Read now
  * nothing is fetched from anywhere but the server

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8094 --web web --mod --perf-window 2
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8100 --web web --mod --log=off
"""
import asyncio, json, os, sys, urllib.request
from urllib.parse import parse_qs, quote, urlparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
OFF = os.environ.get("OFF_URL", "http://127.0.0.1:8100")
PORT = 9234

results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<60} {detail}")
    return ok


def get(url):
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.read().decode()


def mock_log(base, **params):
    return json.loads(get(f"{base}/__mock/log?" + "&".join(
        f"{k}={quote(str(v))}" for k, v in params.items())))


def file_lines(base):
    """Every complete line of the mock's log, read the way the panel reads it:
    the tail, then pages back to the start."""
    page = json.loads(get(f"{base}/?request=getlog"))
    lines = list(page["lines"])
    fid, first = page["file_id"], page["from"]
    while first > 0:
        back = json.loads(get(f"{base}/?request=getlog&before={first}&file={quote(fid)}"))
        lines = back["lines"] + lines
        first = back["from"]
    return lines


def requests_of(c, kind, since=0):
    out = []
    for e in c.events[since:]:
        if e["method"] != "Network.requestWillBeSent":
            continue
        url = e["params"]["request"]["url"]
        q = parse_qs(urlparse(url).query)
        if q.get("request", [None])[0] == kind:
            out.append((e["params"]["requestId"], url, q))
    return out


async def bodies(c, kind, since=0):
    """The JSON bodies of the page's request=<kind> replies after `since`."""
    out = []
    for rid, _, _ in requests_of(c, kind, since):
        try:
            r = await c.send("Network.getResponseBody", requestId=rid)
            out.append(json.loads(r["body"]))
        except Exception:
            pass
    return out


async def open_tab(c, name):
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={name!r}).click()")
    await asyncio.sleep(1.5)


async def dom_lines(c):
    return await c.eval("[...document.querySelectorAll('.log .log-line')]"
                        ".map(e=>({off:+e.dataset.off,text:e.textContent,"
                        "kind:e.dataset.kind}))")


async def text_of(c, selector):
    return str(await c.eval(f"document.querySelector({selector!r})?.textContent||''"))


async def wait_for(c, expr, seconds=8.0):
    for _ in range(int(seconds / 0.25)):
        if await c.eval(expr):
            return True
        await asyncio.sleep(0.25)
    return False


def has_line(text):
    return ("[...document.querySelectorAll('.log .log-line')]"
            f".some(e=>e.textContent==={text!r})")


async def main():
    get(f"{MOD}/__mock/reset")
    get(f"{OFF}/__mock/reset")

    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                "try { localStorage.removeItem('improved-webadmin.settings'); } catch {}")

            print("\n== nothing is read before the tab opens")
            await c.send("Page.navigate", url=MOD + "/index.html")
            await asyncio.sleep(3.5)
            check("no getlog on Players", len(requests_of(c, "getlog")) == 0)

            print("\n== the first read is the tail, starting at a line")
            mark = len(c.events)
            await open_tab(c, "Console")
            await wait_for(c, "document.querySelectorAll('.log .log-line').length>0")
            first = requests_of(c, "getlog", mark)
            check("the first read asks for no cursor",
                  first and "since" not in first[0][2] and "before" not in first[0][2],
                  first[0][1][-40:] if first else "no request")
            check("Engine and Other start unticked, the rest ticked",
                  await c.eval("[...document.querySelectorAll('.log-filters input')]"
                               ".map(i=>i.name+'='+i.checked).join(' ')")
                  == "kind-chat=true kind-connection=true kind-admin=true kind-error=true "
                     "kind-engine=false kind-other=false")
            shown = await dom_lines(c)
            check("and no engine or other line is shown",
                  shown and not {l["kind"] for l in shown} & {"engine", "other"},
                  str(sorted({l["kind"] for l in shown})))
            check("though they are counted",
                  "Engine " in await text_of(c, ".log-filters .kind-engine")
                  and not (await text_of(c, ".log-filters .kind-engine")).endswith(" 0"),
                  await text_of(c, ".log-filters .kind-engine"))
            for kind in ("engine", "other"):
                await c.eval(f"document.querySelector('input[name=kind-{kind}]').click()")
            await asyncio.sleep(0.5)
            stored = json.loads(await c.eval(
                "localStorage.getItem('improved-webadmin.settings')") or "{}")
            check("ticking them is kept in the browser",
                  stored.get("logHiddenKinds") == [], str(stored.get("logHiddenKinds")))
            tail = json.loads(get(f"{MOD}/?request=getlog"))
            shown = await dom_lines(c)
            check("the page shows the server's tail, line for line",
                  [l["off"] for l in shown[:len(tail["lines"])]] == [l["off"] for l in tail["lines"]]
                  and tail["from"] > 0, f"{len(shown)} lines from byte {shown[0]['off'] if shown else '-'}")
            check("the file and its size are named",
                  "log-Server.txt, started " in await text_of(c, ".log-file"),
                  await text_of(c, ".log-file"))
            check("Load earlier is offered", await c.eval("!!document.querySelector('.log-earlier')"))

            print("\n== verbatim: identifiers unmasked, by decision")
            texts = "\n".join(l["text"] for l in shown)
            check("IPs as written", "Client connecting (0.0.0.0:27005)" in texts)
            check("Steam ids as written",
                  "steam user 76561197970265728" in texts and "Steam ID: 10000000" in texts)
            check("nothing in the log is masked",
                  await c.eval("document.querySelectorAll('.log .masked').length") == 0)
            check("a name with an accent survives (offsets are bytes)",
                  "Jösé Onosaurus" in texts)

            print("\n== Load earlier reaches the start, every line once")
            for _ in range(10):
                if await c.eval("!!document.querySelector('.log-edge')?.textContent.includes('Start of the file')"):
                    break
                await c.eval("document.querySelector('.log-earlier')?.click()")
                await asyncio.sleep(1.2)
            check("the start of the file is reached",
                  "Start of the file" in await text_of(c, ".log-edge"))
            shown = await dom_lines(c)
            offs = [l["off"] for l in shown]
            want = file_lines(MOD)
            want = [l for l in want if l["off"] <= offs[-1]] if offs else want
            check("no line twice", len(offs) == len(set(offs)))
            check("every line of the file, in order",
                  [(l["off"], l["text"]) for l in shown] == [(l["off"], l["text"]) for l in want],
                  f"{len(shown)} shown, {len(want)} in the file")
            check("the first line is the header's", shown and shown[0]["text"].startswith("Date: "))

            print("\n== what is written arrives; an idle poll carries nothing")
            get(f"{MOD}/?request=runcommand&cmd=sv_say+log_marker_one")
            check("an sv_say from another client arrives",
                  await wait_for(c, has_line("Chat All - Admin: log_marker_one")))
            polls = requests_of(c, "getlog")
            last = polls[-1][2] if polls else {}
            check("polls carry a byte cursor and the file id",
                  "since" in last and "file" in last, str({k: v[0] for k, v in last.items()})[:70])
            mark = len(c.events)
            await asyncio.sleep(5)
            idle = await bodies(c, "getlog", mark)
            noisy = [b for b in idle if any("Script tracing" not in l["text"] for l in b.get("lines", []))]
            check("idle polls carry no lines", len(idle) >= 2 and not noisy,
                  f"{len(idle)} polls, {len(noisy)} with lines")

            print("\n== a line still being written is held until it is complete")
            mock_log(MOD, partial="partial_marker_")
            await asyncio.sleep(4.5)
            check("not shown while incomplete",
                  not await c.eval("[...document.querySelectorAll('.log .log-line')]"
                                   ".some(e=>e.textContent.includes('partial_marker_'))"))
            mock_log(MOD, append="done")
            check("shown whole once it is",
                  await wait_for(c, has_line("partial_marker_done")))

            print("\n== a burst bigger than one reply: no gap, no duplicate")
            size = mock_log(MOD, burst=700000)["size"]
            await wait_for(c, "[...document.querySelectorAll('.log .log-line')].slice(-1)[0]"
                              "?.textContent.startsWith('burst ')", 12)
            await asyncio.sleep(2.5)
            shown = await dom_lines(c)
            burst = [l for l in shown if l["text"].startswith("burst ")]
            nums = [int(l["text"].split()[1]) for l in burst]
            check("every burst line once, in order",
                  nums == list(range(1, len(nums) + 1)) and len(nums) > 6000,
                  f"{len(nums)} lines, {size} bytes in the file")
            big = [b for b in await bodies(c, "getlog") if b.get("lines")]
            check("no reply over 64 KB", all(b["to"] - b["from"] <= 65536 for b in big))
            check("and the reader, at the end, is still at the end",
                  await c.eval("(e=>e.scrollHeight-e.scrollTop-e.clientHeight<40)"
                               "(document.querySelector('.log'))"))

            print("\n== filters, counts and search")
            counts = str(await c.eval("[...document.querySelectorAll('.log-filters label')]"
                                      ".map(l=>l.textContent).join(' | ')"))
            check("each kind is counted", "Chat" in counts and "Errors and warnings" in counts, counts[:80])
            shown = await dom_lines(c)
            kinds = {l["kind"] for l in shown}
            check("chat, connections, admin, errors and engine lines all recognised",
                  {"chat", "connection", "admin", "error", "engine"} <= kinds, str(sorted(kinds)))
            misread = [l["text"][:40] for l in shown if l["kind"] != "engine" and (
                l["text"].startswith("TICKSTAT|") or " snapshot rate " in l["text"]
                or l["text"].startswith("perfmon: "))]
            engine_lines = [l for l in shown if l["text"].startswith("TICKSTAT|")]
            check("tickstat, rate-step and perfmon lines are engine lines",
                  engine_lines and not misread, misread[:2])
            team = [l["kind"] for l in shown if "Chat Team - Skulkovich" in l["text"]]
            check("Shine's team chat, with no team number, is chat",
                  team and set(team) == {"chat"}, f"{len(team)} lines: {sorted(set(team))}")

            print("\n== colours (L1)")
            colours = json.loads(await c.eval("""JSON.stringify((()=>{
                const col = (sel) => { const e = document.querySelector(sel);
                                       return e ? getComputedStyle(e).color : null; };
                const msg = (tone) => col(`.log .logtone-${tone} .log-msg`);
                return {error: msg('error'), warning: msg('warning'),
                        admin: msg('admin'), connection: msg('connection'), other: msg('other'),
                        text: getComputedStyle(document.body).color,
                        time: col('.log .log-time'), thread: col('.log .log-thread'),
                        msgAfterTime: col('.log .log-time ~ .log-msg')};
            })())"""))
            toned = [colours[k] for k in ("error", "warning", "admin", "connection")]
            check("errors, warnings, admin and connections each have a colour",
                  None not in toned and len(set(toned)) == 4 and colours["text"] not in toned,
                  str(toned))
            check("other lines keep the text colour", colours["other"] == colours["text"],
                  str(colours["other"]))
            check("times and the thread name have their own",
                  colours["time"] and colours["thread"]
                  and len({colours["time"], colours["thread"], colours["text"]}) == 3,
                  f"{colours['time']} {colours['thread']}")
            warn_line = [l for l in shown if "Warning: sound event" in l["text"]]
            tone = await c.eval("document.querySelector('.log .logtone-warning')?.textContent||''")
            check("a warning is told from an error", warn_line and "Warning: sound event" in str(tone),
                  str(tone)[:40])
            await c.eval("document.querySelector('input[name=kind-other]').click()")
            await asyncio.sleep(0.5)
            shown = await dom_lines(c)
            check("unticking a kind hides it",
                  shown and all(l["kind"] != "other" for l in shown))
            check("and the count says how many are shown",
                  " of " in await text_of(c, ".log-count"), await text_of(c, ".log-count"))
            await c.eval("document.querySelector('input[name=kind-other]').click()")
            await c.eval("(()=>{const i=document.querySelector('.log-search');i.value='medpack';"
                         "i.dispatchEvent(new Event('input',{bubbles:true}));})()")
            await asyncio.sleep(0.5)
            shown = await dom_lines(c)
            check("search keeps only matching lines",
                  shown and all("medpack" in l["text"] for l in shown), f"{len(shown)} lines")
            await c.eval("(()=>{const i=document.querySelector('.log-search');i.value='';"
                         "i.dispatchEvent(new Event('input',{bubbles:true}));})()")
            await asyncio.sleep(0.5)

            print("\n== chat in its speaker's team colour, with a mark")
            get(f"{MOD}/__mock/chat?text=team_marker_marine&player=Skulkovich&team=1")
            mock_log(MOD, append="Chat Team - [BOT] Fadeaway 20: team_marker_alien")
            mock_log(MOD, append="Chat All - Long Gone: team_marker_gone")
            await wait_for(c, has_line("Chat All - Long Gone: team_marker_gone"))
            chat = json.loads(await c.eval("""JSON.stringify((()=>{
                const line = (t) => [...document.querySelectorAll('.log .log-line')]
                                      .find(e=>e.textContent.endsWith(t));
                const css = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
                const probe = document.createElement('span'); document.body.appendChild(probe);
                const rgb = (v) => { probe.style.color = v; return getComputedStyle(probe).color; };
                const of = (t) => { const e = line(t); return e && {
                    team: e.dataset.team ?? null,
                    colour: getComputedStyle(e.querySelector('.log-msg')).color,
                    mark: e.querySelector('.chat-mark')?.getAttribute('aria-label') ?? null}; };
                const out = {marine: of('team_marker_marine'), alien: of('team_marker_alien'),
                             gone: of('team_marker_gone'), numbered: of('need a medpack at the ♥ node'),
                             want: {marine: rgb(css('--log-marine')), alien: rgb(css('--log-alien'))},
                             text: getComputedStyle(document.body).color,
                             warningMark: !!document.querySelector('.log .logtone-warning .chat-mark'),
                             connectionMark: !!document.querySelector('.log .logtone-connection .chat-mark')};
                probe.remove(); return out;
            })())"""))
            m, a, g, n = chat["marine"], chat["alien"], chat["gone"], chat["numbered"]
            check("a marine's chat in the marine colour, looked up by name",
                  m and m["team"] == "1" and m["colour"] == chat["want"]["marine"], str(m))
            check("an alien's team chat in the alien colour",
                  a and a["team"] == "2" and a["colour"] == chat["want"]["alien"], str(a))
            check("Chat Team 1 read from the line itself",
                  n and n["team"] == "1" and n["colour"] == chat["want"]["marine"], str(n))
            check("a speaker no longer on the server: no team, the text colour",
                  g and g["team"] is None and g["colour"] == chat["text"], str(g))
            check("every chat line carries the chat mark, in words",
                  all(x and x["mark"] for x in (m, a, g, n))
                  and m["mark"] == "Chat, Marines" and a["mark"] == "Team chat, Aliens",
                  f"{m and m['mark']} / {a and a['mark']}")
            check("and no warning or connection line does",
                  not chat["warningMark"] and not chat["connectionMark"])
            check("the mark adds nothing to the line's text",
                  await c.eval(has_line("Chat All - Skulkovich: team_marker_marine")))
            get(f"{MOD}/?request=runcommand&cmd=sv_switchteam+10000000+2")
            await asyncio.sleep(2.5)   # the next state poll has the switch
            get(f"{MOD}/__mock/chat?text=team_marker_after&player=Skulkovich&team=2")
            await wait_for(c, has_line("Chat All - Skulkovich: team_marker_after"))
            teams = await c.eval("[...document.querySelectorAll('.log .log-line')]"
                                 ".filter(e=>e.textContent.includes('team_marker_'))"
                                 ".map(e=>e.textContent.split(': ')[1]+'='+(e.dataset.team??'-')).join(' ')")
            check("a team switch colours what follows, and not what came before",
                  "team_marker_marine=1" in teams and "team_marker_after=2" in teams, teams)
            get(f"{MOD}/?request=runcommand&cmd=sv_switchteam+10000000+1")

            print("\n== Save writes every line read")
            await c.eval("(()=>{const o=URL.createObjectURL.bind(URL);"
                         "URL.createObjectURL=(b)=>{window.__saved=b;return o(b)};"
                         "const a=HTMLAnchorElement.prototype.click;"
                         "HTMLAnchorElement.prototype.click=function(){window.__savedAs=this.download;"
                         "if(!this.download)a.call(this)}})()")
            await c.eval("document.querySelector('input[name=kind-engine]').click()")
            await asyncio.sleep(0.3)
            await c.eval("document.querySelector('.log-save').click()")
            await asyncio.sleep(0.3)
            saved = await c.eval("window.__saved?.text()", await_promise=True) or ""
            held = await c.eval("document.querySelector('.log-count').textContent")
            shown = await dom_lines(c)
            check("named for the log file",
                  str(await c.eval("window.__savedAs")).startswith("log-Server-")
                  and str(await c.eval("window.__savedAs")).endswith(".txt"),
                  str(await c.eval("window.__savedAs")))
            check("with every line read, hidden kinds too",
                  saved.count("\n") == int(str(held).split(" of ")[1].split()[0])
                  and "TICKSTAT|" in saved and "team_marker_gone" in saved,
                  f"{saved.count(chr(10))} lines saved; {held}")
            await c.eval("document.querySelector('input[name=kind-engine]').click()")

            print("\n== the view follows the end only when the reader is there")
            await c.eval("document.querySelector('.log').scrollTop=0")
            await c.eval("document.querySelector('.log').dispatchEvent(new Event('scroll'))")
            mock_log(MOD, append="follow_marker_a")
            await wait_for(c, has_line("follow_marker_a"))
            check("scrolled up: left where it was",
                  await c.eval("document.querySelector('.log').scrollTop") < 50)
            await c.eval("(e=>{e.scrollTop=e.scrollHeight;e.dispatchEvent(new Event('scroll'))})"
                         "(document.querySelector('.log'))")
            mock_log(MOD, append="follow_marker_b")
            await wait_for(c, has_line("follow_marker_b"))
            await asyncio.sleep(0.3)
            check("at the end: kept at the end",
                  await c.eval("(e=>e.scrollHeight-e.scrollTop-e.clientHeight<40)"
                               "(document.querySelector('.log'))"))

            print("\n== markup is text")
            mock_log(MOD, append="<script>window.__logxss=1</script><b>bold</b><img src=x onerror=window.__logxss=2>")
            await wait_for(c, "[...document.querySelectorAll('.log .log-line')]"
                              ".some(e=>e.textContent.startsWith('<script>'))")
            check("shown as written, nothing run",
                  await c.eval("window.__logxss===undefined")
                  and await c.eval("document.querySelectorAll('.log b, .log img, .log script').length") == 0)

            print("\n== a map change does not interrupt the log")
            get(f"{MOD}/?request=runcommand&cmd=sv_changemap+ns2_veil")
            check("the new map's loading lines arrive",
                  await wait_for(c, has_line("Finished loading 'maps/ns2_veil.level'")))
            check("with no reset", not await c.eval("!!document.querySelector('.log-reset')"))

            print("\n== a cut file and a new file each say so and start over")
            mock_log(MOD, truncate=1)
            check("cut: said so",
                  await wait_for(c, "document.querySelector('.log-reset h2')?.textContent==='The log got shorter'"))
            shown = await dom_lines(c)
            check("and only what the file now holds is shown",
                  len(shown) == 4 and shown[0]["text"].startswith("Date: "), f"{len(shown)} lines")
            await c.eval("document.querySelector('.log-reset .btn').click()")
            await asyncio.sleep(0.3)
            check("Dismiss clears it", not await c.eval("!!document.querySelector('.log-reset')"))
            await asyncio.sleep(1.2)   # the header's Time is to the second
            fid = mock_log(MOD, restart=2)["file_id"]
            check("restart: said so",
                  await wait_for(c, "document.querySelector('.log-reset h2')?.textContent"
                                    ".startsWith('A new log file')"))
            check("and the new file is named", fid in await text_of(c, ".log-file"),
                  await text_of(c, ".log-file"))

            print("\n== with log refresh off, nothing is read until asked")
            await open_tab(c, "Settings")
            await c.eval("(s=>{s.value='0';s.dispatchEvent(new Event('change',{bubbles:true}))})"
                         "(document.querySelector('select[name=refresh-log]'))")
            await open_tab(c, "Console")
            check("the tab says refresh is off",
                  "Log refresh is off" in await text_of(c, ".console-paused"))
            mark = len(c.events)
            mock_log(MOD, append="paused_marker")
            await asyncio.sleep(5)
            check("no getlog while it is off", len(requests_of(c, "getlog", mark)) == 0)
            await c.eval("document.querySelector('.console-paused .btn').click()")
            check("Read now reads", await wait_for(c, has_line("paused_marker"), 3))
            await open_tab(c, "Settings")
            await c.eval("(s=>{s.value='2';s.dispatchEvent(new Event('change',{bubbles:true}))})"
                         "(document.querySelector('select[name=refresh-log]'))")

            print("\n== closed, it reads nothing; away for megabytes, it skips ahead")
            await open_tab(c, "Players")
            mark = len(c.events)
            mock_log(MOD, burst=1600000)
            await asyncio.sleep(5)
            check("no getlog once the tab is closed", len(requests_of(c, "getlog", mark)) == 0)
            await open_tab(c, "Console")
            check("reopened far behind: skips ahead and says so",
                  await wait_for(c, "document.querySelector('.log-reset h2')?.textContent==='Skipped ahead'"))
            skip = await text_of(c, ".log-reset p")
            check("naming how much it skipped", "MB were written" in skip, skip[:60])

            print("\n== a log file the server is not writing")
            mock_log(MOD, stale=1)
            await c.send("Page.navigate", url=MOD + "/index.html")
            await asyncio.sleep(3.5)
            await open_tab(c, "Console")
            stale = await text_of(c, ".log-stale")
            check("is refused, and says why", "this server is not writing it" in stale, stale[:60])
            check("with no line shown", await c.eval("document.querySelectorAll('.log .log-line').length") == 0)
            mock_log(MOD, stale=0)
            await c.send("Page.navigate", url=MOD + "/index.html")
            await asyncio.sleep(3.5)
            await open_tab(c, "Console")
            await wait_for(c, "document.querySelectorAll('.log .log-line').length>0")
            # A fresh page: Other is hidden again, and the check line is Other.
            await c.eval("document.querySelector('input[name=kind-other]').click()")
            await asyncio.sleep(0.3)
            check("a live one shows the mod's check line at the end of the first read",
                  await c.eval("[...document.querySelectorAll('.log .log-line')]"
                               ".some(e=>e.textContent.startsWith('improved-webadmin: checking that'))"))

            print("\n== a server whose log cannot be reached")
            mark = len(c.events)
            await c.send("Page.navigate", url=OFF + "/index.html")
            await asyncio.sleep(3.5)
            await open_tab(c, "Console")
            banner = await text_of(c, ".log-unavailable")
            check("says why", "-logdir" in banner and "-config_path" in banner, banner[:60])
            check("and what the server said", "No such file or directory" in banner)
            check("and the command line still runs, below it",
                  await c.eval("!!document.querySelector('.log-tab .console-input input[name=command]')"))

            print("\n== a stock server")
            await c.send("Page.navigate", url=STOCK + "/index.html")
            await asyncio.sleep(3.5)
            mark = len(c.events)
            await open_tab(c, "Console")
            await asyncio.sleep(2)
            banners = str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                                       ".map(e=>e.textContent).join(' | ')"))
            check("explains itself", "cannot serve its log" in banners, banners[:70])
            check("and never asks", len(requests_of(c, "getlog", mark)) == 0)

            print("\n== nothing from anywhere but the server")
            foreign = [e["params"]["request"]["url"] for e in c.events
                       if e["method"] == "Network.requestWillBeSent"
                       and not any(e["params"]["request"]["url"].startswith(b)
                                   for b in (MOD, STOCK, OFF))]
            check("no third-party request", not foreign, str(foreign[:1]))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

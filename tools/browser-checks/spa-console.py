#!/usr/bin/env python3
"""The server's command line, driven in a real browser against the mock.

It was the Console tab until it was merged into the log
(Console/Log, 2026-10-07, named Console again 2026-10-08): the input sits
under the log, and what a command printed shows right under the input. It exists because console commands used
to return nothing. So the checks are about what it says, not just that it
renders:

  * a failing command shows the reason the stock API threw away
  * a command that ran and printed nothing says so -- not "succeeded"
  * an unknown command is reported as indistinguishable from a plain console
    command, because on the server it is
  * the arrow keys bring back earlier commands
  * a command's name is suggested as it is typed, Tab and a click complete
    it, its arguments and help show once it is typed, and Shine's commands
    are offered only where Shine is loaded
  * output from the legacy command path reaches the log, whoever sent it
  * the last map change's time, from the server, moved by a map change
  * against a stock server the tab explains itself and offers no input

Start a mock with the mod's behaviour first:

    (cd panel && npx vite build)
    node mock/server.js --port 8094 --web web --mod

and, for the stock half, a second one without --mod on 8095, and one with
--mod --shine on 8096.
"""
import asyncio, json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
SHINE = os.environ.get("SHINE_URL", "http://127.0.0.1:8096")
PORT = 9227

results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<54} {detail}")
    return ok


async def open_console(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await asyncio.sleep(3.5)
    await c.eval("[...document.querySelectorAll('.tab')]"
                 ".find(t=>t.textContent.trim()==='Console').click()")
    await asyncio.sleep(1.5)


async def run(c, command):
    await c.eval("(()=>{const i=document.querySelector('.console-input input');"
                 f"i.value={command!r};"
                 "i.dispatchEvent(new Event('input',{bubbles:true}));})()")
    await c.eval("document.querySelector('.console-input .btn').click()")
    await asyncio.sleep(2)


async def lines(c):
    """What the last command printed, under the input."""
    return str(await c.eval("document.querySelector('.command-output')?.textContent||''"))


async def log_lines(c):
    return str(await c.eval(
        "[...document.querySelectorAll('.log .log-line')].map(e=>e.textContent).join('\\n')"))


async def type_(c, text):
    await c.eval("(()=>{const i=document.querySelector('input[name=command]');i.focus();"
                 f"i.value={text!r};i.dispatchEvent(new Event('input',{{bubbles:true}}));}})()")
    await asyncio.sleep(0.2)


async def key(c, name):
    await c.eval("document.querySelector('input[name=command]').dispatchEvent("
                 f"new KeyboardEvent('keydown',{{key:{name!r},bubbles:true,cancelable:true}}))")
    await asyncio.sleep(0.2)


async def value(c):
    return await c.eval("document.querySelector('input[name=command]').value")


async def suggestions(c):
    return await c.eval("[...document.querySelectorAll('.command-suggestions .command-name')]"
                        ".map(e=>e.textContent)")


async def outcome(c):
    """The console's own status line. The activity strip is hidden on this tab,
    where it would only repeat the stream."""
    return str(await c.eval(
        "document.querySelector('.console-status')?.textContent||''"))


async def main():
    with urllib.request.urlopen(f"{MOD}/__mock/reset", timeout=5) as r:
        r.read()

    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('improved-webadmin.settings'); } catch {}")

            print("\n== against a server carrying the mod's Lua")
            await open_console(c, MOD)
            check("the tab has the log, and a command line under it",
                  await c.eval("!!document.querySelector('.log-tab .log')"
                               " && !!document.querySelector('.log-tab .console-input input[name=command]')"))
            check("one tab, named Console",
                  await c.eval("[...document.querySelectorAll('.tab')]"
                               ".filter(t=>/Console|Log/.test(t.textContent)).map(t=>t.textContent.trim())"
                               ".join()") == "Console")
            check("and no notes under the command line",
                  not await c.eval("!!document.querySelector('.console-note')"))
            check("no stock-server explanation here",
                  "cannot return command output" not in str(await c.eval(
                      "document.querySelector('.banner h2')?.textContent||''")))

            print("\n== a command that fails now says why")
            await run(c, "sv_kick NoSuchPlayer")
            text = await lines(c)
            check("the failure reason is shown", "No matching player" in text,
                  [l for l in text.splitlines() if "matching" in l][:1])

            print("\n== a command that prints nothing says exactly that")
            await run(c, "sv_kick 10000000")
            note = await outcome(c)
            check("reported as ran-and-printed-nothing",
                  "printed nothing" in note, note[:60])
            check("and never as success", "success" not in note.lower(), note[:60])

            print("\n== an unknown command is honest about the ambiguity")
            await run(c, "sv_nonsense")
            note = await outcome(c)
            check("named as not-an-admin-command",
                  "not an admin command" in note, note[:52])
            check("and says the server cannot tell the two apart",
                  "does not distinguish" in note, "")

            print("\n== history")
            await c.eval("(()=>{const i=document.querySelector('input[name=command]');i.focus();"
                         "i.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true}));})()")
            await asyncio.sleep(0.3)
            await c.eval("document.querySelector('input[name=command]')"
                         ".dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true}))")
            await asyncio.sleep(0.3)
            check("ArrowUp brings back earlier commands, newest first",
                  await c.eval("document.querySelector('input[name=command]').value") == "sv_kick 10000000")

            print("\n== suggestions")
            await type_(c, "sv_ki")
            names = await suggestions(c)
            check("a name is suggested as it is typed", names[:1] == ["sv_kick"], str(names))
            check("with its arguments and help",
                  "<player id>" in str(await c.eval(
                      "document.querySelector('.command-suggestions li')?.textContent||''")))
            await key(c, "Tab")
            check("Tab completes it", await value(c) == "sv_kick ", repr(await value(c)))
            hint = str(await c.eval("document.querySelector('.command-hint')?.textContent||''"))
            check("and its arguments and help stay in view while typing them",
                  "sv_kick <player id>" in hint and "Kicks the player" in hint, hint[:60])
            await type_(c, "sv_")
            await key(c, "ArrowDown"); await key(c, "ArrowDown")
            second = (await suggestions(c))[1]
            before = await outcome(c)
            await key(c, "Enter")
            await asyncio.sleep(1)
            check("arrows pick one, Enter takes it without running",
                  await value(c) == f"{second} " and await outcome(c) == before, repr(await value(c)))
            await type_(c, "tickst")
            await c.eval("document.querySelector('.command-suggestions li')"
                         ".dispatchEvent(new MouseEvent('mousedown',{bubbles:true}))")
            await asyncio.sleep(0.2)
            check("a click takes one too", await value(c) == "tickstat ", repr(await value(c)))
            await type_(c, "sv_")
            await key(c, "Escape")
            check("Escape closes the list", await suggestions(c) == [])
            await type_(c, "sh_")
            check("no Shine command without Shine", await suggestions(c) == [],
                  str(await suggestions(c))[:60])
            await type_(c, "status")
            check("a name is found by any part of it",
                  "sv_status" in await suggestions(c), str(await suggestions(c)))
            await type_(c, "sv_nonsense_typed ok")
            await key(c, "Enter")
            await asyncio.sleep(2)
            check("anything typed still runs", "sv_nonsense_typed" in await outcome(c),
                  (await outcome(c))[:50])
            await type_(c, "")

            print("\n== output nobody typed here still arrives")
            # The legacy path, i.e. what the 2012 panel sends.
            urllib.request.urlopen(
                f"{MOD}/?request=json&command=Send&rcon=sv_say+from_elsewhere",
                timeout=5).read()
            await asyncio.sleep(3)
            check("a command sent by another client reaches the log",
                  "from_elsewhere" in await log_lines(c))

            print("\n== the last map change, from the server (C1)")
            def map_loaded_at():
                with urllib.request.urlopen(f"{MOD}/?request=json", timeout=5) as r:
                    return json.loads(r.read())["map_loaded_at"]
            async def shown():
                return str(await c.eval("document.querySelector('.console-map')?.textContent||''"))
            def expected(at):
                return c.eval(f"new Date({at}*1000).toLocaleString([],{{year:'numeric',"
                              "month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'})")
            before = map_loaded_at()
            said = await shown()
            check("the tab shows when the map loaded, as the server says",
                  said.startswith("Last map change:") and str(await expected(before)) in said, said)
            check("and no notice about line numbers going backwards",
                  "went backwards" not in str(await c.eval("document.body.textContent")))
            urllib.request.urlopen(f"{MOD}/?request=runcommand&cmd=sv_changemap+ns2_veil",
                                   timeout=5).read()
            await asyncio.sleep(3)
            after = map_loaded_at()
            said = await shown()
            check("a map change moves it", after > before and str(await expected(after)) in said,
                  said)

            print("\n== a server running Shine")
            await open_console(c, SHINE)
            await type_(c, "sh_ki")
            check("Shine's commands are suggested, named as Shine's",
                  (await suggestions(c))[:1] == ["sh_kick"]
                  and "Shine" in str(await c.eval(
                      "document.querySelector('.command-suggestions .command-source').textContent")),
                  str(await suggestions(c)))
            await type_(c, "")

            print("\n== against a stock server")
            await open_console(c, STOCK)
            # Two banners are on the page here: the global one naming what
            # this server cannot do, and the tab's own. Read them all.
            banners = str(await c.eval(
                "[...document.querySelectorAll('.banner h2')]"
                ".map(e=>e.textContent).join(' | ')"))
            check("the tab explains itself instead of sitting empty",
                  "cannot serve its log or command output" in banners, banners[:70])
            check("and offers no command input it cannot honour",
                  not await c.eval("!!document.querySelector('.console-input')"))
            check("nor a map change time it cannot know",
                  not await c.eval("!!document.querySelector('.console-map')"))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

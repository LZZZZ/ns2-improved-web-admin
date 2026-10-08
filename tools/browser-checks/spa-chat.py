#!/usr/bin/env python3
"""Gate: the Chat tab, driven in a real browser against three mocks.

The 2012 panel showed the server's last 20 chat messages on its Players tab
and could talk to All, Marines or Aliens. The checks are about reading chat
without losing or repeating any of it, and about the tab saying plainly what
the server cannot keep:

  * --mod      reads with a cursor (`since`), so a poll carries only what is
               new; messages carry times; a player's message arrives within a
               poll, team chat is marked and Steam ids are masked; All and
               Marines go out as sv_say / sv_tsay 1 and are confirmed from
               the chat itself; nothing is shown twice; a flood larger than the ring
               is reported as dropped; a map change restarts the numbering
               and the tab says so
  * stock      reads the whole 20-entry list, without a cursor, and says that
               it is all a stock server keeps and that it has no times;
               a message sent is confirmed by reading the chat back, the
               one receipt a stock server gives
  * --shine    sv_say becomes Shine's sh_say, which prints only Shine's
               receipt: the tab still confirms it from the chat; a gagged
               player's chat never arrives
  * no buffer  a server answering `{ }` gets an explanation, not an empty box

and on all of them: no uncaught exceptions, nothing fetched from a third
party.

Start the mocks first:

    (cd panel && npx vite build)
    node mock/server.js --port 8095 --web web
    node mock/server.js --port 8094 --web web --mod
    node mock/server.js --port 8101 --web web --no-chat-buffer
    node mock/server.js --port 8096 --web web --mod --shine
"""
import asyncio, json, os, sys, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

STOCK = os.environ.get("STOCK_URL", "http://127.0.0.1:8095")
MOD = os.environ.get("MOD_URL", "http://127.0.0.1:8094")
NOCHAT = os.environ.get("NOCHAT_URL", "http://127.0.0.1:8101")
SHINE = os.environ.get("SHINE_URL", "http://127.0.0.1:8096")
PORT = 9235
TAB = "Chat"
LINES = "document.querySelectorAll('.chat-line')"
results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<58} {detail}")
    return ok


def control(base, path):
    with urllib.request.urlopen(f"{base}/__mock/{path}", timeout=5) as r:
        r.read()


def chat(base, **params):
    control(base, "chat?" + urllib.parse.urlencode(params))


def command(base, cmd):
    q = urllib.parse.urlencode({"request": "runcommand", "cmd": cmd})
    with urllib.request.urlopen(f"{base}/?{q}", timeout=5) as r:
        r.read()


async def type_into(c, selector, text):
    await c.eval("(()=>{const i=document.querySelector(%s);i.value=%s;"
                 "i.dispatchEvent(new Event('input',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(text)))


async def choose(c, selector, value):
    await c.eval("(()=>{const s=document.querySelector(%s);s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));})()"
                 % (json.dumps(selector), json.dumps(value)))


async def open_tab(c, base):
    await c.send("Page.navigate", url=base + "/index.html")
    await asyncio.sleep(3)
    await c.eval("[...document.querySelectorAll('.tab')]"
                 f".find(t=>t.textContent.trim()==={json.dumps(TAB)}).click()")
    await asyncio.sleep(1.5)


async def texts(c):
    return list(await c.eval(
        f"[...{LINES}].map(l=>l.querySelector('.console-text').textContent)") or [])


async def ids(c):
    return [int(i) for i in await c.eval(f"[...{LINES}].map(l=>l.dataset.id)") or []]


async def line_with(c, text):
    """The rendered line whose message is `text`, as a dict of its parts."""
    return await c.eval(
        f"(()=>{{const l=[...{LINES}].find(l=>l.querySelector('.console-text')"
        f".textContent==={json.dumps(text)});"
        "if(!l)return null;return {"
        "player:l.querySelector('.chat-player')?.textContent||'',"
        "team:!!l.querySelector('.tag'),"
        "time:!!l.querySelector('time'),"
        "id:l.querySelector('.chat-id')?.textContent||''};})()")


async def send(c, audience, text):
    await choose(c, ".chat-input select", audience)
    await type_into(c, ".chat-input input", text)
    await c.eval("document.querySelector('.chat-input button').click()")
    await asyncio.sleep(1.5)
    return str(await c.eval("document.querySelector('.console-status')?.textContent||''"))


def chat_requests(c, mark):
    return [e["params"]["request"]["url"] for e in c.events[mark:]
            if e["method"] == "Network.requestWillBeSent"
            and "request=getchatlist" in e["params"]["request"]["url"]]


async def mod(c):
    print(f"\n== --mod ({MOD})")
    control(MOD, "reset")
    mark = len(c.events)
    await open_tab(c, MOD)

    check("the tab is reachable", await c.eval("!!document.querySelector('.chat')"))
    status = str(await c.eval("document.querySelector('.chat-tab .toolbar').textContent"))
    check("the ring size is the server's", "keeps the last 200" in status, status[:60])
    check("no stock-server note", not await c.eval("!!document.querySelector('.chat-stock')"))
    got = await texts(c)
    check("what the server holds is shown", "Test message as a player" in got,
          f"{len(got)} messages")
    first = await line_with(c, "Test message as a player")
    check("each message has a time", first and first["time"], first)
    check("a player's Steam id is masked", first and first["id"].startswith("•"),
          first and first["id"])

    print("\n== a poll carries only what is new")
    chat(MOD, text="gl hf", player="Skulkovich", team=1, steamid=10000000)
    chat(MOD, text="rush hive", player="Skulkovich", team=1, steamid=10000000, teamOnly=1)
    await asyncio.sleep(3)
    got = await texts(c)
    check("a player's message arrives within a poll", "gl hf" in got)
    team = await line_with(c, "rush hive")
    check("team chat is marked", team and team["team"], team)
    urls = chat_requests(c, mark)
    check("every read asks with a cursor",
          urls and all("since=" in u for u in urls), f"{len(urls)} reads")
    check("and the cursor moves", len({u for u in urls}) > 1,
          sorted({u.split("since=")[-1] for u in urls})[:4])

    print("\n== talking to the server")
    note = await send(c, "all", "hello everyone")
    check("All goes out as sv_say", "sv_say hello everyone" in note, note[:60])
    check("and is confirmed from the chat itself",
          "is in the server's chat" in note, note[-50:])
    admin = await line_with(c, "hello everyone")
    check("the message appears, from Admin", admin and admin["player"] == "Admin", admin)
    note = await send(c, "1", "marines only")
    check("Marines goes out as sv_tsay 1", "sv_tsay 1 marines only" in note, note[:60])
    line = await line_with(c, "marines only")
    check("and is marked as team chat", line and line["team"], line)
    seen = await ids(c)
    check("nothing is shown twice", len(seen) == len(set(seen)), f"{len(seen)} lines")

    print("\n== a flood larger than the ring")
    chat(MOD, text="spam", player="Gorgeous", team=2, steamid=10000001, n=250)
    await asyncio.sleep(3)
    status = str(await c.eval("document.querySelector('.chat-tab .toolbar').textContent"))
    check("what fell out before it was read is reported",
          "dropped by the server" in status, status[:90])

    print("\n== a map change")
    command(MOD, "sv_changemap ns2_veil")
    await asyncio.sleep(1)
    chat(MOD, text="new map", player="Skulkovich", team=0, steamid=10000000)
    await asyncio.sleep(3)
    banner = str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                              ".map(h=>h.textContent).join('|')"))
    check("the restart is said, not hidden", "The chat restarted" in banner, banner[:60])
    check("and the new map's chat is shown", "new map" in await texts(c))


async def stock(c):
    print(f"\n== stock server ({STOCK})")
    control(STOCK, "reset")
    mark = len(c.events)
    await open_tab(c, STOCK)

    note = str(await c.eval("document.querySelector('.chat-stock')?.textContent||''"))
    check("says a stock server keeps only 20, without times",
          "last 20 messages" in note and "no" in note and "times" in note, note[:70])
    got = await texts(c)
    check("the server's messages are shown", "Test message as a player" in got,
          f"{len(got)} messages")
    first = await line_with(c, "Test message as a player")
    check("with no time it does not have", first and not first["time"], first)
    urls = chat_requests(c, mark)
    check("and read without a cursor", urls and not any("since=" in u for u in urls),
          f"{len(urls)} reads")
    note = await send(c, "2", "aliens only")
    check("a message sent is confirmed by reading the chat back",
          "sv_tsay 2 aliens only" in note and "is in the server's chat" in note,
          note[-60:])
    await asyncio.sleep(2.5)
    seen = await ids(c)
    check("re-reading the whole list shows nothing twice",
          len(seen) == len(set(seen)), f"{len(seen)} lines")


async def shine(c):
    print(f"\n== Shine with basecommands ({SHINE})")
    control(SHINE, "reset")
    await open_tab(c, SHINE)
    note = await send(c, "all", "shine says hi")
    check("sv_say is confirmed from the chat, though Shine prints only its receipt",
          "is in the server's chat" in note, note[-50:])
    command(SHINE, "sh_gag 10000000")
    chat(SHINE, text="you cannot hear me", player="Skulkovich", team=1, steamid=10000000)
    chat(SHINE, text="but me you can", player="Gorgeous", team=2, steamid=10000001)
    await asyncio.sleep(3)
    got = await texts(c)
    check("a gagged player's chat never arrives",
          "you cannot hear me" not in got and "but me you can" in got)


async def nochat(c):
    print(f"\n== a server with no chat buffer ({NOCHAT})")
    await open_tab(c, NOCHAT)
    banner = str(await c.eval("[...document.querySelectorAll('.banner h2')]"
                              ".map(h=>h.textContent).join('|')"))
    check("the tab explains itself", "keeps no chat" in banner, banner[:60])
    check("and offers nothing it cannot read",
          not await c.eval("!!document.querySelector('.chat')"))


async def main():
    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('webadmin-spa.settings'); } catch {}")
            await mod(c)
            await stock(c)
            await shine(c)
            await nochat(c)

            print("\n== every server")
            exceptions = [e for e in c.events if e["method"] == "Runtime.exceptionThrown"]
            check("no uncaught exceptions", not exceptions, str(len(exceptions)))
            urls = [e["params"]["request"]["url"] for e in c.events
                    if e["method"] == "Network.requestWillBeSent"]
            foreign = sorted({u for u in urls if not u.startswith((STOCK, MOD, NOCHAT, SHINE))})
            check("every request went to the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

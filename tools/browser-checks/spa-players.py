#!/usr/bin/env python3
"""Gate: the new panel's Players tab, driven in a real browser.

The same gate as mock-acceptance.py, pointed at the replacement instead of the
2012 panel. It asserts the things the old panel got wrong, so a regression
looks like a failure rather than like a design choice:

  * identifiers masked until asked for (defect 6)
  * a bot's per-player buttons are disabled rather than inert (defect 7)
  * a command is reported as sent and unverified, never as succeeded
  * sort order and a half-typed filter survive a poll
  * nothing is fetched from anywhere but the game server (defect 13)
  * with the mod, a bare / is a page leading to the panel, not the state
    blob with every player's IP (defect 12); on stock it still is the blob
  * the 2012 panel's round buttons, with commands that exist (its Reset
    Round sent sv_resetround: defect 17); Force even teams is disabled
    mid-round and says why
  * the 09-26+ engine's Family Sharing and rejected moves show only when
    the server reports them: a Shared column with the owner's id masked, and a
    Rejected column; the mod's Hive skill column (P1); and every human row
    links to ns2panel.com (P3)
  * Mute is disabled without Shine and says why -- the game has no mute,
    and the 2012 panel's sv_mute never existed (defect 18); under Shine's
    basecommands it is sh_gag, and the row shows the gag and offers Unmute

Build the panel and start the mock on it first:

    (cd panel && npx vite build)
    node mock/server.js --port 8091 --web web --perf-rate 2

Exit status is 0 only if every check passes.
"""
import asyncio, json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

MOCK = os.environ.get("MOCK_URL", "http://127.0.0.1:8091")
# Shine with basecommands, for Mute, and the 09-26+ engine's per-player
# fields. Both driven in the stock run only.
SHINE = os.environ.get("SHINE_URL", "http://127.0.0.1:8096")
BETA = os.environ.get("BETA_URL", "http://127.0.0.1:8102")
BASE = MOCK + "/index.html"
PORT = 9226

# Set when the mock is running with --mod, i.e. it answers with a mod_version.
# The panel must then drop the stock-server banner -- the same detection,
# asserted from the other side.
EXPECT_MOD = os.environ.get("SPA_EXPECT_MOD") == "1"

results = []


def check(label, ok, detail=""):
    results.append((label, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {label:<52} {detail}")
    return ok


# Counted from the end: the columns a server may add (Skill, Rejected,
# Shared) all come before these, then Actions.
STEAMID_CELL = "r.cells[r.cells.length-3]"
IP_CELL = "r.cells[r.cells.length-2]"
ROWS = "document.querySelectorAll('table tbody tr')"


async def main():
    with urllib.request.urlopen(f"{MOCK}/__mock/reset", timeout=5) as r:
        print(f"mock reset: {r.read().decode().strip()}")

    proc, _ = launch_chrome(port=PORT)
    try:
        async with CDP(page_target(PORT)) as c:
            await c.send("Runtime.enable"); await c.send("Page.enable")
            await c.send("Network.enable")
            # Every destructive action asks first; answer yes without a human.
            await c.send("Page.addScriptToEvaluateOnNewDocument",
                         source="window.confirm = () => true;"
                                # Settings persist per origin, and the last tab is
                                # reopened: start every page load from the defaults.
                                "try { localStorage.removeItem('improved-webadmin.settings'); } catch {}")
            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(4)

            exceptions = [e for e in c.events
                          if e["method"] == "Runtime.exceptionThrown"]

            print("\n== the page loads")
            check("document.title", await c.eval("document.title")
                  == "NS2 Server Admin")
            check("no uncaught exceptions", not exceptions,
                  str(len(exceptions)))
            check("server name from the mock",
                  (await c.eval("document.querySelector('.server-name').textContent"))
                  == "Example NS2 Server")
            check("header stats populated",
                  "tickrate" in str(await c.eval(
                      "document.querySelector('.stats').textContent")))

            print("\n== stock-server honesty")
            banner = str(await c.eval(
                "document.querySelector('.banner h2')?.textContent||''"))
            if EXPECT_MOD:
                check("no stock banner when the server runs our Lua",
                      "Stock server Lua" not in banner, banner or "(no banner)")
            else:
                check("stock Lua banner is shown", "Stock server Lua" in banner)

            print("\n== Players")
            rows = await c.eval(f"{ROWS}.length")
            check("player rows", rows == 12, f"{rows} rows")
            masked = await c.eval(
                f"[...{ROWS}].map(r=>{STEAMID_CELL}.textContent).join('|')")
            check("Steam ids are masked by default (defect 6)",
                  "10000000" not in str(masked), str(masked)[:48])
            ips = await c.eval(
                f"[...{ROWS}].map(r=>{IP_CELL}.textContent).join('|')")
            check("IPs are masked by default (defect 6)",
                  "0.0.0.0" not in str(ips), str(ips)[:48])
            await c.eval(
                f"[...{ROWS}].map(r=>{STEAMID_CELL}.querySelector('button'))"
                ".find(b=>b)?.click()")
            await asyncio.sleep(0.3)
            revealed = await c.eval(
                f"[...{ROWS}].map(r=>{STEAMID_CELL}.textContent).join('|')")
            check("a Steam id reveals on click", "10000000" in str(revealed),
                  str(revealed)[:48])

            print("\n== a bot's buttons say why they cannot work (defect 7)")
            bot_disabled = await c.eval(
                f"[...{ROWS}].filter(r=>r.textContent.includes('BOT'))"
                # Scoped to the action controls: the masked-IP reveal button
                # lives in the same row and is meant to work on a bot too.
                ".every(r=>[...r.querySelectorAll('.actions button,.actions select')]"
                ".every(b=>b.disabled))")
            check("every control on a bot row is disabled", bot_disabled is True)
            reason = await c.eval(
                f"[...{ROWS}].find(r=>r.textContent.includes('BOT'))"
                ".querySelector('button[disabled]').title")
            check("and carries the reason", "Steam id 0" in str(reason),
                  str(reason)[:60])

            print("\n== filter and sort survive a poll")
            await c.eval("(()=>{const i=document.querySelector('input[type=search]');"
                         "i.value='Skulk';"
                         "i.dispatchEvent(new Event('input',{bubbles:true}));})()")
            await asyncio.sleep(0.3)
            filtered = await c.eval(f"{ROWS}.length")
            await c.eval("[...document.querySelectorAll('thead th')]"
                         ".find(t=>t.textContent.startsWith('Ping')).click()")
            await asyncio.sleep(0.3)
            sorted_first = await c.eval(f"{ROWS}[0].cells[0].textContent")
            await asyncio.sleep(5)     # several polls at the 2 s default
            check("filter still applied after polls",
                  await c.eval(f"{ROWS}.length") == filtered,
                  f"{filtered} rows")
            check("the filter box keeps what was typed",
                  await c.eval("document.querySelector('input[type=search]').value")
                  == "Skulk")
            check("sort order held across polls",
                  await c.eval(f"{ROWS}[0].cells[0].textContent") == sorted_first,
                  str(sorted_first)[:30])
            check("sort direction is announced",
                  "descending" in str(await c.eval(
                      "[...document.querySelectorAll('thead th')]"
                      ".find(t=>t.textContent.startsWith('Ping'))"
                      ".getAttribute('aria-sort')")))

            print("\n== the rest of a row's actions")
            await c.eval("(()=>{const i=document.querySelector('input[type=search]');"
                         "i.value='';"
                         "i.dispatchEvent(new Event('input',{bubbles:true}));})()")
            await asyncio.sleep(0.3)
            row = f"[...{ROWS}].find(r=>!r.textContent.includes('BOT'))"
            async def last_activity():
                return (str(await c.eval(
                            "document.querySelector('.cmd-confirm .cmd')?.textContent||''")),
                        str(await c.eval(
                            "document.querySelector('.cmd-confirm .note')?.textContent||''")))
            await c.eval(f"[...{row}.querySelectorAll('.actions button')]"
                         ".find(b=>b.textContent==='Slay').click()")
            await asyncio.sleep(2.5)
            cmd, note = await last_activity()
            check("Slay sends sv_slay with the Steam id", cmd == "sv_slay 10000000", cmd)
            # A slay that works prints nothing, like a kick.
            check("and says what is known",
                  ("printed nothing" in note) if EXPECT_MOD else ("unverified" in note),
                  note[:50])
            await c.eval(f"(()=>{{const s={row}.querySelector('.actions select');"
                         "s.value='1';s.dispatchEvent(new Event('change',{bubbles:true}));})()")
            await asyncio.sleep(2.5)
            cmd, _ = await last_activity()
            check("Move to Marines sends sv_switchteam <id> 1",
                  cmd == "sv_switchteam 10000000 1", cmd)
            check("and the row moves", await c.eval(f"{row}.cells[1].textContent") == "Marines")
            eject = f"[...{row}.querySelectorAll('.actions button')].find(b=>b.textContent==='Eject')"
            check("Eject is offered only to a commander",
                  await c.eval(f"{eject}.disabled") is True
                  and await c.eval(f"{eject}.title") == "Eject: Not commanding")

            print("\n== a kick reports what it knows, and no more")
            await c.eval("(()=>{const i=document.querySelector('input[type=search]');"
                         "i.value='';"
                         "i.dispatchEvent(new Event('input',{bubbles:true}));})()")
            await asyncio.sleep(0.3)
            before = await c.eval(f"{ROWS}.length")
            await c.eval(
                f"[...{ROWS}].find(r=>!r.textContent.includes('BOT'))"
                ".querySelector('.actions button').click()")
            await asyncio.sleep(2.5)
            note = await c.eval(
                "document.querySelector('.cmd-confirm .note')?.textContent||''")
            cmd = await c.eval(
                "document.querySelector('.cmd-confirm .cmd')?.textContent||''")
            check("the command is logged verbatim", cmd.startswith("sv_kick "), cmd)
            if EXPECT_MOD:
                # With the mod's Lua the result is known, so "unverified" would
                # be a lie in the other direction. A kick that works prints
                # nothing -- only its failure branch does -- so that is what
                # the panel must say.
                check("reported as ran-and-printed-nothing, not as success",
                      "printed nothing" in note and "success" not in note.lower(),
                      note[:70])
            else:
                check("and is reported as unverified, not as success",
                      "unverified" in note.lower() and "success" not in note.lower(),
                      note[:70])
            after = await c.eval(f"{ROWS}.length")
            check("the kicked player is gone from the table", after == before - 1,
                  f"{before} -> {after}")

            print("\n== round controls (defect 17)")
            def state():
                with urllib.request.urlopen(f"{MOCK}/?request=json", timeout=5) as r:
                    return json.loads(r.read())
            commands = await c.eval("[...document.querySelectorAll('.round-controls button')]"
                                    ".map(b=>b.dataset.command).join(' ')")
            check("the 2012 panel's four, with commands that exist",
                  commands == "sv_reset sv_rrall sv_randomall sv_forceeventeams", commands)
            even = "document.querySelector('[data-command=sv_forceeventeams]')"
            with urllib.request.urlopen(f"{MOCK}/__mock/round?started=1", timeout=5) as r:
                r.read()
            await asyncio.sleep(2.5)
            check("Force even teams is disabled mid-round",
                  await c.eval(f"{even}.disabled") is True)
            check("and says why", "mid-round" in str(await c.eval(f"{even}.title")))
            await c.eval("document.querySelector('[data-command=sv_reset]').click()")
            await asyncio.sleep(2.5)
            note = str(await c.eval(
                "document.querySelector('.cmd-confirm .note')?.textContent||''"))
            if EXPECT_MOD:
                check("Reset round reports what the server printed",
                      "Reset AI TeamBrain" in note, note[:60])
            else:
                check("Reset round is reported as unverified", "unverified" in note, note[:60])
            check("the round is reset", state()["game_started"] is False)
            check("and Force even teams is offered once it is",
                  not await c.eval(f"{even}.disabled"))
            await c.eval("document.querySelector('[data-command=sv_rrall]').click()")
            await asyncio.sleep(2.5)
            teams = set(await c.eval(f"[...{ROWS}].map(r=>r.cells[1].textContent)") or [])
            check("All to ready room moves everyone", teams == {"Ready room"}, sorted(teams))

            print("\n== Activity (G2): the full list on its own tab")
            async def open_tab(label):
                await c.eval("[...document.querySelectorAll('.tab')]"
                             f".find(t=>t.textContent.trim()==={json.dumps(label)}).click()")
                await asyncio.sleep(0.3)
            cmd = str(await c.eval("document.querySelector('.cmd-confirm .cmd')?.textContent||''"))
            check("Players shows its latest command in one line",
                  cmd == "sv_rrall" and await c.eval(
                      "document.querySelectorAll('.cmd-confirm .cmd').length") == 1, cmd)
            await open_tab("Bans")
            check("a tab nothing was sent from shows none",
                  await c.eval("!document.querySelector('.cmd-confirm')"))
            await open_tab("Activity")
            listed = json.loads(await c.eval(
                "JSON.stringify([...document.querySelectorAll('.activity-table tbody tr')]"
                ".map(r=>[r.cells[1].textContent, r.cells[2].textContent]))"))
            check("Activity lists every command, newest first, with the tab it came from",
                  [x[1].split(" ")[0] for x in listed[:5]]
                  == ["sv_rrall", "sv_reset", "sv_kick", "sv_switchteam", "sv_slay"]
                  and all(x[0] == "Players" for x in listed), f"{len(listed)} rows")
            check("and shows no one-line confirmation of its own",
                  await c.eval("!document.querySelector('.cmd-confirm')"))
            await open_tab("Players")

            print("\n== Mute (defect 18)")
            human = f"[...{ROWS}].find(r=>!r.textContent.includes('BOT'))"
            mute = f"{human}?.querySelector('[data-action=mute]')"
            # The kick above took the only human: start again from the fixtures.
            with urllib.request.urlopen(f"{MOCK}/__mock/reset", timeout=5) as r:
                r.read()
            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(3.5)
            check("without Shine, Mute is disabled",
                  await c.eval(f"{mute}?.disabled") is True)
            check("and says the game has no mute",
                  "no mute command" in str(await c.eval(f"{mute}?.title")))
            if not EXPECT_MOD:
                with urllib.request.urlopen(f"{SHINE}/__mock/reset", timeout=5) as r:
                    r.read()
                await c.send("Page.navigate", url=SHINE + "/index.html")
                await asyncio.sleep(3.5)
                check("under Shine's basecommands Mute is offered",
                      await c.eval(f"{mute}?.disabled") is False)
                await c.eval(f"{mute}.click()")
                await asyncio.sleep(2.5)
                note = str(await c.eval(
                    "document.querySelector('.cmd-confirm .note')?.textContent||''"))
                cmd = str(await c.eval(
                    "document.querySelector('.cmd-confirm .cmd')?.textContent||''"))
                check("it sends sh_gag", cmd.startswith("sh_gag "), cmd)
                check("and reports Shine's line", "gagged" in note, note[:60])
                check("the row shows the gag",
                      "MUTED" in str(await c.eval(f"{human}.textContent")))
                check("and offers Unmute", await c.eval(f"{mute}.textContent") == "Unmute")
                await c.eval(f"{mute}.click()")
                await asyncio.sleep(2.5)
                cmd = str(await c.eval(
                    "document.querySelector('.cmd-confirm .cmd')?.textContent||''"))
                check("Unmute sends sh_ungag", cmd.startswith("sh_ungag "), cmd)
                check("and the gag is gone",
                      "MUTED" not in str(await c.eval(f"{human}.textContent")))

            print("\n== the 09-26+ engine's per-player fields")
            await c.send("Page.navigate", url=BASE)
            await asyncio.sleep(3.5)
            check("no Rejected column from a server that does not count",
                  not await c.eval("[...document.querySelectorAll('thead th')]"
                                   ".some(t=>t.textContent==='Rejected')"))
            check("and no Shared column",
                  not await c.eval("[...document.querySelectorAll('thead th')]"
                                   ".some(t=>t.textContent==='Shared')"))
            has_skill = await c.eval("[...document.querySelectorAll('thead th')]"
                                     ".some(t=>t.textContent.startsWith('Skill'))")
            if EXPECT_MOD:
                with urllib.request.urlopen(f"{MOCK}/?request=json", timeout=5) as r:
                    me = next(p for p in json.loads(r.read())["player_list"]
                              if p["steamid"] == 10000000)
                cell = json.loads(await c.eval(
                    f"JSON.stringify((t=>[t.querySelector('.skill-value').textContent,t.title,"
                    f"t.querySelector('.skill-badge')?.textContent,"
                    f"getComputedStyle(t.querySelector('.skill-badge')).backgroundPosition])"
                    f"({human}.querySelector('.skill-cell')))"))
                marines = round(me["skill"] + me["skill_offset"])
                check("the mod's Skill column shows the server's skill (P1)",
                      has_skill and cell[0] == str(round(me["skill"])), str(cell[0]))
                check("and on hover the marine, alien and commander figures",
                      f"Marines {marines}" in cell[1] and "Commander" in cell[1], cell[1][:60])
                names = {0: "Rookie", 1: "Recruit", 2: "Frontiersman", 3: "Squad Leader",
                         4: "Veteran", 5: "Commandant", 6: "Special Ops", 7: "Sanji Survivor"}
                tier = me["skill_tier"]
                check("the game's badge for the server's tier, named", cell[2] == names[tier],
                      f"{tier} {cell[2]}")
                check("from the sheet's row tier + 2, 20 px a row",
                      cell[3] == f"0px {-(tier + 2) * 20}px", cell[3])
                check("and the tier first on hover", cell[1].startswith(names[tier]), cell[1][:30])
                check("a bot shows no skill, and the bot badge", await c.eval(
                    f"[...{ROWS}].filter(r=>r.textContent.includes('BOT'))"
                    ".every(r=>r.querySelector('.skill-value').textContent==='--'"
                    "&&r.querySelector('.skill-badge')?.textContent==='Bot')"))
                loaded = await c.eval(
                    "(async()=>{const u=getComputedStyle(document.querySelector('.skill-badge'))"
                    ".backgroundImage.slice(5,-2);const i=new Image();i.src=u;"
                    "try{await i.decode();return i.naturalWidth+'x'+i.naturalHeight}"
                    "catch(e){return 'failed '+u}})()", await_promise=True)
                check("the sheet loads from the web root, 100x320", loaded == "100x320", loaded)
            else:
                check("no Skill column from a stock server", not has_skill)
            link = json.loads(await c.eval(
                f"JSON.stringify((a=>a&&[a.href,a.rel,a.target])"
                f"({human}.querySelector('a.ns2panel-link')))"))
            check("a player links to ns2panel.com by account id, without a referrer",
                  link and link[0] == "https://ns2panel.com/player/10000000"
                  and "noreferrer" in link[1] and link[2] == "_blank", str(link)[:60])
            check("while the Steam id itself stays masked",
                  "10000000" not in str(await c.eval(f"{human}.querySelector('td:nth-last-child(3)').textContent")))
            check("and bots get no link", await c.eval(
                f"[...{ROWS}].filter(r=>r.textContent.includes('BOT'))"
                ".every(r=>!r.querySelector('a.ns2panel-link'))"))
            if not EXPECT_MOD:
                await c.send("Page.navigate", url=BETA + "/index.html")
                await asyncio.sleep(3.5)
                check("a server that counts gets the Rejected column",
                      await c.eval("[...document.querySelectorAll('thead th')]"
                                   ".some(t=>t.textContent==='Rejected')"))
                cell = await c.eval(f"{human}.querySelector('.rejected-cell')"
                                    "?.textContent||''")
                check("time credit · other, for the player", cell == "37 · 2", cell)
                check("time-credit rejections stand out",
                      await c.eval(f"{human}.querySelector('.rejected-cell')"
                                   ".classList.contains('tone-error')"))
                check("a server that reports Family Sharing gets the Shared column",
                      await c.eval("[...document.querySelectorAll('thead th')]"
                                   ".some(t=>t.textContent==='Shared')"))
                check("and a shared copy says so there",
                      "shared copy" in str(await c.eval(
                          f"{human}.querySelector('.shared-cell').textContent")))
                owner = f"{human}.querySelector('.owner-id')"
                check("the owner's id is masked",
                      "10000042" not in str(await c.eval(f"{owner}?.textContent||''")))
                await c.eval(f"{owner}.querySelector('button').click()")
                await asyncio.sleep(0.3)
                check("and reveals on click",
                      "10000042" in str(await c.eval(f"{owner}.textContent")))
                bots = await c.eval(f"[...{ROWS}].filter(r=>r.textContent.includes('BOT'))"
                                    ".every(r=>!r.querySelector('.shared-cell')"
                                    ".textContent.includes('shared copy'))")
                check("bots read as not shared", bots is True)

            print("\n== a bare / (CURRENT-UI defect 12)")
            with urllib.request.urlopen(f"{MOCK}/", timeout=5) as r:
                ctype, body = r.headers.get("Content-Type", ""), r.read().decode()
            with urllib.request.urlopen(f"{MOCK}/?request=json", timeout=5) as r:
                state_body = r.read().decode()
            check("?request=json is still the server state",
                  '"player_list"' in state_body, f"{len(state_body)} B")
            if EXPECT_MOD:
                check("/ is a page, not the state blob",
                      ctype.startswith("text/html") and "player_list" not in body
                      and "ipaddress" not in body, ctype)
                await c.send("Page.navigate", url=MOCK + "/")
                await asyncio.sleep(3)
                landed = str(await c.eval("location.pathname"))
                check("and a browser there lands on the panel", landed == "/index.html",
                      landed)
            else:
                check("on stock, / is the state blob, as on a real server",
                      '"player_list"' in body, ctype)

            print("\n== nothing is fetched from a third party (defect 13)")
            urls = [e["params"]["request"]["url"] for e in c.events
                    if e["method"] == "Network.requestWillBeSent"]
            foreign = sorted({u for u in urls if not u.startswith((MOCK, SHINE, BETA))})
            check("every request went to the game server", not foreign,
                  f"{len(urls)} requests" + (f", foreign: {foreign}" if foreign else ""))
    finally:
        proc.terminate()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

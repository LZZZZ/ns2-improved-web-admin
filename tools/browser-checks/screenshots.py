#!/usr/bin/env python3
"""Screenshots of the panel for the README, taken against the mock.

The mock holds no real data: fake player names, 0.0.0.0 for every IP, and
made-up history for the performance charts and the log. So nothing here can
publish a real player. Each shot starts from a fresh browser profile, which
means the panel's defaults: dark theme, Steam ids and IPs masked.

Starts its own mocks on ports 8140-8143, so it can run beside the gates, and
stops if one of those ports is already taken rather than shoot someone else's.
Build the panel first (`cd panel && npx vite build`): the mocks serve `web/`.

Usage: tools/browser-checks/screenshots.py [--out DIR] [name ...]
  DIR defaults to docs/screenshots. Names pick shots (players, performance,
  maps, mods, console); none means all of them.
"""
import argparse
import asyncio
import base64
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, launch_chrome, page_target

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHROME_PORT = 9231
WIDTH, HEIGHT = 1440, 900

# port -> the mock's flags
MOCKS = {
    8140: ["--mod", "--shine", "--beta-players"],
    8141: ["--mod", "--tickstat", "10"],
    8142: ["--mod", "--shine=ban,reservedslots,mapvote", "--maps=modded"],
    8143: ["--mod"],
}

# name -> (port, tab, seconds to let it settle, page height to keep or None)
SHOTS = {
    "players":     (8140, "Players", 4, None),
    "performance": (8141, "Performance", 6, 1312),
    "maps":        (8142, "Maps", 4, None),
    "mods":        (8142, "Mods", 6, None),
    "console":     (8143, "Console", 4, None),
}


def answers(port):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/index.html", timeout=1)
        return True
    except OSError:
        return False


def start_mocks(ports):
    taken = [p for p in ports if answers(p)]
    if taken:
        raise SystemExit(f"port {taken[0]} is already in use; stop what is on it first")
    procs = []
    for port in ports:
        procs.append(subprocess.Popen(
            ["node", "mock/server.js", "--port", str(port), "--web", "web", *MOCKS[port]],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for port in ports:
        for _ in range(100):
            if answers(port):
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"mock on {port} did not start")
    return procs


async def shoot(name, port, tab, settle, height, out):
    async with CDP(page_target(CHROME_PORT)) as c:
        await c.send("Page.enable")
        await c.send("Runtime.enable")
        await c.send("Emulation.setTimezoneOverride", timezoneId="UTC")
        await c.send("Emulation.setDeviceMetricsOverride",
                     width=WIDTH, height=HEIGHT, deviceScaleFactor=1, mobile=False)
        await c.send("Page.navigate", url=f"http://127.0.0.1:{port}/index.html")
        await asyncio.sleep(3)
        await c.eval("localStorage.clear()")
        await c.send("Page.reload")
        await asyncio.sleep(3)
        found = await c.eval("(()=>{const t=[...document.querySelectorAll('.tab')]"
                             f".find(t=>t.textContent.trim()==={tab!r});"
                             "if(t)t.click();return !!t})()")
        if not found:
            raise SystemExit(f"{name}: no tab named {tab}")
        await asyncio.sleep(settle)
        await c.eval("window.scrollTo(0,0); document.activeElement?.blur()")
        full = await c.eval("document.documentElement.scrollHeight")
        h = min(full, height) if height else HEIGHT
        shot = await c.send("Page.captureScreenshot", format="png",
                            captureBeyondViewport=h > HEIGHT,
                            clip={"x": 0, "y": 0, "width": WIDTH, "height": h, "scale": 1})
        path = out / f"{name}.png"
        path.write_bytes(base64.b64decode(shot["data"]))
        print(f"  {path.relative_to(ROOT)}  {WIDTH}x{h}")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path, default=ROOT / "docs" / "screenshots")
    ap.add_argument("names", nargs="*", metavar="name")
    a = ap.parse_args()
    unknown = [n for n in a.names if n not in SHOTS]
    if unknown:
        ap.error(f"unknown shot {unknown[0]!r}; choose from {', '.join(SHOTS)}")
    names = a.names or list(SHOTS)
    a.out.mkdir(parents=True, exist_ok=True)
    mocks = start_mocks(sorted({SHOTS[n][0] for n in names}))
    chrome, _ = launch_chrome(port=CHROME_PORT)
    try:
        for n in names:
            await shoot(n, *SHOTS[n], a.out)
    finally:
        chrome.kill()
        for p in mocks:
            p.terminate()


if __name__ == "__main__":
    asyncio.run(main())

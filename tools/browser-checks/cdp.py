"""Minimal Chrome DevTools Protocol client over websockets."""
import asyncio, json, itertools, subprocess, os, shutil, tempfile, urllib.request, time
import websockets


class CDP:
    def __init__(self, ws_url):
        self.ws_url = ws_url
        self._ids = itertools.count(1)
        self.events = []          # every event, in order
        self._waiters = {}

    async def __aenter__(self):
        self.ws = await websockets.connect(self.ws_url, max_size=64 * 1024 * 1024)
        self._pump = asyncio.create_task(self._read())
        return self

    async def __aexit__(self, *a):
        self._pump.cancel()
        await self.ws.close()

    async def _read(self):
        async for raw in self.ws:
            msg = json.loads(raw)
            if "id" in msg:
                fut = self._waiters.pop(msg["id"], None)
                if fut and not fut.done():
                    fut.set_result(msg)
            else:
                msg["_t"] = time.time()
                self.events.append(msg)

    async def send(self, method, **params):
        mid = next(self._ids)
        fut = asyncio.get_running_loop().create_future()
        self._waiters[mid] = fut
        await self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        msg = await asyncio.wait_for(fut, timeout=60)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg.get("result", {})

    async def eval(self, expr, await_promise=False):
        r = await self.send("Runtime.evaluate", expression=expr,
                            returnByValue=True, awaitPromise=await_promise)
        if "exceptionDetails" in r:
            return {"_exception": r["exceptionDetails"].get("text"),
                    "detail": r["exceptionDetails"].get("exception", {}).get("description")}
        return r.get("result", {}).get("value")

    def take_events(self, *methods):
        out = [e for e in self.events if not methods or e["method"] in methods]
        return out


def launch_chrome(port=9222, profile=None):
    profile = profile or tempfile.mkdtemp(prefix="cdp-profile-")
    chrome = shutil.which("google-chrome") or shutil.which("google-chrome-stable")
    proc = subprocess.Popen(
        [chrome, "--headless=new", f"--remote-debugging-port={port}",
         f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
         "--disable-gpu", "--disable-dev-shm-usage", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=1) as r:
                json.load(r)
            break
        except Exception:
            time.sleep(0.2)
    else:
        proc.kill()
        raise RuntimeError("chrome did not expose CDP")
    return proc, profile


def page_target(port=9222):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
        targets = json.load(r)
    for t in targets:
        if t["type"] == "page":
            return t["webSocketDebuggerUrl"]
    raise RuntimeError("no page target")

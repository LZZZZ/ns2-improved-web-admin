#!/usr/bin/env python3
"""Poll at browser cadence on a single nonce and find where it dies.

The browser run showed 240/240 fetches succeeding across 8 minutes with no
401 visible in DevTools.  Either the server never expired the nonce under
continuous use, or Chrome re-authenticated internally and did not surface
it.  This does at protocol level exactly what the page was doing -- one
nonce, nc incrementing, one request every 2 s -- so the answer is the
server's alone.
"""
import hashlib, os, re, sys, time, urllib.request, urllib.error

user, pw, port = os.environ["WEBUSER"], os.environ["WEBPASS"], os.environ["WEBPORT"]
url = f"http://127.0.0.1:{port}/?request=getperfdata"
md5 = lambda s: hashlib.md5(s.encode()).hexdigest()


def challenge():
    try:
        urllib.request.urlopen(url)
    except urllib.error.HTTPError as e:
        h = e.headers.get("WWW-Authenticate")
        return (re.search(r'nonce="([^"]+)"', h).group(1),
                re.search(r'realm="([^"]+)"', h).group(1), h)


nonce, realm, hdr0 = challenge()
ha1, ha2 = md5(f"{user}:{realm}:{pw}"), md5("GET:/?request=getperfdata")
print(f"first challenge: {hdr0}\n")

t0, nc, ok = time.time(), 0, 0
while time.time() - t0 < 420:
    nc += 1
    resp = md5(f"{ha1}:{nonce}:{nc:08x}:abc123:auth:{ha2}")
    auth = (f'Digest username="{user}", realm="{realm}", nonce="{nonce}", '
            f'uri="/?request=getperfdata", qop=auth, nc={nc:08x}, '
            f'cnonce="abc123", response="{resp}"')
    age = round(time.time() - t0)
    try:
        urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": auth}))
        ok += 1
    except urllib.error.HTTPError as e:
        w = e.headers.get("WWW-Authenticate") or ""
        stale = 'stale="true"' in w.replace(" ", "")
        print(f"  refused at nonce age {age}s after {ok} accepted requests "
              f"(nc up to {nc:08x})")
        print(f"    HTTP {e.code}  stale={'true' if stale else 'ABSENT -- a browser would prompt'}")
        print(f"    {w}")
        m = re.search(r'nonce="([^"]+)"', w)
        if m:
            nonce, nc = m.group(1), 1
            print("    retrying with the fresh nonce the refusal carried...")
            resp = md5(f"{ha1}:{nonce}:{nc:08x}:abc123:auth:{ha2}")
            auth = (f'Digest username="{user}", realm="{realm}", nonce="{nonce}", '
                    f'uri="/?request=getperfdata", qop=auth, nc={nc:08x}, '
                    f'cnonce="abc123", response="{resp}"')
            r = urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": auth}))
            print(f"    HTTP {r.status} -- this is the round trip a browser makes "
                  f"invisibly, and it is why the fetch() poll never broke")
        break
    time.sleep(2)
else:
    print(f"  never refused: {ok} requests accepted on one nonce over "
          f"{round(time.time()-t0)}s of continuous use")

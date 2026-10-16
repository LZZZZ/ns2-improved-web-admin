#!/bin/sh
# Copy the panel into a checkout of UWE's ns2-game repo (beta branch):
# the Lua, the built web/, and the panel source as utils/WebAdminPanel.
# Usage: tools/export-to-ns2-game.sh <ns2-game checkout>
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dst=$(cd "${1:?usage: $0 <ns2-game checkout>}" && pwd)
test -f "$dst/ns2/lua/Server.lua" || { echo "$dst: not an ns2-game checkout" >&2; exit 1; }

# CRLF, like the stock file, so the diff shows what changed.
sed 's/$/\r/' "$here/lua/ServerWebInterface.lua" > "$dst/ns2/lua/ServerWebInterface.lua"

# client_game/ in ns2/web is the game's in-game widgets, not the panel.
web=$dst/ns2/web
rm -rf "$web/index.html" "$web/assets" "$web/THIRD-PARTY-LICENSES.txt" "$web/css" "$web/js" "$web/img"
cp -r "$here/web/." "$web/"

src=$dst/utils/WebAdminPanel
rm -rf "$src"
mkdir -p "$src"
cd "$here/panel"
cp -r src public index.html package.json package-lock.json tsconfig.json "$here/LICENSE" "$src/"
sed 's|^const out = "../web";$|const out = "../../ns2/web";|' vite.config.ts > "$src/vite.config.ts"
grep -q '^const out = "../../ns2/web";$' "$src/vite.config.ts"
echo node_modules/ > "$src/.gitignore"
cat > "$src/README.md" <<'EOF'
# Web admin panel

Source of the server web admin in `ns2/web/` (Preact, TypeScript, Vite).
Server side: `ns2/lua/ServerWebInterface.lua`.

    npm ci
    npm run check    # typecheck
    npm run build    # writes ns2/web/index.html, assets/, THIRD-PARTY-LICENSES.txt

API: openapi.yaml.

MIT (LICENSE). Bundled libraries: ns2/web/THIRD-PARTY-LICENSES.txt.
EOF

# The API spec, without what points into this repo: fixture examples and
# links to docs, fixtures and the mock.
python3 - "$here/docs/openapi.yaml" "$src/openapi.yaml" <<'PY'
import re, sys, yaml
src, out = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
indent = lambda l: len(l) - len(l.lstrip())

def end(i):
    j = i + 1
    while j < len(lines) and (not lines[j].strip() or indent(lines[j]) > indent(lines[i])):
        j += 1
    while not lines[j - 1].strip():
        j -= 1
    return j

kept, i = [], 0
while i < len(lines):
    line = lines[i]
    if line.strip() == "x-fixtures:":
        i = end(i)
        continue
    if line.strip() == "examples:":
        j, entries = i + 1, []
        while j < end(i):
            k = end(j)
            if not any("externalValue" in l for l in lines[j:k]):
                entries += lines[j:k]
            j = k
        kept += [line] + entries if entries else []
        i = end(i)
        continue
    kept.append(line)
    i += 1
s = "\n".join(kept)

for pattern, repl in [
    (r"Machine-readable companion to \[API\.md\]\(API\.md\)\. (Read from.*?needs\)\.).*?check-openapi\.py`\.", r"\1"),
    (r", CONSTRAINTS item \d+", ""),
    (r"\s*\((?:CONSTRAINTS|REQUIREMENTS|SERVER-COST)[^)]*\)", ""),
    (r"; see REQUIREMENTS\.md item \d+\.", "."),
    (r"\s*(?:See\s+)?(?:CONSTRAINTS|REQUIREMENTS)\.md[^.]*\.", ""),
    (r"\s*--\s*develop against `mock/server\.js`", ""),
    (r"\s*Live captures must never be committed.*?`0\.0\.0\.0`\.", ""),
    (r"\s*Redacted in the fixtures\.", ""),
]:
    s = re.sub(pattern, repl, s, flags=re.S)

left = re.findall(r".*(?:\.md\b|CONSTRAINTS|REQUIREMENTS|fixtures|mock/|externalValue|x-fixtures).*", s)
assert not left, "openapi.yaml still points into this repo:\n" + "\n".join(left)
yaml.safe_load(s)
open(out, "w").write(s)
PY

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

MIT (LICENSE). Bundled libraries: ns2/web/THIRD-PARTY-LICENSES.txt.
EOF

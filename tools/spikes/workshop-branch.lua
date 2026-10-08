-- SPIKE 2026-09-27: what the workshop browser can rely on.
--
-- Not loadable on its own. tools/spikes/make-workshop-probe.sh splices this
-- into a copy of lua/ServerWebInterface.lua, at the top of OnWebRequest, so
-- the probe runs next to the shipped handlers. Questions (docs/REQUIREMENTS.md
-- item 4, CONSTRAINTS item 2):               /?request=workshopprobe&do=...
--
--   do=search&text=&p=   call Server.SearchWorshop directly; `do=result&id=`
--                        reports what the callback got: how many arguments,
--                        their types, the item count, the first item's keys
--                        and types, and how long it took.
--   do=json              how json.encode writes an empty table.
--   do=install&id=       Server.InstallMod(id) under pcall: what it returns,
--                        and the installed count before and after.
--   do=installed         every installed mod, id and title, with types.
--   do=functions         every Server and Shared function whose name hints at
--                        Steam or connectivity, and what the no-argument getters
--                        return (offline, is there any signal to use?).

    if actions.request == "workshopprobe" then

        workshopProbe = workshopProbe or { n = 0, searches = { } }
        local P = workshopProbe
        local what = actions["do"]
        local out = { ["do"] = what, now = Shared.GetTime() }

        local function describe(v)
            local t = type(v)
            if t == "table" then
                local n, keys = 0, { }
                for k, x in pairs(v) do
                    n = n + 1
                    if n <= 40 then table.insert(keys, tostring(k) .. ":" .. type(x)) end
                end
                table.sort(keys)
                return { type = t, count = n, len = #v, keys = keys }
            end
            return { type = t, value = tostring(v) }
        end

        if what == "search" then
            P.n = P.n + 1
            local id = P.n
            local text = actions.text
            local page = actions.p and tonumber(actions.p) or actions.p
            local entry = { text = tostring(text), page = tostring(page),
                            page_type = type(page), started = Shared.GetTime() }
            P.searches[id] = entry
            local ok, err = pcall(Server.SearchWorshop, text, page, function(...)
                entry.returned = Shared.GetTime()
                entry.elapsed = entry.returned - entry.started
                entry.nargs = select("#", ...)
                entry.args = { }
                for i = 1, entry.nargs do
                    entry.args[i] = describe((select(i, ...)))
                end
                local results = (select(1, ...))
                if type(results) == "table" then
                    entry.titles = { }
                    for i, m in ipairs(results) do
                        if i <= 60 then
                            table.insert(entry.titles, tostring(m.title) .. " | "
                                .. type(m.id) .. ":" .. tostring(m.id))
                        end
                    end
                    if results[1] then entry.first = describe(results[1]) end
                end
            end)
            entry.call_ok = ok
            entry.call_err = err and tostring(err) or nil
            out.id = id
            out.entry = entry

        elseif what == "result" then
            out.entry = P.searches[tonumber(actions.id)]

        elseif what == "json" then
            out.empty = json.encode({ })
            out.items_empty = json.encode({ items = { } })
            out.nested = json.encode({ done = true, items = { } })

        elseif what == "install" then
            out.before = Server.GetNumMods()
            local r = { pcall(Server.InstallMod, actions.id) }
            out.pcall_ok = r[1]
            out.returned = { }
            for i = 2, table.maxn(r) do out.returned[i - 1] = describe(r[i]) end
            out.nreturned = table.maxn(r) - 1
            out.after = Server.GetNumMods()

        elseif what == "functions" then
            out.functions = { }
            for _, lib in ipairs({ "Server", "Shared" }) do
                for k, v in pairs(_G[lib]) do
                    local lk = type(k) == "string" and k:lower() or ""
                    if lk:find("steam") or lk:find("connect") or lk:find("online")
                            or lk:find("network") or lk:find("lan") or lk:find("master")
                            or lk:find("workshop") or lk:find("worshop") or lk:find("ugc") then
                        local line = lib .. "." .. k .. ":" .. type(v)
                        if type(v) == "function" and (k:find("^Get") or k:find("^Is") or k:find("^Has")) then
                            local ok, r = pcall(v)
                            line = line .. " -> " .. tostring(ok) .. " " .. tostring(r)
                        end
                        table.insert(out.functions, line)
                    end
                end
            end
            table.sort(out.functions)

        elseif what == "installed" then
            out.mods = { }
            for i = 1, Server.GetNumMods() do
                local id = Server.GetModId(i)
                table.insert(out.mods, type(id) .. ":" .. tostring(id)
                    .. " | " .. tostring(Server.GetModTitle(i)))
            end
        end

        return "application/json", json.encode(out)

    end

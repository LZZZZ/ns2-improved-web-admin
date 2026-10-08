-- SPIKE 2026-09-27: what the Mods tab can say about installed and active mods.
--
-- Not loadable on its own. tools/spikes/make-mods-probe.sh splices this into
-- a copy of lua/ServerWebInterface.lua, at the top of OnWebRequest, so the
-- probe runs next to the shipped handlers. Questions (docs/REQUIREMENTS.md
-- item 3):                                            /?request=modsprobe
--
--   1. Do GetActiveModId(i) values match GetModId(i) exactly (case, padding)?
--   2. Which active mods does the cycle not name? (engine-forced hotfixes?)
--   3. Is a per-map mod active only while its map is loaded?
--   4. Does a global mod removed from the cycle drop out at the next map?
--   5. Is a mod titled with its decimal id one that is not downloaded yet?
--   Also: which mod-related functions does Server expose?

    if actions.request == "modsprobe" then

        local out = { map = Shared.GetMapName() }

        out.installed = { }
        for i = 1, Server.GetNumMods() do
            local id = Server.GetModId(i)
            table.insert(out.installed, {
                id = type(id) .. ":" .. tostring(id),
                title = tostring(Server.GetModTitle(i)),
            })
        end

        out.active = { }
        for i = 1, Server.GetNumActiveMods() do
            local id = Server.GetActiveModId(i)
            table.insert(out.active, type(id) .. ":" .. tostring(id))
        end

        local cycle = ReadMapCycleFile()
        out.file_global = { }
        for _, m in ipairs(cycle and cycle.mods or { }) do
            table.insert(out.file_global, type(m) == "number"
                and string.format("%x", m) or tostring(m))
        end

        out.server_functions = { }
        local ok = pcall(function()
            for k, v in pairs(Server) do
                if type(k) == "string" and (k:find("Mod") or k:find("Workshop")
                        or k:find("Worshop") or k:find("Rank") or k:find("Whitelist")) then
                    table.insert(out.server_functions, k .. ":" .. type(v))
                end
            end
        end)
        out.server_iterable = ok
        table.sort(out.server_functions)

        return "application/json", json.encode(out)

    end

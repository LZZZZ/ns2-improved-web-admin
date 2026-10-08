-- SPIKE 2026-09-27: what the map cycle does under the Maps tab.
--
-- Not loadable on its own. tools/spikes/make-maps-probe.sh splices this into
-- a copy of lua/ServerWebInterface.lua, at the top of OnWebRequest, so the
-- probe runs next to the shipped (still vanilla) map handlers. Questions:
--
--   1. Does one getmapcycle rewrite the live cycle's mod ids to hex strings
--      (table.copyDict is shallow)? And is that the table Shine's mapvote
--      holds?                                         /?request=mapsprobe
--   2. Does getmapcycle show memory rather than the file?  (same, `file`)
--   3. dkjson: does `[]` survive a decode/encode, and do unknown keys?
--   4. Shine mapvote: GetMapsFromMapCycle, RoundLimit, GetNextMap().

    if actions.request == "mapsprobe" then

        local out = { }

        local function modTypes(t)
            local r = { }
            if type(t) == "table" and type(t.mods) == "table" then
                for i, m in ipairs(t.mods) do
                    if i > 3 then break end
                    r[i] = type(m) .. ":" .. tostring(m)
                end
            end
            return r
        end

        local cycle = MapCycle_GetMapCycle()
        out.memory_global_mods = modTypes(cycle)
        for _, entry in ipairs(cycle.maps or { }) do
            if type(entry) == "table" then
                out.memory_first_entry = { map = entry.map, mods = modTypes(entry) }
                break
            end
        end
        out.memory_map_count = #(cycle.maps or { })
        out.memory_time = cycle.time

        -- 2. the file, raw
        local f = io.open("config://MapCycle.json", "r")
        if f then
            local text = f:read("*a")
            f:close()
            out.file_bytes = #text
            local parsed = json.decode(text)
            out.file_map_count = parsed and parsed.maps and #parsed.maps or nil
            out.file_time = parsed and parsed.time or nil
        end
        local latest = MapCycle_GetLatestValidConfig()
        out.latest_is_memory = rawequal(latest, cycle)
        out.latest_map_count = #(latest.maps or { })

        -- 3. dkjson round trips
        local sample = '{"mods":[],"maps":["a",{"map":"b","min":12,"mods":[]}],' ..
                       '"groups":[{"name":"x","maps":["a"]}],"time":30.5}'
        out.roundtrip = json.encode((json.decode(sample)))
        local bare = { mods = { }, maps = { "a" } }
        out.fresh_empty = json.encode(bare)

        -- 4. Shine mapvote
        local plugin = GetShinePlugin and GetShinePlugin("mapvote")
        if plugin then
            local mv = { }
            mv.maps_from_cycle = plugin.Config and plugin.Config.GetMapsFromMapCycle
            mv.round_limit = plugin.Config and plugin.Config.RoundLimit
            mv.self_round_limit = plugin.RoundLimit
            mv.cycle_is_memory = rawequal(plugin.MapCycle, cycle)
            local ok, nextMap = pcall(plugin.GetNextMap, plugin)
            mv.next_ok = ok
            mv.next_map = tostring(nextMap)
            local ok2, cur = pcall(plugin.GetCurrentMap, plugin)
            mv.current = ok2 and tostring(cur) or ("error: " .. tostring(cur))
            mv.choices = #(plugin.MapChoices or { })
            for _, choice in ipairs(plugin.MapChoices or { }) do
                if type(choice) == "table" then
                    mv.first_table_choice = { map = choice.map, mods = modTypes(choice) }
                    break
                end
            end
            mv.vote_on_end = plugin.VoteOnEnd
            out.mapvote = mv
        else
            out.mapvote = "absent"
        end

        return "application/json", json.encode(out)

    end

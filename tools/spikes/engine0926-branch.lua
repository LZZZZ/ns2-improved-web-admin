-- SPIKE 2026-09-27: what the 09-26 engine changed under the mod's feet.
--
-- Not loadable on its own. tools/spikes/make-engine0926-probe.sh splices this
-- into a copy of lua/ServerWebInterface.lua, at the top of OnWebRequest, and
-- wraps the WebRequest hook so the probe can see every argument the engine
-- passes. One request type answers four questions:
--
--   1. Does the engine hand request headers to Lua? (CONSTRAINTS item 6 wants
--      to choose HTML or JSON by Accept.) Dumps every key of `actions` and
--      the count and types of the hook's arguments.
--   2. Can mod Lua write under config://? (REQUIREMENTS item 6, the
--      recent-players file.) Write, append, read back, a subdirectory, a
--      100 KB write, and whether os.rename / os.remove exist for an atomic
--      replace.
--   3. Do the log tail's seek/read calls still behave? (09-25 changed
--      f:seek("cur"), f:read(0) and f:read("*n").) Needs -logdir = config.
--   4. What does tonumber64 return now? (09-25: nil for non-numbers, signed
--      results.) ModIdsFromHex runs every hex mod id through it.
--
--   /?request=probe0926

    if actions.request == "probe0926" then

        local out = { args = webadminSpaProbeArgs }

        -- 1. Everything the handler was given.
        local dump = {}
        local okPairs, pairsErr = pcall(function()
            for k, v in pairs(actions) do
                local s = type(v) == "string" and v or ("<" .. type(v) .. ">")
                if #s > 160 then s = s:sub(1, 160) .. "..." end
                dump[tostring(k)] = s
            end
        end)
        out.actions_type = type(actions)
        out.actions = dump
        out.actions_pairs_error = (not okPairs) and tostring(pairsErr) or nil

        -- 2. Writing under config://
        local function tryWrite(path, mode, text)
            local r = { path = path, mode = mode }
            local ok, handle, err = pcall(io.open, path, mode)
            if not ok then r.raised = tostring(handle) return r end
            if not handle then r.opened = false r.err = tostring(err) return r end
            r.opened = true
            local wok, wret = pcall(function() return handle:write(text) end)
            r.write_ok = wok
            if not wok then r.write_err = tostring(wret) end
            r.closed = pcall(function() handle:close() end)
            return r
        end
        local function tryRead(path)
            local ok, handle, err = pcall(io.open, path, "r")
            if not ok then return nil, "raised: " .. tostring(handle) end
            if not handle then return nil, tostring(err) end
            local text = handle:read("*a")
            handle:close()
            return text
        end

        local stamp = tostring(Shared.GetSystemTime())
        local main = "config://webadmin-spa-probe.txt"
        local w = {}
        w.write = tryWrite(main, "w", "line1 " .. stamp .. "\n")
        w.append = tryWrite(main, "a", "line2 " .. stamp .. "\n")
        local back, backErr = tryRead(main)
        w.read_back = back or ("<nil> " .. tostring(backErr))
        w.round_trip_ok = back == ("line1 " .. stamp .. "\nline2 " .. stamp .. "\n")
        w.json_ext = tryWrite("config://webadmin-spa-probe.json", "w", '{"probe":' .. stamp .. '}')
        w.subdir = tryWrite("config://webadmin-spa/probe.txt", "w", "x")
        w.no_scheme = tryWrite("webadmin-spa-probe-noscheme.txt", "w", "x")
        w.big = tryWrite("config://webadmin-spa-probe-big.txt", "w", string.rep("0123456789abcdef", 6400))
        local big = tryRead("config://webadmin-spa-probe-big.txt")
        w.big_read_len = big and #big or -1
        w.os_rename = type(os.rename)
        w.os_remove = type(os.remove)
        if type(os.rename) == "function" then
            local ok, a, b = pcall(os.rename, "config://webadmin-spa-probe.json", "config://webadmin-spa-probe-renamed.json")
            w.rename_result = { ok = ok, a = tostring(a), b = tostring(b) }
            w.rename_target_reads = tryRead("config://webadmin-spa-probe-renamed.json") ~= nil
        end
        if type(os.remove) == "function" then
            local ok, a, b = pcall(os.remove, "config://webadmin-spa-probe-big.txt")
            w.remove_result = { ok = ok, a = tostring(a), b = tostring(b) }
            w.remove_gone = tryRead("config://webadmin-spa-probe-big.txt") == nil
        end
        out.write = w

        -- 3. The log tail's calls, against the live log.
        local l = {}
        local ok, handle = pcall(io.open, "config://log-Server.txt", "r")
        if ok and handle then
            local size = handle:seek("end")
            l.size = size
            l.seek_set = handle:seek("set", math.max(0, size - 64))
            local tail = handle:read("*a") or ""
            l.tail_len = #tail
            l.read0_at_eof = tostring(handle:read(0))
            l.seek_cur_back = tostring(handle:seek("cur", -16))
            local again = handle:read(16)
            l.seek_cur_reread_matches = again == tail:sub(-16)
            handle:seek("set", 0)
            l.read0_at_start = tostring(handle:read(0))
            l.read_n_on_text = tostring(handle:read("*n"))
            handle:close()
        else
            l.opened = false
            l.err = tostring(handle)
        end
        out.log = l

        -- 4. tonumber64 on what ModIdsFromHex can be handed.
        local t = {}
        for _, s in ipairs({ "0x1e62a2ce", "0x5b8a1e4d", "0x", "0xzz", "abc", "",
                              "0x7fffffffffffffff", "0xffffffffffffffff", "-5", "123" }) do
            local ok2, v = pcall(tonumber64, s)
            t[#t + 1] = { input = s, ok = ok2, type = type(v), value = tostring(v),
                          as_hex = (ok2 and v ~= nil) and select(2, pcall(string.format, "%x", v)) or nil }
        end
        out.tonumber64 = t

        return "application/json", json.encode(out)
    end


-- SPIKE 2026-09-28: what the Log tab can rely on.
--
-- Not loadable on its own. tools/spikes/make-log-probe.sh splices this into a
-- copy of lua/ServerWebInterface.lua at the top of OnWebRequest, so the probe
-- runs next to the shipped handlers. Boot the rig with -logdir equal to
-- -config_path, so config://log-Server.txt is the live log.
--
--   /?request=logprobe&op=big&kb=N   a reply of about N KB: the largest the
--                                    engine will serve
--   /?request=logprobe&op=bytes      write odd bytes to the log, read them back
--                                    and return them through json.encode
--   /?request=logprobe&op=head       the header and the size
--   /?request=logprobe&op=end        size, and whether the file ends in "\n"
--   /?request=logprobe&op=cost       what opening, seeking and reading cost

    if actions.request == "logprobe" then
        local path = "config://log-Server.txt"
        local op = actions.op or "head"
        local out = { op = op }

        if op == "big" then
            local kb = math.floor(tonumber(actions.kb) or 64)
            out.kb = kb
            out.pad = string.rep("0123456789abcdef", kb * 64)
            return "application/json", json.encode(out)
        end

        if op == "bytes" then
            -- Latin-1 e-acute, a lone continuation byte, 0xff, a UTF-8 e-acute,
            -- a tab, a control byte and a quote.
            local marker = "logprobe_bytes_" .. tostring(math.floor(Shared.GetSystemTime()))
            Shared.Message(marker .. " [\233] [\128] [\255] [\195\169] [\t] [\1] [\"] end")
        end

        local f, err = io.open(path, "rb")
        if not f then
            out.error = tostring(err)
            return "application/json", json.encode(out)
        end
        local size = f:seek("end")
        out.size = size

        if op == "head" then
            f:seek("set", 0)
            out.head = f:read(160)
        elseif op == "end" then
            f:seek("set", math.max(0, size - 1))
            local last = f:read(1)
            out.ends_newline = last == "\n"
            f:seek("set", math.max(0, size - 80))
            out.tail = f:read("*a")
        elseif op == "bytes" then
            f:seek("set", math.max(0, size - 200))
            out.tail = f:read("*a")
        elseif op == "cost" then
            local t = Shared.GetSystemTimeReal
            local runs = {}
            for _, bytes in ipairs({ 0, 65536, 262144, 1048576 }) do
                local best, worst = 1e9, 0
                local got = 0
                for i = 1, 20 do
                    local t0 = t()
                    local g = io.open(path, "rb")
                    local s = g:seek("end")
                    g:seek("set", math.max(0, s - bytes))
                    local text = bytes > 0 and g:read(bytes) or ""
                    local n = 0
                    for _ in string.gmatch(text, "[^\n]*\n") do n = n + 1 end
                    g:close()
                    local dt = (t() - t0) * 1000
                    if dt < best then best = dt end
                    if dt > worst then worst = dt end
                    got = #text
                end
                table.insert(runs, { bytes = bytes, read = got, best_ms = best, worst_ms = worst })
            end
            out.runs = runs
        end
        f:close()
        return "application/json", json.encode(out)
    end


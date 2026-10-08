-- Off-rig harness for getlog in lua/ServerWebInterface.lua.
--
-- Runs the shipped file under LuaJIT with the engine calls it touches stubbed,
-- over a directory standing in for config://, and writes log-Server.txt there
-- the way the engine does: a Date/Time header, lines appended, a new file with
-- a new header at a restart. It checks the tail, the byte cursor, paging back,
-- the cap, a partial line, a cut file and a new one -- not the engine: what the
-- engine writes and when is a rig question (docs/REQUIREMENTS.md item 7).
--
-- Its io.open serves the file as it was at the open, as Spark's does.
--
-- Usage: luajit tools/spikes/log-harness.lua --core <core/lua> [dir]
--   --core names the game's core/lua directory, in a server install: the
--   game's own dkjson.lua (and RingBuffer.lua) come from there.
--   dir defaults to a fresh temporary directory.
local HERE = (arg[0]:match("^(.*)/") or ".") .. "/"
local REPO = HERE .. "../../"
local opts, pos = dofile(HERE .. "harness-args.lua")("--core <core/lua> [dir]", { "core" })
local CORE = opts.core
local MOD = REPO .. "lua/ServerWebInterface.lua"
local DISK = pos[1]
if not DISK then
    DISK = os.tmpname()
    os.remove(DISK)
end
os.execute("mkdir -p '" .. DISK .. "'")
local LOG = DISK .. "/log-Server.txt"

local realOpen = io.open
local dkjson = dofile(CORE .. "dkjson.lua")

-- The engine's file: a header, then lines. `write` replaces it, `append` adds.
local function header(time)
    return "Date: 09/28/2026\nTime: " .. time .. ":\nBuild: 344 (9beedad4ba beta)\n"
        .. string.rep("-", 62) .. "\n"
end
local function write(text) local f = realOpen(LOG, "wb"); f:write(text); f:close() end
local function append(text) local f = realOpen(LOG, "ab"); f:write(text); f:close() end
local function content() local f = realOpen(LOG, "rb"); local t = f:read("*a"); f:close(); return t end

-- Every line of the file as getlog should serve it: {off, text}, CR dropped,
-- and a last line without its newline left out.
local function fileLines()
    local t, lines, pos = content(), { }, 1
    while true do
        local nl = t:find("\n", pos, true)
        if not nl then break end
        lines[#lines + 1] = { off = pos - 1, text = (t:sub(pos, nl - 1):gsub("\r$", "")) }
        pos = nl + 1
    end
    return lines
end

local function sameLines(got, want)
    if #got ~= #want then return false, ("%d lines, wanted %d"):format(#got, #want) end
    for i = 1, #want do
        if got[i].off ~= want[i].off or got[i].text ~= want[i].text then
            return false, ("line %d: %s@%s, wanted %s@%s"):format(
                i, tostring(got[i].text), tostring(got[i].off), want[i].text, want[i].off)
        end
    end
    return true
end

-- Numbered filler lines, `n` of them, each about `width` bytes.
local function filler(tag, n, width)
    local out = { }
    for i = 1, n do
        local s = ("%s %06d "):format(tag, i)
        out[i] = s .. string.rep("x", math.max(0, (width or 80) - #s))
    end
    return table.concat(out, "\n") .. "\n"
end

-- `stale`: a file the engine is not writing, left by an earlier run.
local function NewVM(stale)
    local hooks = { }
    local players = setmetatable({ }, { __index = { GetSize = function(self) return #self end } })
    local env = setmetatable({ }, { __index = _G })
    -- Spark's handle sees the file as it was when it was opened: a line
    -- written after the open is not in what it reads (measured on the rig).
    -- So the fake reads the whole file at open and serves that.
    env.io = { open = function(path, mode)
        local rel = path:match("^config://(.*)$")
        if not rel then return nil, "not a mounted root" end
        local f, err = realOpen(DISK .. "/" .. rel, mode)
        if not f then return nil, err end
        local data = f:read("*a")
        f:close()
        local pos = 0
        return {
            seek = function(_, whence, off)
                off = off or 0
                if whence == "end" then pos = #data + off
                elseif whence == "cur" then pos = pos + off
                else pos = off end
                return pos
            end,
            read = function(_, n)
                if n == "*a" then local t = data:sub(pos + 1); pos = #data; return t end
                if pos >= #data then return nil end
                local t = data:sub(pos + 1, pos + n); pos = pos + #t; return t
            end,
            close = function() end,
        }
    end }
    env.json = dkjson
    env.Script = { Load = function() end }
    env.CreateRingBuffer = function(n)
        local items = { }
        return {
            Insert = function(self, x) table.insert(items, x); if #items > n then table.remove(items, 1) end end,
            GetNumElements = function() return #items end,
            ToTable = function() return items end,
        }
    end
    env.Event = { Hook = function(name, fn) hooks[name] = hooks[name] or { }; table.insert(hooks[name], fn) end }
    env.Shared = {
        -- The engine writes a Shared.Message line to its log before returning
        -- (REQUIREMENTS item 7); into this file unless it is a stale copy.
        Message = function(m) if not stale then append(tostring(m) .. "\n") end end,
        SetWebRoot = function() end,
        GetSystemTime = function() return 1000 end,
        GetSystemTimeReal = function() return 1000 end,
        GetTime = function() return 0 end,
        GetEntitiesWithClassname = function() return players end,
        GetServerPerformanceData = function() return {
            GetTimestamp = function() return 0 end,
            GetDurationMs = function() return 0 end,
        } end,
    }
    env.Server = { GetFrameRate = function() return 60 end }
    local chunk = assert(loadfile(MOD))
    setfenv(chunk, env)
    chunk()

    local vm = { }
    -- The raw body too: what reaches the browser is the bytes dkjson wrote.
    function vm.log(params)
        params.request = "getlog"
        local ctype, body = hooks.WebRequest[1](params)
        return dkjson.decode(body), body, ctype
    end
    return vm
end

local failures = 0
local function check(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

local vm = NewVM()

-- 1. No file: said so, not an empty log.
do
    os.remove(LOG)
    local r, body = vm.log({ })
    check(r.source == "none" and r.path == "config://log-Server.txt" and type(r.error) == "string",
          "no file: source none, the path and the error")
    check(body:find('"lines"') == nil, "no file: no lines key at all")
end

-- 2. A small file: all of it, the header parsed into the file id.
do
    write(header("02:50:11 AM") .. "[  0.000] Main : Filesystem initialized\n\nLinux\n")
    local r, body, ctype = vm.log({ })
    check(ctype == "application/json" and r.source == "file", "a file: source file")
    check(r.file_id == "09/28/2026 02:50:11 AM", "file id from the Date and Time lines")
    check(r.from == 0 and r.at_start == true and r.to == r.size and r.more == false,
          "small file: from 0, at the start, to the end")
    local ok, why = sameLines(r.lines, fileLines())
    check(ok, "small file: every line, with its offset" .. (why and (": " .. why) or ""))
    check(r.lines[6].text == "" and r.lines[7].text == "Linux", "an empty line is kept")
    check(r.tail_bytes == 65536 and r.max_bytes == 65536, "tail and cap stated, 64 KB each")
    check(r.reset == nil, "no reset without a cursor")
end

-- 3. The cursor: nothing new, then a partial line held until it completes.
do
    local r0 = vm.log({ })
    local r = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(#r.lines == 0 and r.from == r0.to and r.to == r0.to and r.more == false,
          "since=end: no lines, the cursor where it was")
    local body = select(2, vm.log({ since = tostring(r0.to), file = r0.file_id }))
    check(body:find('"lines":%[%]') ~= nil, "no lines encoded as []")
    append("Client connecting (0.0.0.0:1234")
    r = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(#r.lines == 0 and r.to == r0.to, "a line with no newline yet is held back")
    append(")\n")
    r = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(#r.lines == 1 and r.lines[1].text == "Client connecting (0.0.0.0:1234)"
          and r.lines[1].off == r0.to and r.to == r0.to + #r.lines[1].text + 1,
          "completed, it arrives whole, at the offset it started")
end

-- 4. A big file: the tail starts at a line and ends at one.
local bigSize
do
    append(filler("round", 3000, 100))
    append("half a li")
    local r = vm.log({ })
    local t = content()
    bigSize = #t
    check(r.from > 0 and r.at_start == false and t:sub(r.from, r.from) == "\n",
          "big file: the tail starts just after a newline")
    check(r.size - r.from <= 65536, "big file: the tail is at most 64 KB")
    check(r.to == r.size - #"half a li", "big file: the partial last line is held")
    local want = { }
    for _, l in ipairs(fileLines()) do if l.off >= r.from then want[#want + 1] = l end end
    local ok, why = sameLines(r.lines, want)
    check(ok, "big file: the tail's lines are the file's" .. (why and (": " .. why) or ""))
    append("ne\n")
end

-- 5. Paging back from the tail reaches the start with every line once.
do
    local r = vm.log({ })
    local pages, got = 0, { }
    for i = #r.lines, 1, -1 do table.insert(got, 1, r.lines[i]) end
    local first = r.from
    while true do
        local p = vm.log({ before = tostring(first), file = r.file_id })
        pages = pages + 1
        check(p.to == first, "page " .. pages .. " ends where the next one starts")
        for i = #p.lines, 1, -1 do table.insert(got, 1, p.lines[i]) end
        first = p.from
        if p.at_start or pages > 20 then break end
    end
    local ok, why = sameLines(got, fileLines())
    check(ok, ("paging back: %d pages, every line exactly once"):format(pages)
          .. (why and (": " .. why) or ""))
end

-- 6. The cap: a burst bigger than one reply is caught up with no gap.
do
    local r0 = vm.log({ })
    append(filler("burst", 7000, 100))
    local cursor, got, replies = r0.to, { }, 0
    local maxBytes = 0
    repeat
        local r = vm.log({ since = tostring(cursor), file = r0.file_id })
        replies = replies + 1
        maxBytes = math.max(maxBytes, r.to - r.from)
        for _, l in ipairs(r.lines) do got[#got + 1] = l end
        cursor = r.to
    until not r.more or replies > 30
    check(replies >= 11 and maxBytes <= 65536, ("burst of 700 KB: %d replies, none over 64 KB"):format(replies))
    local want = { }
    for _, l in ipairs(fileLines()) do if l.off >= r0.to then want[#want + 1] = l end end
    local ok, why = sameLines(got, want)
    check(ok, "burst: every line once, in order" .. (why and (": " .. why) or ""))
end

-- 7. CRLF and bytes that are not UTF-8.
do
    local r0 = vm.log({ })
    append("windows line\r\n" .. "bytes [\233] [\255] [\195\169] [\t] [\1] [\"]\n")
    local r, body = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(#r.lines == 2 and r.lines[1].text == "windows line"
          and r.lines[2].off == r0.to + #"windows line\r\n", "CR dropped, offsets count it")
    check(r.lines[2].text == "bytes [\233] [\255] [\195\169] [\t] [\1] [\"]",
          "odd bytes round-trip through the JSON")
    check(body:find("[\233]", 1, true) ~= nil and body:find("\\u0001", 1, true) ~= nil,
          "invalid UTF-8 passes raw, control bytes are escaped (as dkjson does)")
end

-- 8. One line longer than the cap does not hold the cursor still.
do
    local r0 = vm.log({ })
    append(string.rep("y", 300 * 1024) .. "\n" .. "after\n")
    local r1 = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(#r1.lines == 1 and #r1.lines[1].text == 65536 and r1.more == true,
          "a 300 KB line: the cap's worth served as a line")
    local cursor, replies, r = r1.to, 1, r1
    repeat
        r = vm.log({ since = tostring(cursor), file = r0.file_id })
        replies = replies + 1
        check(r.to > cursor, ("reply %d moves the cursor"):format(replies))
        cursor = r.to
    until not r.more or replies > 10
    check(r.lines[#r.lines].text == "after" and r.more == false and replies == 5,
          ("and the cursor moves on, in 5 replies (%d)"):format(replies))
end

-- 9. A cut file (shorter than the cursor) and a new one (another header).
do
    local r0 = vm.log({ })
    write(header("02:50:11 AM") .. "after the cut\n")
    local r = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(r.reset == "truncated" and r.from == 0 and r.lines[#r.lines].text == "after the cut",
          "shorter than the cursor: reset truncated, and the tail")
    r = vm.log({ before = tostring(r0.to), file = r0.file_id })
    check(r.reset == "truncated", "before beyond the end: reset truncated")

    write(header("03:10:00 AM") .. filler("new", 4000, 100))
    r = vm.log({ since = tostring(r0.to), file = r0.file_id })
    check(r.reset == "new_file" and r.file_id == "09/28/2026 03:10:00 AM",
          "a new header, even longer than the cursor: reset new_file")
    check(r.lines[#r.lines].text:find("^new 004000") ~= nil and r.from > 0,
          "and the reply is the new file's tail")
end

-- 10. Junk parameters read as no cursor.
do
    local r = vm.log({ since = "junk" })
    check(r.reset == nil and r.to == r.size and r.size - r.from <= 65536, "since=junk: the tail")
    r = vm.log({ since = "-5", file = r.file_id })
    check(r.reset == "truncated", "a negative cursor: reset truncated")
end

-- 11. The live check: one marker line per VM, and a stale file refused.
do
    write(header("04:00:00 AM") .. "a line\n")
    local fresh = NewVM()
    local r = fresh.log({ })
    local marks = 0
    for _, l in ipairs(fileLines()) do
        if l.text:find("^webadmin%-spa: checking that config://log%-Server%.txt is this server's log") then marks = marks + 1 end
    end
    check(r.source == "file" and marks == 1, "a live file: one marker line, and the log served")
    check(r.lines[#r.lines].text:find("^webadmin%-spa: checking") ~= nil,
          "the marker is in the first reply (opened after it was written)")
    fresh.log({ })
    fresh.log({ since = tostring(r.to), file = r.file_id })
    marks = 0
    for _, l in ipairs(fileLines()) do if l.text:find("^webadmin%-spa: checking") then marks = marks + 1 end end
    check(marks == 1, "checked once per VM, not per request")

    local old = NewVM(true)
    local st = old.log({ })
    check(st.source == "none" and st.stale == true and st.error:find("does not grow") ~= nil,
          "a stale file: source none, stale, and why")
    check(old.log({ }).stale == true, "and it stays refused for that VM")
    os.remove(LOG)
    local gone = old.log({ })
    check(gone.source == "none" and not gone.stale, "deleted, it reads as missing at once")
end

-- 12. A file with no header: an empty id, and the cursor still works.
do
    write("no header\nsecond\n")
    local r = vm.log({ })
    check(r.file_id == "" and #r.lines == 2, "no header: file id empty")
    local r2 = vm.log({ since = tostring(r.to), file = "" })
    check(r2.reset == nil and #r2.lines == 0, "no header: since works with file=''")
end

os.execute("rm -rf '" .. DISK .. "'")
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

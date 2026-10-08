-- Command-line arguments for the off-rig harnesses and the benchmark.
--
--   local opts, pos = dofile(HERE .. "harness-args.lua")(usage, { "core" })
--
-- `--name value` pairs land in opts, everything else in pos, in order. Each
-- name in `required` must be given, or the usage is printed and the script
-- exits 2. opts.core, the game's core/lua directory (dkjson.lua,
-- RingBuffer.lua), always ends in "/".
return function(usage, required)
    local opts, pos = { }, { }
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a:sub(1, 2) == "--" and arg[i + 1] then
            opts[a:sub(3)] = arg[i + 1]
            i = i + 2
        else
            pos[#pos + 1] = a
            i = i + 1
        end
    end
    for _, name in ipairs(required or { }) do
        if not opts[name] then
            io.stderr:write("usage: luajit " .. arg[0] .. " " .. usage .. "\n")
            os.exit(2)
        end
    end
    if opts.core and opts.core:sub(-1) ~= "/" then opts.core = opts.core .. "/" end
    return opts, pos
end

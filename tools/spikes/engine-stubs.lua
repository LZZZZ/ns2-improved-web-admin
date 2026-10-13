-- The 10-12 engine's calls the shipped file always makes, for the off-rig
-- harnesses and the benchmark. Fills only what a harness has not stubbed
-- itself:
--
--   dofile(HERE .. "engine-stubs.lua")(env, dkjson)
--
-- Shared.JsonEncode is dkjson here. The engine's writer differs where it
-- matters little (docs/CONSTRAINTS.md, "Engine additions"): a sparse array
-- becomes an object, and it refuses deep nesting.
return function(env, dkjson)
    env.Shared = env.Shared or { }
    env.Server = env.Server or { }
    local function fill(t, name, fn)
        if t[name] == nil then t[name] = fn end
    end
    fill(env.Shared, "JsonEncode", function(v) return dkjson.encode(v) end)
    fill(env.Shared, "ReadLog", function() return "", 0 end)
    fill(env.Shared, "CaptureConsoleCommand", function() return "" end)
    fill(env.Server, "GetTickStat", function() return nil end)
    fill(env.Server, "GetIsModWhitelisted", function() return false end)
    fill(env.Server, "GetIsRankingActive", function() return false end)
    fill(env.Server, "GetIsFamilyShared", function() return false end)
    fill(env.Server, "GetOwnerUserId", function() return 0 end)
    fill(env.Server, "GetBwLimit", function() return 131072 end)
    return env
end

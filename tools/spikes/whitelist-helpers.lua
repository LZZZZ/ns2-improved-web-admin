-- whitelist probe (docs/CONSTRAINTS.md item 17): what Shared.SendHTTPRequest hands its callback
-- on success and on each kind of failure, and what
-- ModServices.GetHotfixListModId() returns. The calls run one after the
-- other, never two at once. Top-level, not in the OnWebRequest branch: with
-- this code nested in the branch the engine's Lua preprocessor stopped after
-- OnWebRequest and the rest of the file was dropped (2026-10-08).
local whitelistProbe

local function WhitelistProbeRecord(name, nextStep)
    return function(...)
        local n = select(string.char(35), ...)
        local args = { }
        for k = 1, n do
            local v = select(k, ...)
            args[k] = { type = type(v),
                        len = type(v) == "string" and #v or nil,
                        head = type(v) == "string" and string.sub(v, 1, 80) or tostring(v) }
        end
        whitelistProbe.results[name] = { n = n, args = args,
                                         after = Shared.GetTime() - whitelistProbe.started }
        nextStep()
    end
end

local kWhitelistProbeCalls = {
    { "page", "https://steamcommunity.com/sharedfiles/filedetails/?id=2633436686" },
    { "refused", "https://127.0.0.1:9/" },
    { "nxdomain", "https://webadmin-spa-probe.invalid/" },
    { "http404", "https://steamcommunity.com/webadmin-spa-probe-404" },
}

local function WhitelistProbeStep(i)
    local c = kWhitelistProbeCalls[i]
    if c then
        Shared.SendHTTPRequest(c[2], "GET",
            WhitelistProbeRecord(c[1], function() WhitelistProbeStep(i + 1) end))
        return
    end
    FetchRequiredItems("1", function(ids, why)
        whitelistProbe.results.no_such_item = { ids = ids and #ids, why = why,
            after = Shared.GetTime() - whitelistProbe.started }
        whitelistProbe.done = true
    end)
end

local function WhitelistProbe(reset)
    if whitelistProbe and not reset then return whitelistProbe end
    whitelistProbe = { started = Shared.GetTime(), results = { } }
    local okId, rawId = pcall(ModServices.GetHotfixListModId)
    whitelistProbe.hotfix_list_id_raw = okId and (type(rawId) .. " " .. tostring(rawId))
                                        or ("error " .. tostring(rawId))
    whitelistProbe.hotfix_list_id = GetHotfixListId()
    WhitelistProbeStep(1)
    return whitelistProbe
end


    if actions.request == "whitelistprobe" then
        return "application/json", json.encode(WhitelistProbe(actions.reset ~= nil))
    end

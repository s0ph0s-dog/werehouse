TestScraperProcessUri = function(e)
    return nil, "this should never have been called"
end

local function can_process_uri(uri)
    return uri:startswith("test://")
end

local function process_uri(uri)
    -- This is intentionally a global so that the test harness can replace it.
    return TestScraperProcessUri(uri)
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

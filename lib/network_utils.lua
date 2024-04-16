
FILE_EXT_EXP = assert(re.compile[[\.([a-z0-9]{1,5})$]])

local function FetchJson(uri, options)
    local status, headers, body = Fetch(uri, options)
    if not status then
        return nil, headers
    end
    if status ~= 200 then
        return nil, status
    end
    local json, errmsg = DecodeJson(body)
    if not json then
        return nil, errmsg
    end
    return json
end

local function is_temporary_failure_status(status)
    return (
        status >= 500 and status <= 599
    ) or (
        status == 429
    )
end

local function is_permanent_failure_status(status)
    return (
        status >= 400 and status <= 499
    ) and (
        status ~= 429
    )
end

local function is_success_status(status)
    return (
        status >= 200 and status <= 299
    )
end

local ext_to_mime = {
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
}

local function guess_mime_from_url(url)
    local parts = ParseUrl(url)
    local match, ext = FILE_EXT_EXP:search(parts.path)
    if not match then
        return nil
    end
    local best_guess = ext_to_mime[ext]
    if not best_guess then
        return nil
    end
    return best_guess
end

return {
    FetchJson = FetchJson,
    is_temporary_failure_status = is_temporary_failure_status,
    is_permanent_failure_status = is_permanent_failure_status,
    is_success_status = is_success_status,
    guess_mime_from_url = guess_mime_from_url,
}

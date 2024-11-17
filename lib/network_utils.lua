FILE_EXT_EXP = assert(re.compile([[\.([a-z0-9]{1,5})$]]))

---@return table
---@overload fun(): nil, string
local function FetchJson(uri, options)
    local status, headers, body = Fetch(uri, options)
    if not status then
        Log(kLogVerbose, "TLS error: %s" % { headers })
        return nil, tostring(headers)
    end
    if status ~= 200 then
        Log(
            kLogVerbose,
            "Error %d from %s: Headers%s; Body(%s)"
                % { status, uri, EncodeJson(headers), body }
        )
        return nil, tostring(status)
    end
    local json, errmsg = DecodeJson(body)
    if not json then
        return nil, tostring(errmsg)
    end
    return json
end

local function is_temporary_failure_status(status)
    return (status >= 500 and status <= 599) or (status == 429)
end

local function is_permanent_failure_status(status)
    return (status >= 400 and status <= 499) and (status ~= 429)
end

local function is_success_status(status)
    return (status >= 200 and status <= 299)
end

---@param uri string
---@param options table<string, string>?
---@return string, table
---@overload fun(uri: string, options: table): nil, PipelineError
local function FetchMedia(uri, options)
    local status, headers, body = Fetch(uri, options)
    if not status then
        return nil, PipelineErrorTemporary(headers)
    elseif is_temporary_failure_status(status) then
        return nil, PipelineErrorTemporary(status)
    elseif is_permanent_failure_status(status) then
        return nil, PipelineErrorPermanent(status)
    else
        return body, headers
    end
end

local ext_to_mime = {
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
    gif = "image/gif",
    mp4 = "video/mp4",
    webm = "video/webm",
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
    FetchMedia = FetchMedia,
    is_temporary_failure_status = is_temporary_failure_status,
    is_permanent_failure_status = is_permanent_failure_status,
    is_success_status = is_success_status,
    guess_mime_from_url = guess_mime_from_url,
    ext_to_mime = ext_to_mime,
}

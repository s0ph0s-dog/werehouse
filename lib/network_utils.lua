
function FetchJson(uri, options)
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

return {
    FetchJson = FetchJson
}

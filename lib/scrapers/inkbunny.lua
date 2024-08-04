local IB_URL_EXP = assert(re.compile([[^(https?://)?inkbunny.net/s/([0-9]+)]]))

local RATING_MAP = {
    [0] = DbUtil.k.Rating.General,
    [1] = DbUtil.k.Rating.Adult,
    [2] = DbUtil.k.Rating.Explicit,
}

local IB_USERNAME = os.getenv("IB_USERNAME")
local IB_PASSWORD = os.getenv("IB_PASSWORD")

local CANONICAL_DOMAIN = "inkbunny.net"

local IB_SID = nil

local function ib_login()
    Log(kLogDebug, "Attempting IB login")
    local auth_url = EncodeUrl {
        scheme = "https",
        host = "inkbunny.net",
        path = "/api_login.php",
        params = {
            { "username", IB_USERNAME },
            { "password", IB_PASSWORD },
        },
    }
    local auth_status, auth_headers, auth_body =
        Fetch(auth_url, { method = "POST" })
    Log(
        kLogDebug,
        "IB login response: %s | %s | %s"
            % { tostring(auth_status), EncodeJson(auth_headers), auth_body }
    )
    if auth_status ~= 200 then
        Log(kLogDebug, "IB auth failed with HTTP error")
        return auth_status, auth_headers, auth_body
    end
    local body_json = DecodeJson(auth_body)
    if not body_json then
        Log(kLogDebug, "IB auth failed because JSON was invalid")
        return nil, "Invalid JSON from Inkbunny"
    end
    if not body_json.sid then
        Log(
            kLogDebug,
            "IB auth failed because there was no session ID in the response"
        )
        return nil, "No session ID in Inkbunny login response"
    end
    IB_SID = body_json.sid
    Log(kLogDebug, "IB Session ID: %s" % { IB_SID })
    return true
end

local function IBFetchJson(url_parts, options)
    if not IB_SID then
        local ok, err = ib_login()
        if not ok then
            return nil, err
        end
    end
    if not url_parts.params then
        url_parts.params = {}
    end
    local retry_count = 0
    while retry_count < 2 do
        local offset = 1
        if retry_count > 0 then
            offset = 0
        end
        url_parts.params[#url_parts.params + offset] = { "sid", IB_SID }
        local url = EncodeUrl(url_parts)
        local json, err = Nu.FetchJson(url, options)
        retry_count = retry_count + 1
        if not json then
            return nil, err
        end
        if json.error_code then
            if json.error_code == 1 or json.error_code == 2 then
                local ok, err = ib_login()
                if not ok then
                    return nil, err
                end
            else
                return nil,
                    "Inkbunny said: error %s (%s)" % {
                        tostring(json.error_code),
                        json.error_message,
                    }
            end
        else
            return json
        end
    end
end

local function extract_submission_id(url)
    local match, _, id = IB_URL_EXP:search(url)
    if match then
        return id
    else
        return nil
    end
end

local function can_process_uri(uri)
    return extract_submission_id(uri) ~= nil
end

---@return ScrapedSourceData[]
local function process_json(json)
    local incoming_tags = table.map(json.keywords, function(k)
        return k.keyword_name
    end)
    local rating = RATING_MAP[json.rating_id]
    local artist = {
        handle = json.username,
        display_name = json.username,
        profile_url = "https://inkbunny.net/" .. json.username,
    }
    return table.map(json.files, function(file)
        return {
            kind = DbUtil.k.ImageKind.Image,
            raw_image_uri = file.file_url_full,
            width = file.full_size_x,
            height = file.full_size_y,
            rating = rating,
            authors = { artist },
            incoming_tags = incoming_tags,
            mime_type = file.mimetype,
            canonical_domain = CANONICAL_DOMAIN,
            this_source = "https://inkbunny.net/s/"
                .. tostring(json.submission_id),
        }
    end)
end

local function process_uri(uri)
    if not IB_USERNAME or not IB_PASSWORD then
        return Err(
            PermScraperError(
                "This instance has no Inkbunny credentials. Ask your administrator to provide the IB_USERNAME and IB_PASSWORD environment variables."
            )
        )
    end
    local submission_id = extract_submission_id(uri)
    local api_url_parts = {
        scheme = "https",
        host = "inkbunny.net",
        path = "/api_submissions.php",
        params = {
            { "submission_ids", submission_id },
        },
    }
    local json, err = IBFetchJson(api_url_parts, { method = "POST" })
    if not json then
        return Err(PermScraperError(err))
    end
    if not json.submissions or #json.submissions ~= 1 then
        return Err(
            PermScraperError(
                "This Inkbunny submission is not visible to you. It may have been deleted."
            )
        )
    end
    local result, p_err = process_json(json.submissions[1])
    if result then
        return Ok(result)
    else
        return Err(p_err)
    end
end

return {
    can_process_uri = can_process_uri,
    process_uri = process_uri,
    CANONICAL_DOMAIN = CANONICAL_DOMAIN,
}

local DA_URI_EXP = assert(
    re.compile([[^(https?://)?www.deviantart.com/([a-z0-9])+/art/([A-z0-9-])+]])
)

local DA_CLIENT_ID = os.getenv("DA_CLIENT_ID")
local DA_CLIENT_SECRET = os.getenv("DA_CLIENT_SECRET")
local CANONICAL_DOMAIN = "www.deviantart.com"

local DA_BEARER_TOKEN = nil

local function dA_login()
    local auth_url = EncodeUrl {
        scheme = "https",
        host = "www.deviantart.com",
        path = "/oauth2/token",
        params = {
            { "grant_type", "client_credentials" },
            { "client_id", DA_CLIENT_ID },
            { "client_secret", DA_CLIENT_SECRET },
        },
    }
    local auth_status, auth_headers, auth_body = Fetch(auth_url)
    if auth_status ~= 200 then
        return auth_status, auth_headers, auth_body
    end
    local body_json = DecodeJson(auth_body)
    if not body_json then
        return nil, "Invalid JSON from DeviantArt"
    end
    if body_json.status ~= "success" then
        return nil, body_json.error
    end
    if not body_json.access_token then
        return nil, "No access_token in DeviantArt login response"
    end
    DA_BEARER_TOKEN = body_json.access_token
end

local function DAFetch(url, options)
    if not DA_BEARER_TOKEN then
        dA_login()
    end
    if not options then
        options = {}
    end
    if not options.headers then
        options.headers = {}
    end
    options.headers["Authorization"] = "Bearer %s" % { DA_BEARER_TOKEN }
    local retry_count = 0
    while retry_count < 2 do
        local resp_status, resp_headers, resp_body = Fetch(url, options)
        retry_count = retry_count + 1
        if not resp_status then
            return resp_status, resp_headers
        end
        if resp_status == 401 then
            dA_login()
        elseif resp_status ~= 200 then
            return resp_status, resp_headers, resp_body
        else
            Log(kLogDebug, "DA response body: " .. resp_body)
            local resp_json, json_err = DecodeJson(resp_body)
            if not resp_json then
                return nil, json_err
            end
            return resp_status, resp_headers, resp_json
        end
    end
end

local function FetchAndCheck(fetch_func, url, options)
    local status, headers, body = fetch_func(url, options)
    if not status then
        return nil, PipelineErrorPermanent(headers)
    end
    if Nu.is_temporary_failure_status(status) then
        return nil, PipelineErrorTemporary(status)
    elseif Nu.is_permanent_failure_status(status) then
        return nil, PipelineErrorPermanent(status)
    elseif not Nu.is_success_status(status) then
        return nil, PipelineErrorPermanent(status)
    end
    return status, headers, body
end

local function encode_da_url(path_suffix, params)
    return EncodeUrl {
        scheme = "https",
        host = "www.deviantart.com",
        path = "/api/v1/oauth2" .. path_suffix,
        params = params,
    }
end

local function can_process_uri(uri)
    return DA_URI_EXP:search(uri)
end

local function process_deviation(json, uri)
    return {
        kind = DbUtil.k.ImageKind.Image,
        canonical_domain = CANONICAL_DOMAIN,
        authors = {
            {
                profile_url = "https://www.deviantart.com/"
                    .. json.author.username,
                display_name = json.author.username,
                handle = json.author.username,
            },
        },
        this_source = uri,
        rating = json.is_mature and DbUtil.k.Rating.Adult
            or DbUtil.k.Rating.General,
    }
end

local function process_download(json, result)
    result.media_url = json.src
    result.width = json.width
    result.height = json.height
    return result
end

local function process_metadata(json, result)
    ---@cast result ScrapedSourceData
    result.incoming_tags = table.map(json.metadata[1].tags, function(t)
        return t.tag_name
    end)
    return result
end

local function first(list)
    if not list then
        return nil
    end
    if #list < 1 then
        return nil
    end
    return list[1]
end

local function process_uri(uri)
    if not DA_CLIENT_ID or not DA_CLIENT_SECRET then
        return nil,
            PipelineErrorPermanent(
                "This instance has no DeviantArt credentials. Ask your administrator to provide the DA_CLIENT_ID and DA_CLIENT_SECRET environment variables."
            )
    end
    local status, headers, body = FetchAndCheck(Fetch, uri)
    if not status then
        return headers
    end
    local root = HtmlParser.parse(body, 5000)
    if not root then
        return nil, PipelineErrorPermanent("DeviantArt returned invalid HTML.")
    end
    local appurl_elt = first(root:select("meta[property='da:appurl']"))
    if not appurl_elt or not appurl_elt.attributes.content then
        return nil,
            PipelineErrorPermanent(
                "DeviantArt did not include the da:appurl meta tag in this page, so I can’t determine the post ID."
            )
    end
    local appurl = appurl_elt.attributes.content
    local post_id_with_slash = ParseUrl(appurl).path
    if not post_id_with_slash then
        return nil,
            PipelineErrorPermanent(
                "DeviantArt included an invalid da:appurl meta tag value with no post ID."
            )
    end
    local deviation_url = encode_da_url(
        "/deviation" .. post_id_with_slash,
        { { "with_session", "0" } }
    )
    local dev_status, dev_headers, dev_json =
        FetchAndCheck(DAFetch, deviation_url)
    if not dev_status then
        return dev_headers
    end
    local phase1 = process_deviation(dev_json, uri)
    local download_url =
        encode_da_url("/deviation/download" .. post_id_with_slash)
    local dl_status, dl_headers, dl_json = FetchAndCheck(DAFetch, download_url)
    if not dl_status then
        return dl_headers
    end
    local phase2 = process_download(dl_json, phase1)
    local post_id = post_id_with_slash:sub(2)
    local metadata_url = encode_da_url("/deviation/metadata", {
        { "deviationids", post_id },
        { "ext_submission", "1" },
        { "with_session", "0" },
    })
    local meta_status, meta_headers, meta_json =
        FetchAndCheck(DAFetch, metadata_url)
    if not meta_status then
        return meta_headers
    end
    local phase3 = process_metadata(meta_json, phase2)
    return { phase3 }
end

return {
    can_process_uri = can_process_uri,
    process_uri = process_uri,
}

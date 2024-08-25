WEASYL_URL_EXP = assert(
    re.compile(
        [[^(https?://)?(www.)?weasyl.com/(~[A-z0-9]+/)?(submissions?|view)/([0-9]+)]]
    )
)

WEASYL_API_KEY = os.getenv("WEASYL_API_KEY")

CANONICAL_DOMAIN = "www.weasyl.com"
RATING_MAP = {
    general = DbUtil.k.Rating.General,
    moderate = DbUtil.k.Rating.Adult,
    mature = DbUtil.k.Rating.Adult,
    explicit = DbUtil.k.Rating.Explicit,
}

local function extract_submission_id(url)
    local match, _, _, _, _, id = WEASYL_URL_EXP:search(url)
    if match then
        return id
    else
        return nil
    end
end

local function can_process_uri(uri)
    return extract_submission_id(uri) ~= nil
end

local function process_json(json)
    if not json.owner or not json.owner_login then
        return nil,
            PipelineErrorPermanent(
                "No owner information in Weasyl API response"
            )
    end
    local author = {
        handle = json.owner_login,
        display_name = json.owner,
        profile_url = "https://www.weasyl.com/~" .. json.owner_login,
    }
    if not json.rating then
        return nil, PipelineErrorPermanent("No rating in Weasyl API response")
    end
    local rating = RATING_MAP[json.rating]
    if not json.media.submission then
        return nil,
            PipelineErrorPermanent(
                "No ‘submission’ in Weasyl API response, so full size image is unavailable"
            )
    end
    return table.maperr(json.media.submission, function(m)
        ---@type ScrapedSourceData
        local result = {
            media_url = m.url,
            width = 0,
            height = 0,
            kind = DbUtil.k.ImageKind.Image,
            canonical_domain = CANONICAL_DOMAIN,
            authors = { author },
            this_source = json.link,
            rating = rating,
            incoming_tags = json.tags,
        }
        return result
    end)
end

---@type ScraperProcess
local function process_uri(uri)
    local submission_id = extract_submission_id(uri)
    local api_url = EncodeUrl {
        scheme = "https",
        host = "www.weasyl.com",
        path = "/api/submissions/%d/view" % { submission_id },
    }
    local json, err = Nu.FetchJson(api_url, {
        headers = {
            ["X-Weasyl-API-Key"] = WEASYL_API_KEY,
        },
    })
    if not json then
        return nil, PipelineErrorPermanent(err)
    end
    if not json or not json.link then
        return nil, PipelineErrorPermanent("Invalid response from Weasyl")
    end
    if json.type ~= "submission" or json.subtype ~= "visual" then
        return nil,
            PipelineErrorPermanent(
                "For now, I can only save visual submissions. Characters, literary submissions, and multimedia sumbissions are not supported yet."
            )
    end
    return process_json(json)
end

return {
    can_process_uri = can_process_uri,
    process_uri = process_uri,
    CANONICAL_DOMAIN = CANONICAL_DOMAIN,
}

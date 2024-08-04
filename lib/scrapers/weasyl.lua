WEASYL_URL_EXP = assert(
    re.compile(
        [[^(https?://)?www.weasyl.com/(~[A-z0-9]+/)?(submissions?|view)/([0-9]+)]]
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
    local match, _, _, _, id = WEASYL_URL_EXP:search(url)
    if match then
        return id
    else
        return nil
    end
end

local function can_process_uri(uri)
    return extract_submission_id(uri) ~= nil
end

local function update_image_size(scraped_data)
    if not img then
        Log(
            kLogWarn,
            "img library not available; unable to determine size of image from Weasyl"
        )
        return scraped_data
    end
    local status, headers, body = Fetch(scraped_data.raw_image_uri)
    if status ~= 200 then
        Log(
            kLogWarn,
            "Error %s while downloading image from Weasyl: %s"
                % { tostring(status), body }
        )
        return scraped_data
    end
    local imageu8, img_err = img.loadbuffer(body)
    if not imageu8 then
        Log(kLogInfo, "Failed to load image: %s" % { img_err })
        return scraped_data
    end
    scraped_data.image_data = body
    scraped_data.mime_type = headers["Content-Type"]
    scraped_data.width = imageu8:width()
    scraped_data.height = imageu8:height()
    return scraped_data
end

local function process_json(json)
    if not json.owner or not json.owner_login then
        return nil,
            PermScraperError("No owner information in Weasyl API response")
    end
    local author = {
        handle = json.owner_login,
        display_name = json.owner,
        profile_url = "https://www.weasyl.com/~" .. json.owner_login,
    }
    if not json.rating then
        return nil, PermScraperError("No rating in Weasyl API response")
    end
    local rating = RATING_MAP[json.rating]
    if not json.media.submission then
        return nil,
            PermScraperError(
                "No ‘submission’ in Weasyl API response, so full size image is unavailable"
            )
    end
    return table.map(json.media.submission, function(m)
        return {
            kind = DbUtil.k.ImageKind.Image,
            canonical_domain = CANONICAL_DOMAIN,
            authors = { author },
            this_source = json.link,
            rating = rating,
            raw_image_uri = m.url,
            incoming_tags = json.tags,
        }
    end)
end

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
        return nil, Err(PermScraperError(err))
    end
    if not json or not json.link then
        return Err(PermScraperError("Invalid response from Weasyl"))
    end
    if json.type ~= "submission" or json.subtype ~= "visual" then
        return Err(
            PermScraperError(
                "For now, I can only save visual submissions. Characters, literary submissions, and multimedia sumbissions are not supported yet."
            )
        )
    end
    local result, err = process_json(json)
    if result then
        local fetched_result = table.map(result, update_image_size)
        return Ok(fetched_result)
    else
        return Err(err)
    end
end

return {
    can_process_uri = can_process_uri,
    process_uri = process_uri,
    CANONICAL_DOMAIN = CANONICAL_DOMAIN,
}

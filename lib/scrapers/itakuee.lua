local RATING_MAP = {
    SFW = DbUtil.k.Rating.General,
    NSFW = DbUtil.k.Rating.Explicit,
}

local ITAKUEE_URI_EXP =
    assert(re.compile([[^https?://itaku.ee/images/([0-9]+)]]))
local CANONICAL_DOMAIN = "itaku.ee"

local function match_itakuee_uri(uri)
    local match, post_id = ITAKUEE_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return tonumber(post_id)
end

local function can_process_uri(uri)
    local ok = match_itakuee_uri(uri)
    return ok ~= nil
end

local function map_tags(tags)
    local tag_names = {}
    for i = 1, #tags do
        local tag = tags[i]
        tag_names[#tag_names + 1] = tag.name
        if tag.synonymous_to then
            tag_names[#tag_names + 1] = tag.synonymous_to.name
        end
    end
    return tag_names
end

---@return ScrapedSourceData
local function map_post(post)
    local mime_type = Nu.guess_mime_from_url(post.image)
    if not mime_type then
        -- Hope for the best.
        mime_type = "image/jpeg"
    end
    local tags = map_tags(post.tags)
    return {
        kind = DbUtil.k.ImageKind.Image,
        authors = {
            {
                display_name = post.owner_displayname,
                handle = post.owner_username,
                profile_url = "https://itaku.ee/profile/"
                    .. post.owner_username,
            },
        },
        this_source = "https://itaku.ee/images/%d" % { post.id },
        raw_image_uri = post.image,
        mime_type = mime_type,
        -- These will be filled in later.
        width = 0,
        height = 0,
        canonical_domain = CANONICAL_DOMAIN,
        rating = RATING_MAP[post.maturity_rating],
        incoming_tags = tags,
    }
end

local function update_image_size(scraped_data)
    if not img then
        Log(
            kLogWarn,
            "img library not available; unable to determine size of image from itaku.ee"
        )
        return scraped_data
    end
    local status, headers, body = Fetch(scraped_data.raw_image_uri)
    if status ~= 200 then
        Log(
            kLogWarn,
            "Error %s while downloading image from itaku.ee: %s"
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

local function process_uri(uri)
    local post_id = match_itakuee_uri(uri)
    if not post_id then
        return Err(PermScraperError("Unsupported itaku.ee URL"))
    end
    local api_url = EncodeUrl {
        scheme = "https",
        host = "itaku.ee",
        path = "/api/galleries/images/%d/" % { post_id },
        params = {
            { "format", "json" },
        },
    }
    local json, fetch_err = Nu.FetchJson(api_url)
    if not json then
        return Err(PermScraperError(fetch_err))
    end
    local scraped_data = map_post(json)
    scraped_data = update_image_size(scraped_data)
    return Ok { scraped_data }
end

return {
    can_process_uri = can_process_uri,
    process_uri = process_uri,
}

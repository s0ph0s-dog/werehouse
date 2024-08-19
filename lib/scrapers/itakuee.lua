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
---@overload fun(post: table): nil, PipelineError
local function map_post(post)
    local tags = map_tags(post.tags)
    ---@type ScrapedSourceData
    local result = {
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
        media_url = post.image,
        width = 0,
        height = 0,
        canonical_domain = CANONICAL_DOMAIN,
        rating = RATING_MAP[post.maturity_rating],
        incoming_tags = tags,
    }
    return { result }
end

local function process_uri(uri)
    local post_id = match_itakuee_uri(uri)
    if not post_id then
        return nil, PipelineErrorPermanent("Unsupported itaku.ee URL")
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
        return nil, PipelineErrorPermanent(fetch_err)
    end
    return map_post(json)
end

return {
    can_process_uri = can_process_uri,
    process_uri = process_uri,
}

-- This scraper implements the Mastodon Client API v1, not ActivityPub.
local MASTO_PATH_EXP = assert(re.compile([[^/@[A-z0-9_-]+/([0-9]+)]]))
local TYPE_TO_KIND_MAP = {
    image = DbUtil.k.ImageKind.Image,
    gifv = DbUtil.k.ImageKind.Animation,
    video = DbUtil.k.ImageKind.Video,
}

local function match_mastodon_uri(uri)
    local parts = ParseUrl(uri)
    local match, status_id = MASTO_PATH_EXP:search(parts.path)
    if not match then
        return nil
    end
    return parts.host, tonumber(status_id)
end

local function can_process_uri(uri)
    local ok = match_mastodon_uri(uri)
    return ok ~= nil
end

local function process_account(account)
    if not account.username or not account.display_name or not account.url then
        return nil
    end
    return {
        handle = account.username,
        profile_url = account.url,
        display_name = account.display_name,
    }
end

local function process_meta_kind(kind)
    return function(meta, key, default)
        return meta and meta[kind] and meta[kind][key] or default
    end
end

local process_meta_original = process_meta_kind("original")
local process_meta_small = process_meta_kind("small")

local function make_thumbnail(item)
    return {
        raw_uri = item.preview_url,
        height = process_meta_small(item.meta, "height", 0),
        width = process_meta_small(item.meta, "width", 0),
        scale = 1,
    }
end

---@param post table
---@param account ScrapedAuthor
---@param domain string
---@return ScrapedSourceData[]
---@overload fun(table, ScrapedAuthor, string): nil, PipelineError
local function process_media(post, account, domain)
    local supported_attachments = table.filter(
        post.media_attachments,
        function(item)
            return TYPE_TO_KIND_MAP[item.type] ~= nil
        end
    )
    if #supported_attachments == 0 then
        return nil, PipelineErrorPermanent("No attached files on this post")
    end
    return table.maperr(supported_attachments, function(item)
        local tags = nil
        if post.tags then
            tags = table.map(post.tags, function(t)
                return t.name
            end)
        end
        ---@type ScrapedSourceData
        local result = {
            kind = TYPE_TO_KIND_MAP[item.type],
            authors = { account },
            this_source = post.url,
            media_url = item.url,
            height = process_meta_original(item.meta, "height", 0),
            width = process_meta_original(item.meta, "width", 0),
            canonical_domain = domain,
            rating = post.sensitive and DbUtil.k.Rating.Explicit
                or DbUtil.k.Rating.General,
            incoming_tags = tags,
            thumbnails = { make_thumbnail(item) },
        }
        return result
    end)
end

---@type ScraperProcess
local function process_uri(uri)
    local domain, status_id = match_mastodon_uri(uri)
    if not domain then
        return nil, PipelineErrorPermanent("Not a Mastodon URL.")
    end
    local api_url = EncodeUrl {
        scheme = "https",
        host = domain,
        path = "/api/v1/statuses/%d" % { status_id },
    }
    local json, errmsg1 = Nu.FetchJson(api_url)
    if not json then
        if errmsg1 == 404 then
            return nil,
                PipelineErrorPermanent(
                    "That post was deleted, or the server does not implement the Mastodon Client v1 API, so I can't scrape it."
                )
        elseif errmsg1 == 401 then
            return nil,
                PipelineErrorPermanent(
                    "The Mastodon instance operator has turned on Authorized Fetch, which blocks me from scraping it."
                )
        end
        -- TODO: some of these are probably not permanent (e.g. 502, 429)
        return nil, PipelineErrorPermanent(errmsg1)
    end
    if not json.account then
        return nil,
            PipelineErrorPermanent(
                "The `account` field was missing from the API response, so I can't tell who posted it."
            )
    end
    local account = process_account(json.account)
    if not json.media_attachments or #json.media_attachments == 0 then
        return nil, PipelineErrorPermanent("This post has no attached media.")
    end
    return process_media(json, account, domain)
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

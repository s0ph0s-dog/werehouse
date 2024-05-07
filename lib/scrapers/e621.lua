local ALLOWED_EXTS = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
}
local CANONICAL_DOMAIN = "e621.net"

local function can_process_uri(uri)
    local parts = ParseUrl(uri)
    return parts.host == "e621.net" or parts.host == "e926.net"
end

local function is_user_page(source)
    if source:find("furaffinity%.net/user/") then
        return false
    end
    -- Twitter page without /status/snowflake
    if source:find("twitter.com/[A-z0-9_]+/?$") then
        return false
    end
    -- Ditto for x.com
    if source:find("x.com/[A-z0-9_]+/?$") then
        return false
    end
    return true
end

local function filter_user_pages(sources)
    return table.filter(sources, is_user_page)
end

local function process_post(json, clean_uri, pool_uri)
    if json.post.flags and json.post.flags.deleted then
        return Err(PermScraperError("This post was deleted"))
    end
    local file = json.post.file
    if not file then
        return Err(
            PermScraperError("The e621 API didn't give me a file for the post")
        )
    end
    if not file.url then
        return Err(
            PermScraperError("The e621 API gave me a post file with no URL")
        )
    end
    if not ALLOWED_EXTS[file.ext] then
        return Err(
            PermScraperError(
                "This post is a %s, which isn't supported yet" % { file.ext }
            )
        )
    end
    local additional_sources = json.post.sources
    if not additional_sources then
        additional_sources = {}
    end
    additional_sources = filter_user_pages(additional_sources)
    if pool_uri then
        table.insert(additional_sources, pool_uri)
    end
    local artist_tags = json.post.tags.artist
    if not artist_tags or type(artist_tags) ~= "table" then
        artist_tags = {}
    end
    artist_tags = table.filter(artist_tags, function(x)
        return x ~= "third-party_edit"
    end)
    ---@cast artist_tags string[]
    local authors = table.map(artist_tags, function(item)
        return {
            display_name = item,
            handle = item,
            profile_url = EncodeUrl {
                scheme = "https",
                host = "e621.net",
                path = "/posts",
                params = {
                    { "tags", tostring(item) },
                },
            },
        }
    end)
    return Ok {
        {
            raw_image_uri = file.url,
            width = file.width,
            height = file.height,
            this_source = clean_uri,
            additional_sources = additional_sources,
            mime_type = Nu.ext_to_mime[file.ext],
            canonical_domain = CANONICAL_DOMAIN,
            authors = authors,
        },
    }
end

local function process_pool(json, clean_uri)
    local result = {}
    for _, post_id in ipairs(json.post_ids) do
        local post_uri = EncodeUrl {
            scheme = "https",
            host = "e621.net",
            path = "/posts/" .. post_id .. ".json",
        }
        local clean_post_uri = post_uri:sub(1, #post_uri - 5)
        -- Be kind to e6's servers
        Sleep(0.2)
        local post_json, errmsg = Nu.FetchJson(post_uri)
        if not post_json then
            return Err(PermScraperError(errmsg))
        end
        if not post_json.post then
            return Err(PermScraperError("The e621 API didn't give me a post"))
        end
        local post_result = process_post(post_json, clean_post_uri, clean_uri)
        assert(post_result, "post result was nil for " .. post_uri)
        table.insert(result, post_result)
    end
    local all_posts = table.collect(result)
    local fixed = all_posts:map(table.flatten)
    return fixed
end

---@return Result<ScrapedSourceData, ScraperError>
local function process_uri(uri)
    local parts = ParseUrl(uri)
    parts.path = parts.path .. ".json"
    local new_uri = EncodeUrl(parts)
    local clean_parts = ParseUrl(uri)
    clean_parts.params = nil
    local clean_uri = EncodeUrl(clean_parts)
    local json, errmsg = Nu.FetchJson(new_uri)
    if not json then
        return Err(PermScraperError(errmsg))
    end
    if json.post then
        return process_post(json, clean_uri)
    elseif json.post_ids then
        return process_pool(json, clean_uri)
    else
        return Err(
            PermScraperError("The e621 API didn't give me a post or a pool")
        )
    end
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

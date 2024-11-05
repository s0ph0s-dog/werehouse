local ALLOWED_EXTS = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
    webm = true,
}
local RATING_MAP = {
    s = DbUtil.k.Rating.General,
    q = DbUtil.k.Rating.Adult,
    e = DbUtil.k.Rating.Explicit,
}
local EXT_TO_KIND_MAP = {
    webm = DbUtil.k.ImageKind.Video,
    jpg = DbUtil.k.ImageKind.Image,
    png = DbUtil.k.ImageKind.Image,
    jpeg = DbUtil.k.ImageKind.Image,
    gif = DbUtil.k.ImageKind.Image,
}
local CANONICAL_DOMAIN = "e621.net"
local E621_USERNAME = os.getenv("E621_USERNAME")
local E621_API_KEY = os.getenv("E621_API_KEY")
local E621_TOKEN = nil
if E621_USERNAME and E621_API_KEY then
    E621_TOKEN = EncodeBase64("%s:%s" % { E621_USERNAME, E621_API_KEY })
end

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

local function make_thumbnail(post)
    if post.preview then
        return {
            {
                raw_uri = post.preview.url,
                width = post.preview.width,
                height = post.preview.height,
                scale = 1,
            },
        }
    else
        return nil
    end
end

local function process_post(json, clean_uri, pool_uri)
    if json.post.flags and json.post.flags.deleted then
        return nil, PipelineErrorPermanent("This post was deleted")
    end
    local file = json.post.file
    if not file then
        return nil,
            PipelineErrorPermanent(
                "The e621 API didn't give me a file for the post"
            )
    end
    if not file.url then
        return nil,
            PipelineErrorPermanent(
                "The e621 API gave me a post file with no URL"
            )
    end
    if not ALLOWED_EXTS[file.ext] then
        return nil,
            PipelineErrorPermanent(
                "This post is a %s, which isn't supported yet" % { file.ext }
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
            and x ~= "conditional_dnp"
            and x ~= "sound_warning"
    end)
    local incoming_tags = table.filter(
        table.flatten {
            json.post.tags.general,
            json.post.tags.copyright,
            json.post.tags.character,
            json.post.tags.species,
            json.post.tags.meta,
            json.post.tags.lore,
        },
        function(x)
            return type(x) == "string"
        end
    )
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
    ---@type ScrapedSourceData
    local result = {
        kind = EXT_TO_KIND_MAP[file.ext],
        media_url = file.url,
        width = file.width,
        height = file.height,
        this_source = clean_uri,
        additional_sources = additional_sources,
        canonical_domain = CANONICAL_DOMAIN,
        authors = authors,
        rating = RATING_MAP[json.post.rating],
        incoming_tags = incoming_tags,
        thumbnails = make_thumbnail(json.post),
    }
    return { result }
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
        local headers = {}
        if E621_TOKEN then
            headers.Authorization = "Bearer " .. E621_TOKEN
        end
        local post_json, errmsg = Nu.FetchJson(post_uri, {
            headers = headers,
        })
        if not post_json then
            return nil, PipelineErrorPermanent(errmsg)
        end
        if not post_json.post then
            return nil,
                PipelineErrorPermanent("The e621 API didn't give me a post")
        end
        local post_result, post_err =
            process_post(post_json, clean_post_uri, clean_uri)
        if not post_result or not post_result[1] then
            return nil, post_err
        end
        table.insert(result, post_result[1])
    end
    return result
end

---@type ScraperNormalize
local function normalize_uri(uri)
    local parts = ParseUrl(uri)
    if parts.host ~= "e621.net" and parts.host ~= "e926.net" then
        return uri
    end
    -- Require HTTPS
    parts.scheme = "https"
    -- E621 doesn't use the params for anything other than optional data on pool/post pages
    parts.params = nil
    -- Rewrite old e621 URLs.
    -- (e6 redirects post/show/xxx.json to posts/xxx, stripping the json, and
    -- breaking the request.)
    parts.path = parts.path:gsub("/post/show/", "/posts/")
    -- Strip all trailing slashes
    if parts.path:endswith("/") then
        parts.path = parts.path:gsub("/+$", "")
    end
    Log(kLogDebug, "parts.path = " .. parts.path)
    return EncodeUrl(parts)
end

---@type ScraperProcess
local function process_uri(uri)
    local clean_uri = normalize_uri(uri)
    local api_uri = clean_uri .. ".json"
    local headers = {}
    if E621_TOKEN then
        headers.Authorization = "Bearer " .. E621_TOKEN
    end
    local json, errmsg = Nu.FetchJson(api_uri, {
        headers = headers,
    })
    if not json then
        return nil, PipelineErrorPermanent(errmsg)
    end
    if json.post then
        return process_post(json, clean_uri)
    elseif json.post_ids then
        return process_pool(json, clean_uri)
    else
        return nil,
            PipelineErrorPermanent(
                "The e621 API didn't give me a post or a pool"
            )
    end
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
}

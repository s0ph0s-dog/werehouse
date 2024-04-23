local ALLOWED_EXTS = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
}
local CANONICAL_DOMAIN = "e621.net"

local function can_process_uri(uri)
    local parts = ParseUrl(uri)
    return parts.host == "e621.net"
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
    if not json.post then
        return Err(PermScraperError("The e621 API didn't give me a post"))
    end
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
    local artist_tags = json.post.tags.artist
    if not artist_tags or type(artist_tags) ~= "table" then
        artist_tags = {}
    end
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

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

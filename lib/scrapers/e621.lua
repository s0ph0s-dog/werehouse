
local ALLOWED_EXTS = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
}

local function can_process_uri(uri)
    local parts = ParseUrl(uri)
    return parts.host == "e621.net"
end

---@return Result<ScrapedSourceData, ScraperError>
local function process_uri(uri)
    local parts = ParseUrl(uri)
    parts.path = parts.path .. ".json"
    local new_uri = EncodeUrl(parts)
    local json, errmsg = Nu.FetchJson(new_uri)
    if not json then
        return Err(PermScraperError(errmsg))
    end
    if not json.post then
        return Err(PermScraperError("The e621 API didn't give me a post"))
    end
    local file = json.post.file
    if not file then
        return Err(PermScraperError("The e621 API didn't give me a file for the post"))
    end
    if not file.url then
        return Err(PermScraperError("The e621 API gave me a post file with no URL"))
    end
    if not ALLOWED_EXTS[file.ext] then
        return Err(PermScraperError("This post is a %s, which isn't supported yet" % {file.ext}))
    end
    return Ok({
        raw_image_uri = file.url,
        width = file.width,
        height = file.height,
        mime_type = Nu.ext_to_mime[file.ext]
    })
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

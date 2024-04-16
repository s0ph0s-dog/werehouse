
BSKY_URI_EXP = assert(re.compile[[^https?://[bp]sky\.app/profile/([A-z0-9\.:]+)/post/([a-z0-9]+)]])
---@param uri string
---@return string?
---@return string|re.Errno
local function parse_bsky_uri(uri)
    local match, handle_or_did, post_id = BSKY_URI_EXP:search(uri)
    if not match or type(handle_or_did) == "re.Errno" then
        return nil, handle_or_did
    end
    return handle_or_did, post_id
end

local function extract_image_embeds(post_data)
    if not post_data then
        Log(kLogVerbose, "Post was nil")
        return nil
    end
    if not post_data.value then
        Log(kLogVerbose, "Post value was nil")
        return nil
    end
    if not post_data.value.embed then
        Log(kLogVerbose, "Post embed was nil")
        return nil
    end
    local embed_type = post_data.value.embed["$type"]
    if not embed_type or (
        embed_type ~= "app.bsky.embed.images"
        and embed_type ~= "app.bsky.embed.recordWithMedia"
    ) then
        Log(kLogVerbose, "Post embed was not an image.")
        return nil
    end
    local embed_images = post_data.value.embed.images
    if not embed_images then
        return nil
    end
    return embed_images
end

local function make_image_uri(handle_or_did, image_ref)
    return string.format(
        "https://cdn.bsky.app/img/feed_thumbnail/plain/%s/%s@%s",
        handle_or_did,
        image_ref,
        "jpeg"
    )
end

-- TODO: parse at:// URIs too

---@return Result<ScrapedSourceData, string>
local function process_uri(uri)
    local handle_or_did, post_id = parse_bsky_uri(uri)
    if not handle_or_did or type(post_id) == "re.Errno" then
        return Err(PermScraperError("Invalid Bluesky post URI"))
    end
    local xrpc_uri = EncodeUrl{
        scheme = "https",
        host = "bsky.social",
        path = "/xrpc/com.atproto.repo.getRecord",
        params = {
            { "repo", handle_or_did },
            { "collection", "app.bsky.feed.post" },
            { "rkey", post_id },
        },
    }
    local json, errmsg = Nu.FetchJson(xrpc_uri)
    if not json then
        return Err(TempScraperError(errmsg))
    end
    local images = extract_image_embeds(json)
    if not images then
        return Err(PermScraperError("Post had no images"))
    end
    local results = table.map(images,
        ---@return ScrapedSourceData
        function (image)
        if not image then
            Log(kLogInfo, "Image was null")
            return nil
        end
        if not image.image then
            Log(kLogInfo, "Image.image was null")
            return nil
        end
        if not image.image.ref then
            Log(kLogInfo, "Image.image.ref was null")
            return nil
        end
        if not image.aspectRatio then
            Log(kLogInfo, "Image.aspectRatio was null")
            return nil
        end
        return {
            raw_image_uri = make_image_uri(handle_or_did, image.image.ref["$link"]),
            mime_type = image.image.mimeType,
            width = image.aspectRatio.width,
            height = image.aspectRatio.height,
        }
    end)
    return Ok(results)
end

local function can_process_uri(uri)
    if uri:startswith("at://") then
        return true
    end
    if uri:find("^https?://[bp]sky%.app/") then
        return true
    end
    return false
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

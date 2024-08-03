local BSKY_URI_EXP = assert(
    re.compile(
        [[^(https?://)?[bp]sky\.app/profile/([A-z0-9\.:]+)/post/([a-z0-9]+)]]
    )
)
local BSKY_DID_EXP = assert(re.compile([[^at://([A-z0-9:]+)/]]))
local CANONICAL_DOMAIN = "bsky.app"

---@param uri string
---@return string?
---@return string|re.Errno
local function parse_bsky_uri(uri)
    local match, _, handle_or_did, post_id = BSKY_URI_EXP:search(uri)
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
    if
        not embed_type
        or (
            embed_type ~= "app.bsky.embed.images"
            and embed_type ~= "app.bsky.embed.recordWithMedia"
        )
    then
        Log(kLogVerbose, "Post embed was not an image.")
        return nil
    end
    local embed_images = post_data.value.embed.images
        or post_data.value.embed.media.images
    if not embed_images then
        return nil
    end
    return embed_images
end

local function make_image_uri(handle_or_did, image_ref)
    local parts = {
        scheme = "https",
        host = "bsky.social",
        path = "/xrpc/com.atproto.sync.getBlob",
        params = {
            { "did", handle_or_did },
            { "cid", image_ref },
        },
    }
    return EncodeUrl(parts)
end

local function get_artist_profile(post_uri, handle_or_did, did)
    local handle = handle_or_did
    if did == handle_or_did then
        local xrpc_user_uri = EncodeUrl {
            scheme = "https",
            host = "bsky.social",
            path = "/xrpc/com.atproto.repo.describeRepo",
            params = {
                { "repo", did },
            },
        }
        local repo_json, errmsg3 = Nu.FetchJson(xrpc_user_uri)
        if not repo_json then
            return nil, TempScraperError(errmsg3)
        end
        if not repo_json.handle or type(repo_json.handle) ~= "string" then
            return nil, TempScraperError("No handle?")
        end
        handle = repo_json.handle
    end
    local xrpc_profile_uri = EncodeUrl {
        scheme = "https",
        host = "bsky.social",
        path = "/xrpc/com.atproto.repo.listRecords",
        params = {
            { "repo", handle_or_did },
            { "collection", "app.bsky.actor.profile" },
            { "limit", "1" },
        },
    }
    local user_json, errmsg2 = Nu.FetchJson(xrpc_profile_uri)
    if not user_json then
        return nil, TempScraperError(errmsg2)
    end
    if not user_json.records[1] then
        return nil, PermScraperError("Missing profile")
    end
    local displayName = user_json.records[1].value.displayName
    if not displayName then
        return nil, PermScraperError("No display name")
    end
    local profile_url = EncodeUrl {
        scheme = "https",
        host = "bsky.app",
        path = "/profile/" .. did,
    }
    return {
        handle = handle,
        profile_url = profile_url,
        display_name = displayName,
    }
end

-- TODO: parse at:// URIs too

---@return Result<ScrapedSourceData, string>
local function process_uri(uri)
    local handle_or_did, post_id = parse_bsky_uri(uri)
    if not handle_or_did or type(post_id) == "re.Errno" then
        return Err(PermScraperError("Invalid Bluesky post URI"))
    end
    local xrpc_uri = EncodeUrl {
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
    local match, did = BSKY_DID_EXP:search(json.uri)
    if not match or type(did) == "re.Errno" then
        return nil, PermScraperError("Invalid bsky post URI??")
    end
    local artist, errmsg2 = get_artist_profile(json.uri, handle_or_did, did)
    if not artist then
        return Err(errmsg2)
    end
    local results = table.map(
        images,
        ---@return ScrapedSourceData
        function(image)
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
            local aspectRatio = image.aspectRatio
            if not aspectRatio then
                -- This is apparently not required. Assume 0 for both. This will get chosen last among available sources, which is maybe not the best choice, but I don't want to download the image and compute the size myself yet.
                aspectRatio = {
                    width = 0,
                    height = 0,
                }
            end
            return {
                kind = DbUtil.k.ImageKind.Image,
                raw_image_uri = make_image_uri(did, image.image.ref["$link"]),
                mime_type = image.image.mimeType,
                width = aspectRatio.width,
                height = aspectRatio.height,
                canonical_domain = CANONICAL_DOMAIN,
                this_source = uri,
                authors = { artist },
            }
        end
    )
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

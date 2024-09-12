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

local function normalize_uri(uri)
    local handle_or_did, post_id = parse_bsky_uri(uri)
    if not handle_or_did then
        return uri
    end
    return "https://bsky.app/profile/%s/post/%s" % { handle_or_did, post_id }
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
            and embed_type ~= "app.bsky.embed.video"
        )
    then
        Log(kLogVerbose, "Post embed was not an image or video.")
        return nil
    end
    local embed_media = post_data.value.embed.images
        or post_data.value.embed.video
        or post_data.value.embed.media.images
        or post_data.value.embed.media.video
    if not embed_media then
        return nil
    end
    if #embed_media < 1 then
        local ar = post_data.value.embed.aspectRatio
        if ar then
            embed_media.aspectRatio = ar
        end
        return { embed_media }
    end
    return embed_media
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
            return nil, PipelineErrorTemporary(errmsg3)
        end
        if not repo_json.handle or type(repo_json.handle) ~= "string" then
            return nil, PipelineErrorTemporary("No handle?")
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
        return nil, PipelineErrorTemporary(errmsg2)
    end
    if not user_json.records[1] then
        return nil, PipelineErrorPermanent("Missing profile")
    end
    local displayName = user_json.records[1].value.displayName
    if not displayName then
        return nil, PipelineErrorPermanent("No display name")
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

---@param image table Bluesky image embed
---@param did string Bluesky DID of user who posted
---@param uri string Bluesky URI for post
---@param artist ScrapedAuthor Author object for the user who posted
---@return ScrapedSourceData
---@overload fun(image: table, did: string, uri: string, artist: ScrapedAuthor): nil, PipelineError
local function process_image(image, did, uri, artist)
    if not image then
        return nil, PipelineErrorPermanent("image was null")
    end
    local aspectRatio = image.aspectRatio
    if not aspectRatio then
        -- This is apparently not required. Assume 0 for both. The later stages of the pipeline will download the image and update the sizes.
        aspectRatio = {
            width = 0,
            height = 0,
        }
    end
    if image.mimeType == "video/mp4" then
        if not image.ref then
            return nil, PipelineErrorPermanent("Video.ref was null")
        end
        local video_uri = make_image_uri(did, image.ref["$link"])
        ---@type ScrapedSourceData
        local data = {
            kind = DbUtil.k.ImageKind.Video,
            rating = DbUtil.k.Rating.General,
            media_url = video_uri,
            mime_type = image.mimeType,
            width = aspectRatio.width,
            height = aspectRatio.height,
            canonical_domain = CANONICAL_DOMAIN,
            this_source = uri,
            authors = { artist },
            thumbnails = {
                {
                    raw_uri = EncodeUrl {
                        scheme = "https",
                        host = "video.bsky.app",
                        path = "/watch/%s/%s/thumbnail.jpg"
                            % {
                                did,
                                image.ref["$link"],
                            },
                    },
                    mime_type = "image/jpeg",
                    width = 0,
                    height = 0,
                    scale = 1,
                },
            },
        }
        return data
    else
        if not image.image then
            return nil, PipelineErrorPermanent("Image.image was null")
        end
        if not image.image.ref then
            return nil, PipelineErrorPermanent("Image.image.ref was null")
        end
        local image_uri = make_image_uri(did, image.image.ref["$link"])
        ---@type ScrapedSourceData
        local data = {
            kind = DbUtil.k.ImageKind.Image,
            rating = DbUtil.k.Rating.General,
            media_url = image_uri,
            mime_type = image.image.mimeType,
            width = aspectRatio.width,
            height = aspectRatio.height,
            canonical_domain = CANONICAL_DOMAIN,
            this_source = uri,
            authors = { artist },
        }
        return data
    end
end

---@type ScraperProcess
local function process_uri(uri)
    local handle_or_did, post_id = parse_bsky_uri(uri)
    if not handle_or_did or type(post_id) == "re.Errno" then
        return nil, PipelineErrorPermanent("Invalid Bluesky post URI")
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
        return nil, PipelineErrorTemporary(errmsg)
    end
    local images = extract_image_embeds(json)
    if not images then
        return nil, PipelineErrorPermanent("Post had no images or video")
    end
    if not json.uri or type(json.uri) ~= "string" then
        return nil,
            PipelineErrorPermanent(
                "Bluesky API didn't provide a URI for this post?"
            )
    end
    local match, did = BSKY_DID_EXP:search(json.uri)
    if not match or type(did) == "re.Errno" then
        return nil, PipelineErrorPermanent("Invalid bsky post URI??")
    end
    local artist, errmsg2 = get_artist_profile(json.uri, handle_or_did, did)
    if not artist then
        return nil, errmsg2
    end
    return table.maperr(images, function(image)
        return process_image(image, did, uri, artist)
    end)
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
    normalize_uri = normalize_uri,
}

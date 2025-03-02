local BSKY_URI_EXP = assert(
    re.compile(
        [[^(https?://)?(bsky|cbsky|psky|fxbsky|bskye)\.app/profile/([^/#?]+)/post/([a-z0-9]+)]]
    )
)
local CANONICAL_DOMAIN = "bsky.app"

---@param uri string
---@return string?
---@return string|re.Errno
local function parse_bsky_uri(uri)
    local match, _, _, handle_or_did, post_id = BSKY_URI_EXP:search(uri)
    if not match or type(handle_or_did) == "re.Errno" then
        return nil, handle_or_did
    end
    return handle_or_did, post_id
end

local function handle_to_did(handle)
    if handle:startswith("did:") then
        return handle
    end
    local req_url = EncodeUrl {
        scheme = "https",
        host = "public.api.bsky.app",
        path = "/xrpc/com.atproto.identity.resolveHandle",
        params = {
            { "handle", handle },
        },
    }
    local resp_json, err = Nu.FetchJson(req_url)
    if not resp_json then
        return nil, err
    end
    if not resp_json.did then
        return nil, "No DID in handle lookup response from Bluesky"
    end
    return resp_json.did
end

local function normalize_uri(uri)
    local handle_or_did, post_id = parse_bsky_uri(uri)
    if not handle_or_did then
        return uri
    end
    local did, did_err = handle_to_did(handle_or_did)
    if not did then
        Log(
            kLogVerbose,
            "Unable to get DID for '%s': %s" % { handle_or_did, did_err }
        )
        return uri
    end
    return "https://bsky.app/profile/%s/post/%s" % { did, post_id }
end

local function extract_image_embeds(post_data)
    if not post_data then
        Log(kLogVerbose, "Post was nil")
        return nil
    end
    if not post_data.record then
        Log(kLogVerbose, "Post record was nil")
        return nil
    end
    if not post_data.record.embed then
        Log(kLogVerbose, "Post embed was nil")
        return nil
    end
    local embed_type = post_data.record.embed["$type"]
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
    local embed_media = post_data.record.embed.images
        or post_data.record.embed.video
        or post_data.record.embed.media.images
        or post_data.record.embed.media.video
    if not embed_media then
        return nil
    end
    if #embed_media < 1 then
        local ar = post_data.record.embed.aspectRatio
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

-- TODO: parse at:// URIs too

---@param image table Bluesky image embed
---@param did string Bluesky DID of user who posted
---@param uri string Bluesky URI for post
---@param artist ScrapedAuthor Author object for the user who posted
---@param rating integer Rating of the post (value of DbUtil.k.Rating enum)
---@return ScrapedSourceData
---@overload fun(image: table, did: string, uri: string, artist: ScrapedAuthor, rating: integer): nil, PipelineError
local function process_image(image, did, uri, artist, rating)
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
            rating = rating,
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
            rating = rating,
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

local label_map = {
    porn = DbUtil.k.Rating.Explicit,
    sexual = DbUtil.k.Rating.Explicit,
    ["sexual-figurative"] = DbUtil.k.Rating.Explicit,
}

---@param labels table ATProto SelfLabels
---@return integer # a value of the DbUtil.k.Rating enum
local function guess_rating_from_labels(labels)
    if not labels then
        return DbUtil.k.Rating.General
    end
    for i = 1, #labels do
        local lbl = labels[i]
        if lbl and lbl.val then
            return label_map[lbl.val]
        end
    end
    return DbUtil.k.Rating.General
end

---@param bsky_author table
---@return ScrapedAuthor
local function map_author(bsky_author)
    ---@type ScrapedAuthor
    return {
        handle = bsky_author.handle or "invalid.handle",
        display_name = bsky_author.displayName
            or bsky_author.handle
            or "Unknown User",
        profile_url = "https://bsky.app/profile/"
            .. EscapeSegment(bsky_author.did),
    }
end

---@type ScraperProcess
local function process_uri(uri)
    -- Normalize URI to at://did/app.bsky.feed.post/id
    local handle_or_did, post_id = parse_bsky_uri(uri)
    if not handle_or_did or type(post_id) == "re.Errno" then
        return nil, PipelineErrorPermanent("Invalid Bluesky post URI")
    end
    local did, did_err = handle_to_did(handle_or_did)
    if not did then
        return nil, PipelineErrorPermanent(did_err)
    end
    local post_at_uri = "at://%s/app.bsky.feed.post/%s"
        % {
            did,
            post_id,
        }
    local post_uri = "https://bsky.app/profile/%s/post/%s"
        % {
            EscapeSegment(did),
            EscapeSegment(post_id),
        }
    -- Fetch post info
    local xrpc_uri = EncodeUrl {
        scheme = "https",
        host = "public.api.bsky.app",
        path = "/xrpc/app.bsky.feed.getPosts",
        params = {
            { "uris", post_at_uri },
        },
    }
    local json, errmsg = Nu.FetchJson(xrpc_uri)
    if not json then
        return nil, PipelineErrorTemporary(errmsg)
    end
    if not json.posts or #json.posts == 0 then
        return nil, PipelineErrorPermanent("This post could not be found.")
    end
    local post_data = json.posts[1]
    -- Determine artist
    local author = map_author(post_data.author)
    -- Determine rating from labels
    local rating = guess_rating_from_labels(post_data.labels)
    -- Map embeds to ScrapedSourceData
    local images = extract_image_embeds(post_data)
    return table.maperr(images, function(image)
        return process_image(image, did, post_uri, author, rating)
    end)
end

local function can_process_uri(uri)
    local match = parse_bsky_uri(uri)
    return match ~= nil
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
}

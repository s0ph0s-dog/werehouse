local CHOST_URI_EXP =
    assert(re.compile([[^(https?://)?cohost.org/([A-z0-9_-]+)/post/([0-9]+)]]))
local CANONICAL_DOMAIN = "cohost.org"

local function match_cohost_uri(uri)
    local match, _, project, post_id = CHOST_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return project, tonumber(post_id)
end

---@type ScraperNormalize
local function normalize_uri(uri)
    local project, post_id = match_cohost_uri(uri)
    if not project then
        return uri
    end
    return "https://cohost.org/%s/post/%s" % { project, post_id }
end

local function can_process_uri(uri)
    local ok = match_cohost_uri(uri)
    return ok ~= nil
end

local function process_attachment_blocks(post)
    if not post.blocks then
        return nil
    end
    local attachment_blocks = table.filter(post.blocks, function(item)
        return item.type == "attachment" and item.attachment.kind == "image"
    end)
    if #attachment_blocks < 1 then
        return nil
    end
    if
        not post.postingProject
        or not post.postingProject.handle
        or not post.postingProject.displayName
    then
        return nil
    end
    local rating = DbUtil.k.Rating.General
    if post.effectiveAdultContent then
        rating = DbUtil.k.Rating.Explicit
    end
    local displayName = post.postingProject.displayName
    if not displayName or displayName == "" then
        displayName = post.postingProject.handle
    end
    local author = {
        handle = post.postingProject.handle,
        profile_url = "https://cohost.org/" .. post.postingProject.handle,
        display_name = displayName,
    }
    return table.maperr(attachment_blocks, function(block)
        ---@type ScrapedSourceData
        local result = {
            kind = DbUtil.k.ImageKind.Image,
            authors = { author },
            this_source = post.singlePostPageUrl,
            media_url = block.attachment.fileURL,
            height = block.attachment.height,
            width = block.attachment.width,
            canonical_domain = CANONICAL_DOMAIN,
            rating = rating,
            incoming_tags = post.tags,
        }
        return result
    end)
end

---@type ScraperProcess
local function process_uri(uri)
    local project, post_id = match_cohost_uri(uri)
    if not project then
        return nil, PipelineErrorPermanent("Not a Cohost URI.")
    end
    local api_url = EncodeUrl {
        scheme = "https",
        host = "cohost.org",
        path = "/api/v1/trpc/posts.singlePost",
        params = {
            { "batch", "1" },
            {
                "input",
                EncodeJson {
                    ["0"] = {
                        handle = project,
                        postId = post_id,
                    },
                },
            },
        },
    }
    local json, errmsg1 = Nu.FetchJson(api_url)
    if not json then
        -- TODO: some of these are probably not permanent (e.g. 502, 429)
        return nil, PipelineErrorPermanent(errmsg1)
    end
    if not json[1] or not json[1].result or not json[1].result.data then
        return nil, PipelineErrorPermanent("Invalid response from Cohost.")
    end
    local post = json[1].result.data.post
    if not post then
        return nil, PipelineErrorPermanent("Invalid response from Cohost.")
    end
    if post.limitedVisibilityReason ~= "none" then
        return nil,
            PipelineErrorPermanent(
                "This user's posts are only visible when logged in."
            )
    end
    local images = process_attachment_blocks(post)
    if not images then
        -- TODO: support videos
        return nil, PipelineErrorPermanent("This post has no attached photos.")
    end
    return images
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
}

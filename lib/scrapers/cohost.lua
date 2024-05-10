local CHOST_URI_EXP =
    assert(re.compile([[^https?://cohost.org/([A-z0-9_-]+)/post/([0-9]+)]]))
local CANONICAL_DOMAIN = "cohost.org"

local function match_cohost_uri(uri)
    local match, project, post_id = CHOST_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return project, tonumber(post_id)
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
    local rating = DbUtil.k.RatingGeneral
    if post.effectiveAdultContent then
        rating = DbUtil.k.RatingExplicit
    end
    local author = {
        handle = post.postingProject.handle,
        profile_url = "https://cohost.org/" .. post.postingProject.handle,
        display_name = post.postingProject.displayName,
    }
    return table.map(attachment_blocks, function(block)
        local mime_type = Nu.guess_mime_from_url(block.attachment.fileURL)
        if not mime_type then
            -- Hope for the best.
            mime_type = "image/jpeg"
        end
        return {
            authors = { author },
            this_source = post.singlePost,
            raw_image_uri = block.attachment.fileURL,
            mime_type = mime_type,
            height = block.attachment.height,
            width = block.attachment.width,
            canonical_domain = CANONICAL_DOMAIN,
            rating = rating,
        }
    end)
end

local function process_uri(uri)
    local project, post_id = match_cohost_uri(uri)
    if not project then
        return Err(PermScraperError("Not a Cohost URI."))
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
        return Err(PermScraperError(errmsg1))
    end
    if not json[1] or not json[1].result or not json[1].result.data then
        return Err(PermScraperError("Invalid response from Cohost."))
    end
    local post = json[1].result.data.post
    if not post then
        return Err(PermScraperError("Invalid response from Cohost."))
    end
    if post.limitedVisibilityReason ~= "none" then
        return Err(
            PermScraperError(
                "This user's posts are only visible when logged in."
            )
        )
    end
    local images = process_attachment_blocks(post)
    if not images then
        -- TODO: support videos
        return Err(PermScraperError("This post has no attached photos."))
    end
    return Ok(images)
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

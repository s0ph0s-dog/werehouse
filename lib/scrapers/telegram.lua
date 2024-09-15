local TG_URI_EXP =
    assert(re.compile([[^(https?://)t(elegram)?\.me/([A-z0-9_]+)/([0-9]+)]]))
local TG_BG_IMAGE_EXP =
    assert(re.compile([[background-image:url\('([^']+)'\)]]))
local CANONICAL_DOMAIN = "t.me"

local function normalize_tg_uri(uri)
    local match, _, _, chat_name, post_id = TG_URI_EXP:search(uri)
    if not match or not post_id then
        return nil
    end
    return "https://t.me/%s/%s" % { chat_name, post_id }
end

local function normalize_uri(uri)
    local result = normalize_tg_uri(uri)
    if not result then
        return uri
    end
    return result
end

local function can_process_uri(uri)
    local norm = normalize_tg_uri(uri)
    return norm ~= nil
end

local function first(list)
    if not list then
        return nil
    end
    if #list < 1 then
        return nil
    end
    return list[1]
end

---@param root table HTML element root for the Telegram embed page
---@return ScrapedAuthor
---@overload fun(root: any): nil, PipelineError
local function scrape_author_data(root)
    local maybe_owner_name_tag =
        first(root:select(".tgme_widget_message_owner_name"))
    if not maybe_owner_name_tag then
        return nil,
            PipelineErrorPermanent("No message owner name in Telegram embed")
    end
    local maybe_owner_name_span = maybe_owner_name_tag.nodes[1]
    if not maybe_owner_name_span then
        return nil,
            PipelineErrorPermanent("No message owner name in Telegram embed")
    end
    local owner_name = maybe_owner_name_span:getcontent()
    local owner_profile_url = maybe_owner_name_tag.attributes.href
    local handle = ParseUrl(owner_profile_url).path:sub(2)
    return {
        display_name = owner_name,
        handle = handle,
        profile_url = owner_profile_url,
    }
end

---@param style_text string
---@return string?
local function extract_bg_img_from_style(style_text)
    if not style_text then
        return nil
    end
    local match, url = TG_BG_IMAGE_EXP:search(style_text)
    if not match or not url then
        return nil
    end
    return url
end

---@return ScrapedSourceData
---@overload fun(root: any): nil, PipelineError
local function scrape_media_data(root)
    local author, a_err = scrape_author_data(root)
    if not author then
        return nil, a_err
    end
    -- Telegram's embed HTML doesn't seem to offer any distinction between videos and "GIFs" (which it internally converts to videos), so scrape only either images or videos.
    local images = root:select(".tgme_widget_message_photo_wrap")
    local image_records, img_err = table.maperr(images, function(image)
        local image_url = extract_bg_img_from_style(image.attributes.style)
        if not image_url then
            return nil,
                PipelineErrorPermanent("Invalid image URL in Telegram embed")
        end
        return {
            authors = { author },
            canonical_domain = CANONICAL_DOMAIN,
            height = 0,
            width = 0,
            kind = DbUtil.k.ImageKind.Image,
            media_url = image_url,
            mime_type = "image/jpeg",
            this_source = image.attributes.href,
        }
    end)
    if not image_records then
        return nil, img_err
    end
    local videos = root:select(".tgme_widget_message_video_player")
    local video_records, v_err = table.maperr(videos, function(video)
        local maybe_thumbnail =
            first(video:select(".tgme_widget_message_video_thumb"))
        if not maybe_thumbnail then
            return nil,
                PipelineErrorPermanent("No video thumbnail in Telegram embed")
        end
        local thumbnail_url =
            extract_bg_img_from_style(maybe_thumbnail.attributes.style)
        if not thumbnail_url then
            return nil,
                PipelineErrorPermanent(
                    "Invalid image URL in Telegram video thumbnail embed"
                )
        end
        local maybe_video = first(video:select(".tgme_widget_message_video"))
        if not maybe_video then
            return nil,
                PipelineErrorPermanent(
                    "No video element inside Telegram video player embed"
                )
        end
        return {
            authors = { author },
            canonical_domain = CANONICAL_DOMAIN,
            -- Telegram just doesn't include the video dimensions anywhere.
            height = 0,
            width = 0,
            kind = DbUtil.k.ImageKind.Video,
            media_url = maybe_video.attributes.src,
            mime_type = "video/mp4",
            this_source = video.attributes.href,
            thumbnails = {
                {
                    raw_uri = thumbnail_url,
                    mime_type = "image/jpeg",
                    width = 0,
                    height = 0,
                    scale = 1,
                },
            },
        }
    end)
    if not video_records then
        return nil, v_err
    end
    local results = table.extend(image_records, video_records)
    if #results < 1 then
        return nil,
            PipelineErrorPermanent(
                "No images, videos, or GIFs in the Telegram embed page"
            )
    end
    return results
end

---@type ScraperProcess
local function process_uri(uri)
    local norm_uri = normalize_tg_uri(uri)
    if not norm_uri then
        return nil, PipelineErrorPermanent("Invalid Telegram URL")
    end
    local parts = ParseUrl(norm_uri)
    parts.params = {
        { "embed", "1" },
        { "mode", "tme" },
    }
    local embed_uri = EncodeUrl(parts)
    local status, resp_headers, body = Fetch(embed_uri)
    if not status then
        return nil, PipelineErrorPermanent(resp_headers)
    end
    if Nu.is_temporary_failure_status(status) then
        return nil, PipelineErrorTemporary(status)
    elseif Nu.is_permanent_failure_status(status) then
        return nil, PipelineErrorPermanent(status)
    elseif not Nu.is_success_status(status) then
        return nil, PipelineErrorPermanent(status)
    end
    if #body < 100 then
        return nil,
            PipelineErrorPermanent("The response from Telegram was too short.")
    end
    local root = HtmlParser.parse(body)
    if not root then
        return nil, PipelineErrorPermanent("Telegram returned invalid HTML.")
    end
    local data, errmsg = scrape_media_data(root)
    if not data then
        return nil, errmsg
    end
    return data
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
}

local TWITTER_URI_EXP = assert(
    re.compile(
        [[^(https?://)?(twitter\.com|vxtwitter\.com|fxtwitter\.com|x\.com|fixupx\.com|fixvx\.com|nitter\.privacydev\.net|twittervx\.com)/([A-z0-9_]+/)?status/([A-z0-9]+)]]
    )
)
local SPLITEXT_EXP = assert(re.compile([[(.+)\.([a-z0-9]{3})$]]))
local TYPE_TO_KIND_MAP = {
    photo = DbUtil.k.ImageKind.Image,
    video = DbUtil.k.ImageKind.Video,
    gif = DbUtil.k.ImageKind.Animation,
}
-- Eat Shit, Elon
local CANONICAL_DOMAIN = "twitter.com"

local function match_twitter_uri(uri)
    local match, _, _, handle, snowflake = TWITTER_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return snowflake, handle
end

local function can_process_uri(uri)
    local snowflake = match_twitter_uri(uri)
    return snowflake ~= nil
end

---@type ScraperNormalize
local function normalize_uri(uri)
    local snowflake, handle = match_twitter_uri(uri)
    if not snowflake then
        return uri
    end
    return "https://twitter.com/%sstatus/%s"
        % {
            handle or "",
            snowflake,
        }
end

local function make_thumbnail(media)
    if media.thumbnail_url then
        return {
            {
                raw_uri = media.thumbnail_url,
                width = media.width,
                height = media.height,
                scale = 1,
            },
        }
    else
        return nil
    end
end

local function process_embeds(json)
    if not json.media then
        return nil
    end
    if not json.media.all then
        return nil
    end
    if #json.media.all < 1 then
        return nil, PipelineErrorPermanent("This tweet has no embedded media.")
    end
    if not json.author then
        return nil
    end
    local rating = DbUtil.k.Rating.General
    if json.possibly_sensitive then
        rating = DbUtil.k.Rating.Adult
    end
    local author = {
        handle = json.author.screen_name,
        profile_url = json.author.url,
        display_name = json.author.name,
    }
    return table.maperr(json.media.all, function(twitter_embed)
        local fullsize_media_url
        if twitter_embed.type == "photo" then
            local parts = ParseUrl(twitter_embed.url)
            local m, path_prefix, ext = SPLITEXT_EXP:search(parts.path)
            if not m then
                fullsize_media_url = twitter_embed.url
            else
                parts.path = path_prefix
                parts.params = {
                    { "format", ext },
                    -- `orig` is the original size of the image.
                    { "name", "orig" },
                }
                fullsize_media_url = EncodeUrl(parts)
            end
        else
            fullsize_media_url = twitter_embed.url
        end
        ---@type ScrapedSourceData
        local result = {
            kind = TYPE_TO_KIND_MAP[twitter_embed.type],
            authors = { author },
            this_source = json.url,
            media_url = fullsize_media_url,
            height = twitter_embed.height,
            width = twitter_embed.width,
            canonical_domain = "twitter.com",
            rating = rating,
            thumbnails = make_thumbnail(twitter_embed),
        }
        return result
    end)
end

---@type ScraperProcess
local function process_uri(uri)
    local snowflake = match_twitter_uri(uri)
    if not snowflake then
        return nil, PipelineErrorPermanent("Not a Twitter URI.")
    end
    local normalized = "https://api.fxtwitter.com/status/" .. snowflake
    local json, errmsg1 = Nu.FetchJson(normalized)
    if not json then
        -- TODO: some of these are probably not permanent (e.g. 502, 429)
        return nil, PipelineErrorPermanent(errmsg1)
    end
    if not json.code then
        return nil, PipelineErrorPermanent("Invalid response from fxtwitter.")
    end
    if json.code == 401 then
        return nil, PipelineErrorPermanent("This tweet is private.")
    elseif json.code == 404 then
        return nil, PipelineErrorPermanent("This tweet doesn't exist.")
    elseif json.code == 500 then
        return nil,
            PipelineErrorTemporary(
                "Temporary Twitter API error, will retry next time."
            )
    end
    -- Only remaining option should be 200.
    if not json.tweet then
        return nil, PipelineErrorPermanent("Invalid response from fxtwitter.")
    end
    return process_embeds(json.tweet)
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
}

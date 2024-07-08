local TWITTER_URI_EXP = assert(
    re.compile(
        [[^https?://(twitter\.com|vxtwitter\.com|fxtwitter\.com|x\.com|fixupx\.com|fixvx\.com|nitter\.privacydev\.net)/([A-z_]+/)?status/([A-z0-9]+)]]
    )
)
local TYPE_TO_KIND_MAP = {
    photo = DbUtil.k.ImageKind.Image,
    video = DbUtil.k.ImageKind.Video,
    gif = DbUtil.k.ImageKind.Animation,
}
-- Eat Shit, Elon
local CANONICAL_DOMAIN = "twitter.com"

local function normalize_twitter_uri(uri)
    local match, _, _, snowflake = TWITTER_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return "https://api.fxtwitter.com/status/%s" % { snowflake }
end

local function can_process_uri(uri)
    local normalized = normalize_twitter_uri(uri)
    return normalized ~= nil
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
    return table.map(json.media.all, function(twitter_embed)
        local mime_type = Nu.guess_mime_from_url(twitter_embed.url)
        if not mime_type then
            -- Hope for the best.
            mime_type = "image/jpeg"
        end
        return {
            kind = TYPE_TO_KIND_MAP[twitter_embed.type],
            authors = { author },
            this_source = json.url,
            raw_image_uri = twitter_embed.url,
            mime_type = mime_type,
            height = twitter_embed.height,
            width = twitter_embed.width,
            canonical_domain = "twitter.com",
            rating = rating,
            thumbnails = make_thumbnail(twitter_embed),
        }
    end)
end

local function process_uri(uri)
    local normalized = normalize_twitter_uri(uri)
    if not normalized then
        return Err(PermScraperError("Not a Twitter URI."))
    end
    local json, errmsg1 = Nu.FetchJson(normalized)
    if not json then
        -- TODO: some of these are probably not permanent (e.g. 502, 429)
        return Err(PermScraperError(errmsg1))
    end
    if not json.code then
        return Err(PermScraperError("Invalid response from fxtwitter."))
    end
    if json.code == 401 then
        return Err(PermScraperError("This tweet is private."))
    elseif json.code == 404 then
        return Err(PermScraperError("This tweet doesn't exist."))
    elseif json.code == 500 then
        return Err(
            TempScraperError(
                "Temporary Twitter API error, will retry next time."
            )
        )
    end
    -- Only remaining option should be 200.
    if not json.tweet then
        return Err(PermScraperError("Invalid response from fxtwitter."))
    end
    local supported_embeds = process_embeds(json.tweet)
    if not supported_embeds then
        -- TODO: support videos
        return Err(PermScraperError("This tweet has no embedded media."))
    end
    return Ok(supported_embeds)
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

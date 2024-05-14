local TWITTER_URI_EXP = assert(
    re.compile(
        [[^https?://(twitter\.com|vxtwitter\.com|fxtwitter\.com|x\.com|fixupx\.com|fixvx\.com|nitter\.privacydev\.net)/.+/([A-z0-9]+)]]
    )
)
-- Eat Shit, Elon
local CANONICAL_DOMAIN = "twitter.com"

local function normalize_twitter_uri(uri)
    local match, _, snowflake = TWITTER_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return "https://api.fxtwitter.com/status/%s" % { snowflake }
end

local function can_process_uri(uri)
    local normalized = normalize_twitter_uri(uri)
    return normalized ~= nil
end

local function process_image_embeds(json)
    if not json.media then
        return nil
    end
    if not json.media.photos then
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
    return table.map(json.media.photos, function(twitter_photo)
        local mime_type = Nu.guess_mime_from_url(twitter_photo.url)
        if not mime_type then
            -- Hope for the best.
            mime_type = "image/jpeg"
        end
        return {
            authors = { author },
            this_source = json.url,
            raw_image_uri = twitter_photo.url,
            mime_type = mime_type,
            height = twitter_photo.height,
            width = twitter_photo.width,
            canonical_domain = "twitter.com",
            rating = rating,
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
    local image_embeds = process_image_embeds(json.tweet)
    if not image_embeds then
        -- TODO: support videos
        return Err(PermScraperError("This tweet has no embedded photos."))
    end
    return Ok(image_embeds)
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

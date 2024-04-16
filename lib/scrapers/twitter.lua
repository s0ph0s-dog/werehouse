
TWITTER_URI_EXP = assert(re.compile[[^https?://(twitter\.com|vxtwitter\.com|fxtwitter\.com|x\.com|fixupx\.com|fixvx\.com|nitter\.privacydev\.net)/.+/([A-z0-9]+)]])
TWITTER_MEDIA_EXT_EXP = assert(re.compile[[\.([a-z0-9]{1,5})$]])

local function normalize_twitter_uri(uri)
    local match, _, snowflake = TWITTER_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return "https://api.fxtwitter.com/status/%s" % {snowflake}
end

local function can_process_uri(uri)
    local normalized = normalize_twitter_uri(uri)
    return normalized ~= nil
end

local ext_to_mime = {
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
}
local function twitter_photo_to_mime(url)
    local parts = ParseUrl(url)
    local match, ext = TWITTER_MEDIA_EXT_EXP:search(parts.path)
    if not match then
        -- Hope for the best.
        return "image/jpeg"
    end
    local best_guess = ext_to_mime[ext]
    if not best_guess then
        return "image/jpeg"
    end
    return best_guess
end

local function process_image_embeds(json)
    if not json.media then
        return nil
    end
    if not json.media.photos then
        return nil
    end
    return table.map(
        json.media.photos,
        function (twitter_photo)
            return {
                raw_image_uri = twitter_photo.url,
                mime_type = twitter_photo_to_mime(twitter_photo.url),
                height = twitter_photo.height,
                width = twitter_photo.width,
            }
        end
    )
end

local function process_uri(uri)
    local normalized= normalize_twitter_uri(uri)
    if not normalized then
        return Err(PermScraperError("Not a Twitter URI."))
    end
    local json, errmsg1 = FetchJson(normalized)
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
        return Err(TempScraperError("Temporary Twitter API error, will retry next time."))
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

local FA_URI_EXP = assert(
    re.compile(
        [[^https?://(www\.)?(fx|x)?furaffinity\.net/(view|full)/([0-9]+)]]
    )
)
local RATING_MAP = {
    General = DbUtil.k.RatingGeneral,
    Mature = DbUtil.k.RatingAdult,
    Adult = DbUtil.k.RatingExplicit,
}
local FA_SIZE_EXP = assert(re.compile([[(\d+) x (\d+)]]))
local FA_AUTH_COOKIES = os.getenv("FA_AUTH_COOKIES")
local CANONICAL_DOMAIN = "www.furaffinity.net"

local function normalize_fa_uri(uri)
    local match, _, _, _, id = FA_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return "https://www.furaffinity.net/full/%s" % { id }
end

local function can_process_uri(uri)
    local norm = normalize_fa_uri(uri)
    return norm ~= nil
end

local function is_cloudflare_blocked(root)
    local maybe_block = root:select(".cf-browser-verification")
    return maybe_block ~= nil and #maybe_block > 0
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

local function last(list)
    if not list then
        return nil
    end
    if #list < 1 then
        return nil
    end
    return list[#list]
end

local function scrape_image_metadata(root)
    local maybe_image_tag = first(root:select("#submissionImg"))
    if not maybe_image_tag then
        return nil, PermScraperError("No image in post.")
    end
    local maybe_image_src = maybe_image_tag.attributes.src
    if not maybe_image_src then
        return nil, PermScraperError("Invalid image tag in post.")
    end
    local full_image_src = "https:" .. maybe_image_src
    local maybe_rating = first(root:select(".rating-box"))
    if not maybe_rating then
        return nil, PermScraperError("No rating for this post")
    end
    local rating_text = maybe_rating:getcontent()
    rating_text = rating_text:strip()
    local rating = RATING_MAP[rating_text]
    if not rating then
        Log(kLogWarn, "Unknown rating from FA: %s" % { rating_text })
    end
    local maybe_sidebar_size = last(root:select(".info div span"))
    if not maybe_sidebar_size then
        return nil, PermScraperError("No size metadata in post.")
    end
    local match, width, height =
        FA_SIZE_EXP:search(maybe_sidebar_size:getcontent())
    if not match then
        return nil, PermScraperError("Corrupt size metadata in post.")
    end
    local mime_type = Nu.guess_mime_from_url(full_image_src)
    local maybe_profile_element =
        first(root:select(".submission-id-sub-container a"))
    if not maybe_profile_element then
        return nil, PermScraperError("Unable to find the post author's name")
    end
    local profile_url = "https://www.furaffinity.net"
        .. maybe_profile_element.attributes.href
    local display_name_element = first(maybe_profile_element:select("strong"))
    if not display_name_element then
        return nil, PermScraperError("No display name for the user")
    end
    local display_name = display_name_element:getcontent()
    return {
        raw_image_uri = full_image_src,
        mime_type = mime_type,
        width = tonumber(width),
        height = tonumber(height),
        canonical_domain = CANONICAL_DOMAIN,
        authors = {
            {
                profile_url = profile_url,
                display_name = display_name,
                handle = display_name,
            },
        },
        rating = rating,
    }
end

local function process_uri(uri)
    local norm_uri = normalize_fa_uri(uri)
    local req_headers = {
        ["Cookie"] = FA_AUTH_COOKIES,
    }
    local status, resp_headers, body =
        Fetch(norm_uri, { headers = req_headers })
    if not status then
        return Err(PermScraperError(resp_headers))
    end
    if Nu.is_temporary_failure_status(status) then
        return Err(TempScraperError(status))
    elseif Nu.is_permanent_failure_status(status) then
        return Err(PermScraperError(status))
    elseif not Nu.is_success_status(status) then
        return Err(PermScraperError(status))
    end
    if #body < 100 then
        return Err(PermScraperError("The response from FA was too short."))
    end
    -- Increase loop limit from default 1000 to 10,000 because FA's html is bloated.
    local root = HtmlParser.parse(body, 10000)
    if not root then
        return Err(PermScraperError("FA returned invalid HTML."))
    end
    -- TODO: detect not being logged in as well
    if is_cloudflare_blocked(root) then
        return Err(
            TempScraperError(
                "FA has turned on Cloudflare's 'under attack' mode, which blocks bots."
            )
        )
    end
    local metadata, errmsg = scrape_image_metadata(root)
    if not metadata then
        return Err(errmsg)
    end
    metadata.this_source = norm_uri
    return Ok { metadata }
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

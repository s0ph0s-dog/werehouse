local FA_URI_EXP = assert(
    re.compile(
        [[^(https?://)?(www\.)?(fx|x|vx)?f(u|x)raffinity\.net/(view|full)/([0-9]+)]]
    )
)
local RATING_MAP = {
    General = DbUtil.k.Rating.General,
    Mature = DbUtil.k.Rating.Adult,
    Adult = DbUtil.k.Rating.Explicit,
}
local FA_SIZE_EXP = assert(re.compile([[(\d+) x (\d+)]]))
local FA_AUTH_COOKIES = os.getenv("FA_AUTH_COOKIES")
local CANONICAL_DOMAIN = "www.furaffinity.net"

local function normalize_fa_uri(uri)
    local match, _, _, _, _, _, id = FA_URI_EXP:search(uri)
    if not match or not id then
        return nil
    end
    return "https://www.furaffinity.net/full/%s" % { id }
end

local function normalize_uri(uri)
    local result = normalize_fa_uri(uri)
    if not result then
        return uri
    end
    return result
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

---@return ScrapedSourceData
---@overload fun(root: any): nil, PipelineError
local function scrape_image_data(root)
    local maybe_image_tag = first(root:select("#submissionImg"))
    if not maybe_image_tag then
        return nil, PipelineErrorPermanent("No image in post.")
    end
    local maybe_image_src = maybe_image_tag.attributes.src
    if not maybe_image_src then
        return nil, PipelineErrorPermanent("Invalid image tag in post.")
    end
    local full_image_src = "https:" .. maybe_image_src
    local maybe_rating = first(root:select(".rating-box"))
    if not maybe_rating then
        return nil, PipelineErrorPermanent("No rating for this post")
    end
    local rating_text = maybe_rating:getcontent()
    rating_text = rating_text:strip()
    local rating = RATING_MAP[rating_text]
    if not rating then
        Log(kLogWarn, "Unknown rating from FA: %s" % { rating_text })
    end
    local maybe_sidebar_size = last(root:select(".info div span"))
    if not maybe_sidebar_size then
        return nil, PipelineErrorPermanent("No size metadata in post.")
    end
    local match, width, height =
        FA_SIZE_EXP:search(maybe_sidebar_size:getcontent())
    if not match then
        return nil, PipelineErrorPermanent("Corrupt size metadata in post.")
    end
    local maybe_profile_element =
        first(root:select(".submission-id-sub-container a"))
    if not maybe_profile_element then
        return nil,
            PipelineErrorPermanent("Unable to find the post author's name")
    end
    local profile_url = "https://www.furaffinity.net"
        .. maybe_profile_element.attributes.href
    local display_name_element = first(maybe_profile_element:select("strong"))
    if not display_name_element then
        return nil, PipelineErrorPermanent("No display name for the user")
    end
    local display_name = display_name_element:getcontent()
    -- The tags are in two places on the page, so find just the sidebar ones.
    local tag_elements = root:select(".submission-sidebar .tags a")
    local tags = table.map(tag_elements, function(t)
        return t:getcontent()
    end)
    ---@type ScrapedSourceData
    local result = {
        kind = DbUtil.k.ImageKind.Image,
        media_url = full_image_src,
        width = tonumber(width) or 0,
        height = tonumber(height) or 0,
        canonical_domain = CANONICAL_DOMAIN,
        authors = {
            {
                profile_url = profile_url,
                display_name = display_name,
                handle = display_name,
            },
        },
        rating = rating,
        incoming_tags = tags,
        this_source = "",
    }
    return result
end

---@type ScraperProcess
local function process_uri(uri)
    local norm_uri = normalize_fa_uri(uri)
    if not norm_uri then
        return nil, PipelineErrorPermanent("Invalid FA URL")
    end
    local req_headers = {
        ["Cookie"] = FA_AUTH_COOKIES,
    }
    local status, resp_headers, body =
        Fetch(norm_uri, { headers = req_headers })
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
            PipelineErrorPermanent("The response from FA was too short.")
    end
    -- Increase loop limit from default 1000 to 10,000 because FA's html is bloated.
    local root = HtmlParser.parse(body, 10000)
    if not root then
        return nil, PipelineErrorPermanent("FA returned invalid HTML.")
    end
    -- TODO: detect not being logged in as well
    if is_cloudflare_blocked(root) then
        return nil,
            PipelineErrorTemporary(
                "FA has turned on Cloudflare's 'under attack' mode, which blocks bots."
            )
    end
    local data, errmsg = scrape_image_data(root)
    if not data then
        return nil, PipelineErrorPermanent(errmsg)
    end
    data.this_source = norm_uri
    return { data }
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
}

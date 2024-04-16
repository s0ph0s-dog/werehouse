FA_URI_EXP = assert(re.compile[[^https?://(www\.)?(fx|x)?furaffinity\.net/(view|full)/([0-9]+)]])
FA_SIZE_EXP = assert(re.compile[[(\d+) x (\d+)]])
FA_AUTH_COOKIES = os.getenv("FA_AUTH_COOKIES")

local function normalize_fa_uri(uri)
    local match, _, _, _, id = FA_URI_EXP:search(uri)
    if not match then
        return nil
    end
    return "https://www.furaffinity.net/full/%s" % {id}
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
    local maybe_sidebar_size = last(root:select(".info div span"))
    if not maybe_sidebar_size then
        return nil, PermScraperError("No size metadata in post.")
    end
    local match, width, height = FA_SIZE_EXP:search(maybe_sidebar_size:getcontent())
    if not match then
        return nil, PermScraperError("Corrupt size metadata in post.")
    end
    local mime_type = Nu.guess_mime_from_url(full_image_src)
    return {
        raw_image_uri = full_image_src,
        mime_type = mime_type,
        width = tonumber(width),
        height = tonumber(height),
    }
end

local function process_uri(uri)
    local norm_uri = normalize_fa_uri(uri)
    local req_headers = {
        ["Cookies"] = FA_AUTH_COOKIES,
    }
    local status, resp_headers, body = Fetch(norm_uri, {headers = req_headers})
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
    if is_cloudflare_blocked(root) then
        return Err(TempScraperError("FA has turned on Cloudflare's 'under attack' mode, which blocks bots."))
    end
    local metadata, errmsg = scrape_image_metadata(root)
    if not metadata then
        return Err(errmsg)
    end
    return Ok({metadata})
end

return {
    process_uri = process_uri,
    can_process_uri = can_process_uri,
}

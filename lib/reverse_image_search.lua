local FUZZYSEARCH_API_KEY = os.getenv("FUZZYSEARCH_API_KEY")

local SITE_TO_POST_URL_MAP = {
    FurAffinity = "https://www.furaffinity.net/full/%s",
    e621 = "https://e621.net/posts/%s",
    Twitter = "https://twitter.com/status/%s",
    Weasyl = "https://www.weasyl.com/submissions/%s",
}

local REVERSE_SEARCHABLE_MIME_TYPES = {
    ["image/png"] = true,
    ["image/jpeg"] = true,
    ["image/gif"] = true,
}

local FUZZYSEARCH_DISTANCE = 3

local function fuzzysearch_multipart_body(
    boundary,
    distance,
    image_data,
    content_type
)
    local ext = FsTools.MIME_TO_EXT[content_type] or ""
    return Multipart.encode({
        distance = tostring(distance),
        image = {
            filename = "C:\\fakepath\\purple" .. ext,
            data = image_data,
        },
    }, boundary)
end

local function fluffle_multipart_body(boundary, image_data, content_type)
    local ext = FsTools.MIME_TO_EXT[content_type] or ""
    return Multipart.encode({
        includeNsfw = "true",
        file = {
            filename = "C:\\fakepath\\fluffle" .. ext,
            exclude_asterisk = true,
            data = image_data,
        },
    }, boundary)
end

local function transform_fuzzysearch_response(json)
    -- Log(kLogDebug, "FuzzySearch JSON response: %s" % { EncodeJson(json) })
    local result = table.filtermap(json, function(result)
        -- Log(kLogDebug, "Filter debug: %d, %s, %s" % {result.distance, result.site, SITE_TO_POST_URL_MAP[result.site]})
        return result.distance <= 3 and SITE_TO_POST_URL_MAP[result.site] ~= nil
    end, function(result)
        local post_url_template = SITE_TO_POST_URL_MAP[result.site]
        local result = post_url_template:format(result.site_id_str)
        -- Log(kLogDebug, "Map debug: %s" % {EncodeJson(result)})
        return result
    end)
    -- Log(kLogDebug, "Processed FuzzySearch results: %s" % {EncodeJson(result)})
    return result
end

local function fuzzysearch_image(image_data, mime_type)
    assert(image_data ~= nil, "image data was nil, why are searching for that?")
    assert(
        mime_type ~= nil,
        "mime type was nil, why are you searching for that?"
    )
    if not FUZZYSEARCH_API_KEY then
        return nil,
            "This instance has no FuzzySearch API key. Please ask your administrator to request one."
    end
    local api_url = EncodeUrl {
        scheme = "https",
        host = "api-next.fuzzysearch.net",
        path = "/v1/image",
    }
    local boundary = "__X_HELLO_SYFARO__"
    local body = fuzzysearch_multipart_body(
        boundary,
        FUZZYSEARCH_DISTANCE,
        image_data,
        mime_type
    )
    local json, errmsg = Nu.FetchJson(api_url, {
        method = "POST",
        headers = {
            ["Content-Type"] = "multipart/form-data; charset=utf-8; boundary=%s"
                % { boundary },
            ["Content-Length"] = tostring(#body),
            ["x-api-key"] = FUZZYSEARCH_API_KEY,
        },
        body = body,
    })
    if not json and errmsg then
        return nil, errmsg
    end
    return transform_fuzzysearch_response(json)
end

local function dim_helper(d1, d2, d1_target)
    return math.ceil(d1_target / d1 * d2)
end

local function dimensions_not_smaller_than(target, in_width, in_height)
    if in_width > in_height then
        return dim_helper(in_height, in_width, target), target
    end
    return target, dim_helper(in_width, in_height, target)
end

local function transform_fluffle_response(json)
    -- Log(kLogDebug, "Fluffle API response: %s" % { EncodeJson(json) })
    local result = table.filtermap(json, function(result)
        return result.score >= 0.95
    end, function(result)
        return result.location
    end)
    -- Log(kLogDebug, "Processed Fluffle.xyz results: %s" % { EncodeJson(result) })
    return result
end

local function fluffle_image(image_data, mime_type)
    assert(image_data ~= nil)
    if not img then
        return nil,
            "This Redbean wasn't compiled with the `img` library for image resizing and (en/de)coding."
    end
    local imageu8, i_err = img.loadbuffer(image_data)
    if not imageu8 then
        return nil, i_err
    end
    local thumbnail, t_err = imageu8:resize(
        dimensions_not_smaller_than(256, imageu8:width(), imageu8:height())
    )
    if not thumbnail then
        return nil, t_err
    end
    local thumbnail_png = thumbnail:savebufferpng()
    local boundary = "__X_HELLO_NOPPES_THE_FOLF__"
    local request_body =
        fluffle_multipart_body(boundary, thumbnail_png, mime_type)
    local api_url = EncodeUrl {
        scheme = "https",
        host = "api.fluffle.xyz",
        path = "/v1/search",
    }
    local json, errmsg = Nu.FetchJson(api_url, {
        method = "POST",
        headers = {
            ["Content-Type"] = "multipart/form-data; charset=utf-8; boundary=%s"
                % { boundary },
            ["Content-Length"] = tostring(#request_body),
            ["User-Agent"] = "werehouse/0.1.0 (https://github.com/s0ph0s-2/werehouse)",
        },
        body = request_body,
    })
    if not json or errmsg then
        return nil, errmsg
    end
    if not json.results then
        return nil,
            "Error from Fluffle.xyz: %s (%s)" % { json.code, json.message }
    end
    return transform_fluffle_response(json.results)
end

---@param image string The encoded image data to locate sources for.
---@param mime_type string The MIME type of the encoded image data in `image`.
---@return string[] A list of URLs that are potential sources for the image.
---@overload fun(string): nil, string An error message will be the second return value if the first return value is nil.
local function search(image, mime_type)
    local fluffle_results, fluffle_err = fluffle_image(image, mime_type)
    Log(kLogDebug, "Fluffle results: " .. EncodeJson(fluffle_results))
    if fluffle_results and #fluffle_results > 0 then
        return fluffle_results
    end
    local fuzzysearch_results, fuzzysearch_err =
        fuzzysearch_image(image, mime_type)
    Log(kLogDebug, "FuzzySearch results: " .. EncodeJson(fuzzysearch_results))
    if fuzzysearch_results and #fuzzysearch_results > 0 then
        return fuzzysearch_results
    end
    if #fluffle_results == 0 and #fuzzysearch_results == 0 then
        return {}
    end
    return nil, fluffle_err + "; " + fuzzysearch_err
end

return {
    search = search,
    SEARCHABLE_MIME_TYPES = REVERSE_SEARCHABLE_MIME_TYPES,
}

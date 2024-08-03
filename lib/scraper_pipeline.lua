require("scraper_types")

local FUZZYSEARCH_API_KEY = os.getenv("FUZZYSEARCH_API_KEY")
local SP_QUEUE = "save_from_queue"
local function require_only(path)
    local result = require(path)
    return result
end

--- All of the available scrapers
---@type Scraper[]
local scrapers = {
    require_only("scrapers.bluesky"),
    require_only("scrapers.twitter"),
    require_only("scrapers.furaffinity"),
    require_only("scrapers.e621"),
    require_only("scrapers.cohost"),
    require_only("scrapers.itakuee"),
    require_only("scrapers.mastodon"),
    require_only("scrapers.test"),
}

local CANONICAL_DOMAINS_WITH_TAGS = {
    "www.furaffinity.net",
    "e621.net",
    "cohost.org",
    "itaku.ee",
}

local SITE_TO_POST_URL_MAP = {
    FurAffinity = "https://www.furaffinity.net/full/%s",
    e621 = "https://e621.net/posts/%s",
    Twitter = "https://twitter.com/status/%s",
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

local function fuzzysearch_uri(image_uri)
    local api_url = EncodeUrl {
        scheme = "https",
        host = "api-next.fuzzysearch.net",
        path = "/v1/url",
        params = { { "url", image_uri } },
    }
    local json, errmsg = Nu.FetchJson(api_url, {
        headers = {
            ["x-api-key"] = FUZZYSEARCH_API_KEY,
        },
    })
    if not json and errmsg then
        return nil, errmsg
    end
    return transform_fuzzysearch_response(json)
end

local function fuzzysearch_image(image_data, mime_type)
    assert(image_data ~= nil, "image data was nil, why are searching for that?")
    assert(
        mime_type ~= nil,
        "mime type was nil, why are you searching for that?"
    )
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
    local request_body = fluffle_multipart_body(boundary, image_data, mime_type)
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

local function can_process_uri(uri)
    for i = 1, #scrapers do
        if scrapers[i].can_process_uri(uri) then
            return true
        end
    end
    return false
end

---@param uri (string) A single URI pointing to a webpage on an art gallery or social media site at which an artist has posted an image.
---@return Result<ScrapedSourceData, ScraperError> # All of the scraped data objects from the first scraper that could process the URI.
local function process_source_uri(uri)
    for _, scraper in ipairs(scrapers) do
        if scraper.can_process_uri(uri) then
            return scraper.process_uri(uri)
        end
    end
    return Err(PermScraperError("No scrapers could process %s" % { uri }))
end

---@param link string
---@return boolean # Does this URL have quirks?
---@return boolean? # If this URL has quirks, true if it should be checked against FuzzySearch, false otherwise.
local function quirks(link)
    local parts = ParseUrl(link)
    if
        parts.host == "twitter.com"
        or parts.host == "vxtwitter.com"
        or parts.host == "x.com"
        or parts.host == "fixvx.com"
    then
        -- Twitter (for mystery reasons) makes Redbean go into an infinite loop while waiting for the response to my HEAD request below.
        return true, false
    end
    if parts.host == "nitter.privacydev.net" then
        -- Nitter results in "HTTP client EOF body error"
        return true, false
    end
    if
        parts.host == "www.fxfuraffinity.net"
        or parts.host == "fxfuraffinity.net"
        or parts.host == "xfuraffinity.net"
        or parts.host == "www.xfuraffinity.net"
    then
        -- fxfuraffinity and Redbean's Fetch() don't get along well when sending HEAD requests.
        return true, false
    end
    if
        parts.host == "www.furaffinity.net"
        or parts.host == "furaffinity.net"
    then
        -- FurAffinity also sometimes confuses Redbean's Fetch().
        return true, false
    end
    if parts.host == "d.furaffinity.net" then
        return true, true
    end
    return false
end

---@return boolean # true if this URL should be checked with FuzzySearch, false if it can be handled internally.
---@return string? errmsg An error message, if one occurred.
local function guess_with_head(link)
    if not link then
        return false, "link was null, probably an error"
    end
    local status, headers, _ = Fetch(link, { method = "HEAD" })
    if not status then
        return false, "%s while fetching %s" % { headers, link }
    elseif status == 405 then
        -- If status is 405, assume it's not a raw image URL. Most image CDNs don't disallow HEAD (for caching/performance reasons)
        return false
    elseif status ~= 200 then
        return false, "%d while fetching %s" % { status, link }
    else
        return headers["Content-Type"]
            and headers["Content-Type"]:startswith("image/")
    end
end

---@param queue_entry ActiveQueueEntry
local function get_sources_for_entry(queue_entry)
    if queue_entry.link then
        local has_quirks, check_fuzzysearch = quirks(queue_entry.link)
        if not has_quirks then
            local errmsg = nil
            check_fuzzysearch, errmsg = guess_with_head(queue_entry.link)
            if errmsg then
                Log(
                    kLogInfo,
                    "Failed to guess whether %s is a file using HEAD: %s"
                        % { queue_entry.link, errmsg }
                )
                return { queue_entry.link }
            end
        end
        if check_fuzzysearch then
            local maybe_source_links, errmsg = fuzzysearch_uri(queue_entry.link)
            if not maybe_source_links then
                return nil, errmsg
            end
            return maybe_source_links
        else
            return { queue_entry.link }
        end
        return nil, "should be unreachable"
    elseif queue_entry.image then
        local maybe_source_links, l_err =
            fuzzysearch_image(queue_entry.image, queue_entry.image_mime_type)
        if not maybe_source_links then
            Log(kLogInfo, tostring(l_err))
        end
        if #maybe_source_links < 1 then
            maybe_source_links, l_err =
                fluffle_image(queue_entry.image, queue_entry.image_mime_type)
            if not maybe_source_links then
                return nil, l_err
            end
        end
        return maybe_source_links
    else
        return nil,
            "No link or image data for queue entry %s" % { queue_entry.qid }
    end
    return nil, "should be unreachable"
end

local function check_for_duplicates_helper(
    model,
    dupes_list,
    sources,
    source_kind
)
    local dupes, dupe_err = model:checkDuplicateSources(sources)
    if not dupes then
        return TempScraperError(dupe_err)
    end
    for dupe_url, dupe_image_id in pairs(dupes) do
        table.insert(dupes_list, {
            url = dupe_url,
            image_id = dupe_image_id,
            source_kind = source_kind,
        })
    end
end

---@return FetchedThumbnail
---@overload fun(imageu8: img.Imageu8): nil, any?
local function make_thumbnail(imageu8)
    local thumbnail, thumb_err = imageu8:resize(192)
    if not thumbnail then
        return nil, thumb_err
    end
    local thumbnail_data, td_err = thumbnail:savebufferwebp(75.0)
    if not thumbnail_data then
        return nil, td_err
    end
    return {
        raw_uri = "data:image/png;base64,",
        image_data = thumbnail_data,
        mime_type = "image/webp",
        width = thumbnail:width(),
        height = thumbnail:height(),
        scale = 1,
    }
end

--- Also does the thumbnailing, because this function already has the decoded image in memory to hash it.
---@param model Model
---@param queue_entry ActiveQueueEntry
---@param task EntryTask
local function check_for_duplicates(model, queue_entry, task)
    -- This validation only makes sense for archive tasks, so pass other tasks through unchanged.
    if not task.archive then
        return task
    end
    -- Check for duplicate sources already in the database.
    ---@type DuplicateData[]
    local duplicates = {}
    if not task.no_dupe_check then
        if task.discovered_sources then
            local err = check_for_duplicates_helper(
                model,
                duplicates,
                task.discovered_sources,
                "discovered"
            )
            if err then
                return nil, err
            end
        end
    end
    for _, data in ipairs(task.archive) do
        if not task.no_dupe_check then
            local this_err = check_for_duplicates_helper(
                model,
                duplicates,
                { data.this_source },
                "this"
            )
            if this_err then
                return nil, this_err
            end
            if data.additional_sources then
                local addtnl_err = check_for_duplicates_helper(
                    model,
                    duplicates,
                    data.additional_sources,
                    "additional"
                )
                if addtnl_err then
                    return nil, addtnl_err
                end
            end
        end
        -- Hash & thumbnail the image.
        assert(
            data.image_data,
            "Task made it to check_for_duplicates without having downloaded the image. Something was supposed to have been fetched from "
                .. data.raw_image_uri
        )
        local imageu8, img_err = img.loadbuffer(data.image_data)
        if not imageu8 then
            Log(kLogInfo, "Failed to decode the image: %s" % { img_err })
        else
            data.width = imageu8:width()
            data.height = imageu8:height()
            local thumbnail, thumb_err = make_thumbnail(imageu8)
            if not thumbnail then
                Log(
                    kLogInfo,
                    "Failed to make thumbnail for image, will bypass: %s"
                        % { thumb_err }
                )
            end
            if not data.thumbnails then
                data.thumbnails = {}
            end
            data.thumbnails[#data.thumbnails + 1] = thumbnail
            local hash = imageu8:gradienthash()
            data.gradienthash = hash
            local similar, s_err = model:findSimilarImageHashes(hash, 3)
            if not similar then
                return nil, TempScraperError(s_err)
            end
            for s_idx = 1, #similar do
                if #similar > 0 then
                    local similar_record = similar[s_idx]
                    duplicates[#duplicates + 1] = {
                        image_id = similar_record.image_id,
                        source_kind = "hash",
                        similarity = (64 - similar_record.distance) / 64 * 100,
                    }
                end
            end
        end
    end
    if task.no_dupe_check then
        return task
    end
    if #duplicates > 0 then
        Log(kLogInfo, "Found duplicates: %s" % { EncodeJson(duplicates) })
        return RequestHelpEntryTask(
            { d = HelpWithDuplicates(task, duplicates) },
            task.discovered_sources
        )
    end
    Log(kLogVerbose, "Found no duplicates by source link")
    return task
end

---@param source_links string[] A list of source links to scrape.
---@return EntryTask? # A database manipulation task to do now that the queue entry has been processed, or nil if there was an error.
---@return ScraperError? # A table with information about the kind of error that occurred, or nil if there was no error.
local function scrape_sources(source_links)
    -- Log(kLogInfo, "source_links: %s" % {EncodeJson(source_links)})
    -- a list containing [ a result containing [ a list containing [ scraped data for one image at the source ] ] ]
    local scraped = table.map(source_links, process_source_uri)
    if #scraped < 1 then
        return nil,
            PermScraperError(
                "I don't know how to scrape data from any of these sources: %s."
                    % { EncodeJson(source_links) }
            )
    end
    -- Log(kLogInfo, "scraped: %s" % {EncodeJson(scraped)})
    -- a list containing [ a list containing [ scraped data for one image at the source ] ]. The outer list has one item per source link in `sources`. The inner arrays are not necessarily all the same size (e.g. FA only ever has one image per link, but Twitter can have up to 4 and Cohost is effectively unlimited.)
    local scraped_no_errors = table.collect_lenient(scraped)
    -- Log(kLogInfo, "scraped_no_errors: %s" % {EncodeJson(scraped_no_errors)})
    if scraped_no_errors:is_err() then
        return nil, scraped_no_errors.err
    end
    scraped_no_errors = scraped_no_errors.result
    if #scraped_no_errors == 1 then
        return FetchEntryTask(scraped_no_errors[1], source_links)
    else
        local max_results =
            math.max(table.unpack(table.map(scraped_no_errors, function(item)
                return #item
            end)))
        if max_results == 1 then
            local largest_source = table.reduce(
                table.flatten(scraped_no_errors),
                ---@param acc ScrapedSourceData
                ---@param next ScrapedSourceData
                ---@return ScrapedSourceData
                function(acc, next)
                    if acc == nil then
                        return next
                    end
                    if next.width > acc.width and next.height > acc.height then
                        return next
                    else
                        return acc
                    end
                end
            )
            if not largest_source then
                return nil,
                    TempScraperError(
                        "I couldn't figure out which source had the largest version of the image. It's possible that they're down."
                    )
            end
            return FetchEntryTask({ largest_source }, source_links)
        else
            return RequestHelpEntryTask({ h = scraped_no_errors }, source_links)
        end
    end
    return nil, PermScraperError("This should be unreachable")
end

local function fetch_record_file(uri)
    local status, headers, body = Fetch(uri)
    if status ~= 200 then
        return nil,
            TempScraperError(
                "I got a %d (%s) error when trying to download the image from '%s'."
                    % { status, headers, uri }
            )
    end
    Log(kLogVerbose, "Successfully fetched record file")
    -- The smallest possible GIF file is 35 bytes, which is smaller than PNG (68 B) or JPEG (119 B). I'm using it as a reasonable minimum for file size.
    -- https://stackoverflow.com/questions/2570633/smallest-filesize-for-transparent-single-pixel-image
    -- https://stackoverflow.com/questions/2253404/what-is-the-smallest-valid-jpeg-file-size-in-bytes
    if #body < 35 then
        return nil,
            TempScraperError(
                "I got an image file that was too small to be real from '%s'."
                    % { uri }
            )
    end
    local content_type = headers["Content-Type"]
    if not content_type then
        return nil,
            PermScraperError(
                "%s didn't tell me what kind of image they sent." % { uri }
            )
    end
    return body, content_type
end

---@param model Model
---@param queue_entry ActiveQueueEntry
---@param task EntryTask
---@return EntryTask
---@overload fun(model: Model, queue_entry: ActiveQueueEntry, task: EntryTask): nil, ScraperError?
local function fetch_files(model, queue_entry, task)
    Log(kLogInfo, "Fetching files…")
    if not task.fetch then
        Log(kLogInfo, "No files to fetch, not a fetch task")
        return task
    end
    for i = 1, #task.fetch do
        local record = task.fetch[i]
        if record.image_data then
            Log(kLogVerbose, "Not downloading, image already has image_data")
        else
            Log(kLogVerbose, "Downloading %s…" % { record.raw_image_uri })
            local body, content_type = fetch_record_file(record.raw_image_uri)
            if not body then
                return nil, PermScraperError(content_type)
            end
            record.image_data = body
            record.mime_type = content_type
        end
        if record.thumbnails then
            for j = 1, #record.thumbnails do
                local thumbnail = record.thumbnails[j]
                local tbody, tcontent_type =
                    fetch_record_file(thumbnail.raw_uri)
                if not tbody then
                    return nil, PermScraperError(tcontent_type)
                end
                thumbnail.image_data = tbody
                thumbnail.mime_type = tcontent_type
            end
        end
    end
    return ArchiveEntryTask(task.fetch, task.discovered_sources)
end

---@param model Model
---@param scraped_data FetchedData[]
---@param queue_entry table
---@return boolean?
---@return ScraperError?
local function save_sources(model, queue_entry, scraped_data, sources_list)
    Log(kLogInfo, "scraped_data: %s" % { EncodeJson(scraped_data) })
    model:create_savepoint(SP_QUEUE)
    local group = nil
    Log(kLogInfo, "#scraped_data: %d" % { #scraped_data })
    if #scraped_data > 1 then
        local name = "Untitled group by "
            .. table.reduce(scraped_data[1].authors, function(acc, next)
                if acc == nil then
                    return next.display_name
                else
                    return acc .. ", " .. next.display_name
                end
            end)
        local errmsg
        group, errmsg = model:createImageGroup(name)
        if not group then
            Log(kLogInfo, "Database error 0: " .. errmsg)
            model:rollback(SP_QUEUE)
            return nil, TempScraperError(errmsg)
        end
    end
    for _, data in ipairs(scraped_data) do
        local sources_with_dupes = {
            data.this_source,
        }
        if sources_list then
            for _, source in ipairs(sources_list) do
                table.insert(sources_with_dupes, source)
            end
        end
        if data.additional_sources then
            for _, source in ipairs(data.additional_sources) do
                table.insert(sources_with_dupes, source)
            end
        end
        local this_item_sources = table.uniq(sources_with_dupes)
        -- Add image, sources, etc. to database and save to disk.
        local image, errmsg2 = model:insertImage(
            data.image_data,
            data.mime_type,
            data.width,
            data.height,
            data.kind,
            data.rating
        )
        if not image then
            Log(kLogInfo, "Database error 1: %s" % { errmsg2 })
            model:rollback(SP_QUEUE)
            return nil, PermScraperError(errmsg2)
        end
        Log(
            kLogInfo,
            "Inserted image record into database (result: %s)" % { image }
        )
        Log(kLogInfo, "Sources (deduped): " .. EncodeJson(this_item_sources))
        local ok, errmsg4 =
            model:insertSourcesForImage(image.image_id, this_item_sources)
        if not ok then
            Log(kLogInfo, "Database error 2: " .. errmsg4)
            model:rollback(SP_QUEUE)
            return nil, TempScraperError(errmsg4)
        end
        for _, author in ipairs(data.authors) do
            local result2, errmsg3 = model:createOrAssociateArtistWithImage(
                image.image_id,
                data.canonical_domain,
                author
            )
            if not result2 then
                Log(kLogInfo, "Database error 3: " .. errmsg3)
                model:rollback(SP_QUEUE)
                return nil, TempScraperError(errmsg3)
            end
        end
        if data.incoming_tags then
            local add_tags_ok, add_tags_err = model:addIncomingTagsForImage(
                image.image_id,
                data.canonical_domain,
                data.incoming_tags
            )
            if not add_tags_ok then
                Log(kLogInfo, "Error adding tags: " .. tostring(add_tags_err))
                model:rollback(SP_QUEUE)
                return nil, TempScraperError(add_tags_err)
            end
        end
        if group then
            local result5, errmsg5 =
                model:addImageToGroupAtEnd(image.image_id, group.ig_id)
            if not result5 then
                Log(kLogInfo, "Database error 4: " .. errmsg5)
                model:rollback(SP_QUEUE)
                return nil, TempScraperError(errmsg5)
            end
        end
        if data.thumbnails then
            for i = 1, #data.thumbnails do
                local thumbnail = data.thumbnails[i]
                local t_ok, t_err = model:insertThumbnailForImage(
                    image.image_id,
                    thumbnail.image_data,
                    thumbnail.width,
                    thumbnail.height,
                    thumbnail.scale,
                    thumbnail.mime_type
                )
                if not t_ok then
                    model:rollback(SP_QUEUE)
                    return nil, TempScraperError(t_err)
                end
            end
        end
        if data.gradienthash then
            local h_ok, h_err =
                model:insertImageHash(image.image_id, data.gradienthash)
            if not h_ok then
                model:rollback(SP_QUEUE)
                return nil, TempScraperError(h_err)
            end
        end
    end
    local ok, errmsg3 =
        model:setQueueItemStatusAndDescription(queue_entry.qid, 2, "")
    if not ok then
        model:rollback(SP_QUEUE)
        return nil,
            TempScraperError(
                "Unable to mark the now-completed queue entry as complete: "
                    % { errmsg3 }
            )
    end
    model:release_savepoint(SP_QUEUE)
    return true
end

---@param model Model
---@param queue_entry table
---@param error ScraperError
local function handle_queue_error(model, queue_entry, error)
    local model_function = model.setQueueItemStatusAndDescription
    if error.type == 3 then
        model_function = model.setQueueItemStatusOnly
    end
    local status_result, errmsg2 =
        model_function(model, queue_entry.qid, error.type, error.description)
    if not status_result then
        Log(kLogWarn, "While processing queue for user %d, item %d: %s" % {
            model.user_id,
            queue_entry.qid,
            errmsg2,
        })
    end
    if queue_entry.tg_message_id then
        Bot.update_queue_message_with_status(
            queue_entry.tg_chat_id,
            queue_entry.tg_message_id,
            "Error: " .. error.description
        )
    end
end

local function queue_entry_tostr(queue_entry)
    local result = {}
    for key, value in pairs(queue_entry) do
        if type(value) == "string" and #value > 512 then
            local prefix = value:sub(1, 256)
            local suffix = value:sub(#value - 256)
            value = VisualizeControlCodes(
                "%s[elided to prevent log spam]%s" % { prefix, suffix }
            )
        end
        result[key] = value
    end
    return EncodeJson(result)
end

-- TODO: also base64 the thumbnail's image_data key
---@return string?
local function serialize_task(task, discovered_sources)
    if task.d and task.d.original_task and task.d.original_task.archive then
        local archive_task = task.d.original_task.archive
        for i = 1, #archive_task do
            local scraped_data = archive_task[i]
            if scraped_data.image_data then
                scraped_data.image_data = EncodeBase64(scraped_data.image_data)
            end
            if scraped_data.thumbnails then
                for j = 1, #scraped_data.thumbnails do
                    local thumb = scraped_data.thumbnails[j]
                    if thumb.image_data then
                        thumb.image_data = EncodeBase64(thumb.image_data)
                    end
                end
            end
        end
    end
    task.discovered_sources = discovered_sources
    return EncodeJson(task)
end

local function deserialize_task(task_str)
    local task, json_err = DecodeJson(task_str)
    if not task then
        return nil, json_err
    end
    if task.d and task.d.original_task and task.d.original_task.archive then
        local archive_task = task.d.original_task.archive
        for i = 1, #archive_task do
            local scraped_data = archive_task[i]
            if scraped_data and scraped_data.image_data then
                scraped_data.image_data = DecodeBase64(scraped_data.image_data)
            end
            if scraped_data and scraped_data.thumbnails then
                for j = 1, #scraped_data.thumbnails do
                    local thumb = scraped_data.thumbnails[j]
                    if thumb and thumb.image_data then
                        thumb.image_data = DecodeBase64(thumb.image_data)
                    end
                end
            end
        end
    end
    return task
end

local function execute_task(model, queue_entry, task)
    if task.archive then
        local ok, error2 = save_sources(
            model,
            queue_entry,
            task.archive,
            task.discovered_sources
        )
        if not ok then
            ---@cast error2 ScraperError
            return nil, error2
        end
        if queue_entry.tg_message_id then
            Bot.update_queue_message_with_status(
                queue_entry.tg_chat_id,
                queue_entry.tg_message_id,
                "Archived!"
            )
        end
        return true
    elseif task.help then
        local json_task = serialize_task(task.help, task.discovered_sources)
        local ok, errmsg3 =
            model:setQueueItemDisambiguationRequest(queue_entry.qid, json_task)
        if not ok then
            Log(kLogWarn, "%s" % { errmsg3 })
        end
        if queue_entry.tg_message_id then
            Bot.update_queue_message_with_status(
                queue_entry.tg_chat_id,
                queue_entry.tg_message_id,
                "I need help to figure this one out: https://werehouse.s0ph0s.dog/queue/%d/help"
                    % { queue_entry.qid }
            )
        end
        return true
    elseif task.noop then
        -- intentionally do nothing
        return true
    else
        Log(
            kLogFatal,
            "Unhandled task from process_entry: %s" % { EncodeJson(task) }
        )
        -- Execution stops after a fatal log event.
        return false
    end
end

local function task_for_scraping(queue_entry)
    local sources, find_src_err = get_sources_for_entry(queue_entry)
    if not sources then
        return nil,
            TempScraperError(
                "I couldn't find sources for %s: %s"
                    % { queue_entry.qid, find_src_err }
            )
    end
    if type(sources) == "table" and #sources < 1 then
        return nil,
            PermScraperError(
                "No sources found for this image in the FuzzySearch or Fluffle.xyz databases"
            )
    end
    local task, scrape_err = scrape_sources(sources)
    if not task then
        return nil, scrape_err
    end
    return task
end

local function task_for_answering_disambiguation_req(queue_entry)
    local disambiguation_request = queue_entry.disambiguation_request
    if not disambiguation_request then
        return NoopEntryTask
    end
    local dr, req_err = deserialize_task(queue_entry.disambiguation_request)
    if not dr or req_err then
        Log(kLogWarn, "error decoding JSON from queue: %s" % { req_err })
        return NoopEntryTask
    end
    if dr.d then
        if not queue_entry.disambiguation_data then
            return NoopEntryTask
        end
        local response, data_err = DecodeJson(queue_entry.disambiguation_data)
        if not response or data_err then
            Log(kLogWarn, "error decoding JSON from queue: %s" % { data_err })
            return NoopEntryTask
        end
        if not response.d then
            Log(
                kLogVerbose,
                "There's a response to the disambiguation request for %d, but it doesn't answer the current question."
                    % { queue_entry.qid }
            )
            return NoopEntryTask
        end
        if response.d == "discard" then
            return nil,
                PermScraperError(
                    "Duplicate of existing image, user-requested error"
                )
        elseif response.d == "save" then
            local new_task = dr.d.original_task
            new_task.no_dupe_check = true
            new_task.discovered_sources = dr.discovered_sources
            Log(kLogInfo, "Returning task: %s" % { EncodeJson(new_task) })
            ---@cast new_task FetchEntryTask
            return new_task
        else
            return nil,
                PermScraperError(
                    "Unexpected response to request for help (wanted %s): %s"
                        % { "{'d': something}", queue_entry.disambiguation_data }
                )
        end
        return nil, PermScraperError("Should be unreachable")
    elseif dr.h then
        if not queue_entry.disambiguation_data then
            return NoopEntryTask
        end
        local response, data_err = DecodeJson(queue_entry.disambiguation_data)
        if not response or data_err then
            Log(kLogWarn, "error decoding JSON from queue: %s" % { data_err })
            return NoopEntryTask
        end
        if not response.h then
            Log(
                kLogVerbose,
                "There's a response to the disambiguation request for %d, but it doesn't answer the current question."
                    % { queue_entry.qid }
            )
            return NoopEntryTask
        end
        local new_task = FetchEntryTask(response.h, dr.discovered_sources)
        return new_task
    end
    return NoopEntryTask
end

---@param queue_entry ActiveQueueEntry
---@return EntryTask?
---@return ScraperError?
local function task_for_entry(_, queue_entry, _)
    -- NOTE: DO NOT USE THE FIRST OR THIRD PARAMETERS TO THIS FUNCTION!
    -- The first one is the database model, which should not be consulted when creating the task. Given a particular queue entry, the output of this function should only depend on network calls.
    -- The third one is always nil, because there is no prior task.

    -- These states are possible, but filtered out by the query that selects active queue entries.
    --[[
    -- Dead -> Dead
    if queue_entry.tombstone == 1 then
        return NoopEntryTask
    end
    -- Archived -> Archived
    if queue_entry.tombstone == 2 then
        return NoopEntryTask
    end
    ]]
    -- NeedsHelp -> Archived
    if queue_entry.disambiguation_data then
        return task_for_answering_disambiguation_req(queue_entry)
    end
    -- NeedsHelp -> NeedsHelp
    if queue_entry.disambiguation_request then
        -- Do nothing here because we're waiting for the user to disambiguate.
        return NoopEntryTask
    end
    -- Queued -> Dead
    if queue_entry.retry_count > 4 then
        return nil, RetryExceededScraperError()
    end
    -- Queued -> (NeedsHelp, Dead, Archived)
    return task_for_scraping(queue_entry)
end

local function increment_retry_count(model, queue_entry, task)
    if not task or task.archive then
        local rt_ok, rt_err =
            model:incrementQueueItemRetryCount(queue_entry.qid)
        if not rt_ok then
            Log(kLogInfo, "Unable to update queue retry count: %s" % { rt_err })
        end
    end
    return task
end

---@type PipelineFunction[]
local entry_pipeline = {
    task_for_entry,
    increment_retry_count,
    fetch_files,
    check_for_duplicates,
    execute_task,
}

local function process_entry(model, queue_entry)
    Log(
        kLogInfo,
        "Processing queue entry %s" % { queue_entry_tostr(queue_entry) }
    )
    local task, step_err = nil, nil
    for i = 1, #entry_pipeline do
        Log(kLogVerbose, "Process entry pipeline step %d" % { i })
        local step = entry_pipeline[i]
        task, step_err = step(model, queue_entry, task)
        if not task then
            handle_queue_error(model, queue_entry, step_err)
            return
        end
    end
end

---@param model Model
---@param queue_records ActiveQueueEntry[]
local function process_queue(model, queue_records)
    for _, queue_entry in ipairs(queue_records) do
        process_entry(model, queue_entry)
    end
end

local function process_all_queues()
    local user_ids, errmsg = Accounts:getAllUserIds()
    if not user_ids then
        Log(kLogWarn, errmsg)
        return
    end
    Log(kLogInfo, "Beginning queue processing.")
    for _, user_id in ipairs(user_ids) do
        user_id = user_id.user_id
        Log(kLogInfo, "Beginning queue processing for user %s" % { user_id })
        ---@type Model
        local model = DbUtil.Model:new(nil, user_id)
        local queue_records, errmsg2 = model:getAllActiveQueueEntries()
        if queue_records then
            Log(
                kLogInfo,
                "Processing %d queue entries for %s"
                    % { #queue_records, user_id }
            )
            -- Use pcall to isolate each user's queue processing. That way, if
            -- one user has something in their queue that causes a problem, it
            -- doesn't mean that everyone after them gets blocked too.
            local q_ok, q_err =
                xpcall(process_queue, debug.traceback, model, queue_records)
            if not q_ok then
                Log(
                    kLogWarn,
                    "Error occurred while processing queue for user %s: %s"
                        % { user_id, q_err }
                )
            end
        else
            Log(kLogWarn, errmsg2)
        end
        Log(
            kLogInfo,
            "Finished processing queue entries for user %s" % { user_id }
        )
        model.conn:close()
    end
    Log(kLogInfo, "Ending queue processing.")
end

return {
    process_all_queues = process_all_queues,
    can_process_uri = can_process_uri,
    process_entry = process_entry,
    scrape_sources = scrape_sources,
    multipart_body = fuzzysearch_multipart_body,
    CANONICAL_DOMAINS_WITH_TAGS = CANONICAL_DOMAINS_WITH_TAGS,
    REVERSE_SEARCHABLE_MIME_TYPES = REVERSE_SEARCHABLE_MIME_TYPES,
}

require "scraper_types"

local FUZZYSEARCH_API_KEY = os.getenv("FUZZYSEARCH_API_KEY")
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
    require_only("scrapers.test"),
}

local MIME_TO_EXT = {
    ["image/jpeg"] = ".jpg",
    ["image/png"] = ".png",
    ["image/webp"] = ".webp",
}

local function multipart_body(boundary, image_data, content_type)
    local result = [[--%s\r\nContent-Disposition: form-data; name="image"\r\nContent-Type: %s\r\n\r\n%s\r\n--%s--\r\n\r\n]] % {
        boundary,
        content_type,
        image_data,
        boundary,
    }
    return result
end

local function transform_fuzzysearch_response(json)
    return table.filtermap(
        json,
        function (result) return result.distance < 10 end,
        function (result) return result.url end
    )
end

local function fuzzysearch_uri(image_uri)
    local api_url = EncodeUrl{
        scheme = "https",
        host = "api-next.fuzzysearch.net",
        path = "/v1/url",
        params = { {"url", image_uri}, }
    }
    local json, errmsg = Nu.FetchJson(api_url, {
        headers = {
            ["x-api-key"] = FUZZYSEARCH_API_KEY,
        }
    })
    if not json and errmsg then
        return nil, errmsg
    end
    return transform_fuzzysearch_response(json)
end

local function fuzzysearch_image(image_data, mime_type)
    local api_url = EncodeUrl{
        scheme = "https",
        host = "api-next.fuzzysearch.net",
        path = "/v1/image",
    }
    local boundary = "__X_HELLO_SYFARO__"
    local body = multipart_body(boundary, image_data, mime_type)
    local json, errmsg = Nu.FetchJson(api_url, {
        method = "POST",
        headers = {
            ["Content-Type"] = "multipart/form-data; charset=utf-8; boundary=%s" % {boundary},
            ["x-api-key"] = FUZZYSEARCH_API_KEY,
        },
        body = body,
    })
    if not json and errmsg then
        return nil, errmsg
    end
    return transform_fuzzysearch_response(json)
end

local function hash_to_filesystem_safe(hash)
    local b64 = EncodeBase64(hash)
    local safe = b64:gsub("[+/]", { ["+"] = "-", ["/"] = "_" })
    return safe
end

local function save_image(image_data, image_mime_type)
    local hash_raw = GetCryptoHash("SHA256", image_data)
    local hash = hash_to_filesystem_safe(hash_raw)
    local ext = MIME_TO_EXT[image_mime_type] or ""
    local filename = hash .. ext
    local parent_dir = "./images/%s/%s/" % {
        hash:sub(1, 2),
        hash:sub(3, 2),
    }
    Log(kLogInfo, "parent_dir: %s" % {parent_dir})
    local path = parent_dir .. filename
    unix.makedirs(parent_dir, 0755)
    Barf(path, image_data, 0644, unix.O_WRONLY | unix.O_CREAT | unix.O_EXCL)
    return filename
end

---@param uri (string) A single URI pointing to a webpage on an art gallery or social media site at which an artist has posted an image.
---@return Result<ScrapedSourceData, ScraperError> # All of the scraped data objects from the first scraper that could process the URI.
local function process_source_uri(uri)
    for _, scraper in ipairs(scrapers) do
        if scraper.can_process_uri(uri) then
            return scraper.process_uri(uri)
        end
    end
    return Err(PermScraperError("No scrapers could process %s" % {uri}))
end


local function get_sources_for_entry(queue_entry)
    if queue_entry.link then
        local status, headers, _ = Fetch(queue_entry.link, {method = "HEAD"})
        if not status then
            return nil, "%s while fetching %s" % {headers, queue_entry.link}
        elseif status == 405 then
            -- If status is 405, assume it's not a raw image URL. Most image CDNs don't disallow HEAD (for caching/performance reasons)
            return { queue_entry.link }
        elseif status ~= 200 then
            return nil, "%d while fetching %s" % {status, queue_entry.link}
        elseif headers["Content-Type"] and headers["Content-Type"]:startswith("image/") then
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
        local maybe_source_links, errmsg2 = fuzzysearch_image(queue_entry.image_data)
        if not maybe_source_links then
            return nil, errmsg2
        end
        return maybe_source_links
    else
        return nil, "No link or image data for queue entry %s" % {queue_entry.qid}
    end
    return nil, "should be unreachable"
end


---@param queue_entry table Queue entry from the database
---@return EntryTask? # A database manipulation task to do now that the queue entry has been processed, or nil if there was an error.
---@return ScraperError? # A table with information about the kind of error that occurred, or nil if there was no error.
local function process_entry(queue_entry)
    if queue_entry.disambiguation_results then
        -- TODO: implement disambiguation.
        return NoopEntryTask
    end
    if queue_entry.disambiguation_request then
        -- Do nothing here because we're waiting for the user to disambiguate.
        return NoopEntryTask
    end
    local source_links, errmsg1 = get_sources_for_entry(queue_entry)
    if not source_links or (type(source_links) == "table" and #source_links < 1) then
        return nil, TempScraperError("I couldn't find sources for %s: %s" % {queue_entry.qid, errmsg1})
    end
    ---@cast source_links string[]
    Log(kLogInfo, "source_links: %s" % {EncodeJson(source_links)})
    -- a list containing [ a result containing [ a list containing [ scraped data for one image at the source ] ] ]
    local scraped = table.map(source_links, process_source_uri)
    if #scraped < 1 then
        return nil, PermScraperError("I don't know how to scrape data from any of these sources: %s." % {EncodeJson(source_links)})
    end
    Log(kLogInfo, "scraped: %s" % {EncodeJson(scraped)})
    -- a list containing [ a list containing [ scraped data for one image at the source ] ]. The outer list has one item per source link in `sources`. The inner arrays are not necessarily all the same size (e.g. FA only ever has one image per link, but Twitter can have up to 4 and Cohost is effectively unlimited.)
    local scraped_no_errors = table.map(
        scraped,
        ---@generic T
        ---@generic E
        ---@param item Result
        ---@return `T`
        function(item) return item:unwrap_or{} end
    )
    ---@cast scraped_no_errors ScrapedSourceData[][]
    Log(kLogInfo, "scraped_no_errors: %s" % {EncodeJson(scraped_no_errors)})
    local result_count = table.reduce(
        table.map(
            scraped_no_errors,
            function (x) return #x end
        ),
        function (acc, next) return (acc or 0) + next end
    )
    if result_count < 1 then
        return nil, TempScraperError("All of the scrapers failed to scrape from these sources: %s" % {EncodeJson(source_links)})
    end
    if #scraped_no_errors == 1 then
        return ArchiveEntryTask(scraped_no_errors[1])
    else
        local max_results = math.max(
            table.unpack(table.map(
                scraped,
                function (item) return #item end
            ))
        )
        if max_results == 1 then
            local largest_source = table.reduce(
                table.flatten(scraped_no_errors),
                ---@param acc ScrapedSourceData
                ---@param next ScrapedSourceData
                ---@return ScrapedSourceData
                function (acc, next)
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
                return nil, TempScraperError("I couldn't figure out which source had the largest version of the image. It's possible that they're down.")
            end
            return ArchiveEntryTask{largest_source}
        else
            return RequestHelpEntryTask(scraped)
        end
    end
    return nil, PermScraperError("This should be unreachable")
end

---@param model Model
---@param sources_list ScrapedSourceData[]
---@param queue_entry table
---@return boolean?
---@return ScraperError?
local function save_sources(model, queue_entry, sources_list)
    Log(kLogInfo, "data: %s" % {EncodeJson(sources_list)})
    -- TODO: rewrite this to loop over the sources list and save all of the images in one transaction.
    local status, headers, body = Fetch(data.raw_image_uri)
    if status ~= 200 then
        return nil, TempScraperError("I got a %d (%s) error when trying to download the image from '%s'." % {status, headers, data.raw_image_uri})
    end
    if #body < 1024 then
        return nil, TempScraperError("I got an image file that was too small to be real from '%s'." % {data.raw_image_uri})
    end
    if not headers["Content-Type"] then
        return nil, PermScraperError("%s didn't tell me what kind of image they sent." % {data.raw_image_uri})
    end
    local content_type = headers["Content-Type"]
    local filename = save_image(body, content_type)
    Log(kLogInfo, "Saved image to disk")
    local result, errmsg2 = model:insertImageAndRemoveFromQueue(queue_entry.qid, filename, content_type)
    if not result then
        Log(kLogInfo, "Database error: %s" % {errmsg2})
        return nil, TempScraperError(errmsg2)
    end
    Log(kLogInfo, "Inserted image record into database (result: %d)" % {result})
    return true
end

local function process_queue(model, queue_records)
    for _, queue_entry in ipairs(queue_records) do
        Log(kLogInfo, "Processing queue entry %s" % {EncodeJson(queue_entry)})
        local result, errmsg1 = process_entry(queue_entry)
        if not result then
            local status_result, errmsg2 = model:setQueueItemStatus(
                queue_entry.qid,
                errmsg1
            )
            if not status_result then
                Log(kLogWarn,
                    "While processing queue for user %d, item %d: %s" % {
                        model.user_id,
                        queue_entry.qid,
                        errmsg2
                    })
            end
        else
            local ok, errmsg2 = save_sources(model, queue_entry, result)
            if not ok then
                Log(kLogWarn, "%s" % {errmsg2})
            end
        end
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
        Log(kLogInfo, "Beginning queue processing for user %s" % {user_id})
        local model = DbUtil.Model:new(nil, user_id)
        local queue_records, errmsg2 = model:getAllActiveQueueEntries()
        if queue_records then
            Log(kLogInfo, "Processing %d queue entries for %s" % {#queue_records, user_id})
            process_queue(model, queue_records)
        else
            Log(kLogWarn, errmsg2)
        end
        Log(kLogInfo, "Finished processing queue entries for user %s" % {user_id})
    end
    Log(kLogInfo, "Ending queue processing.")
end

return {
    process_all_queues = process_all_queues,
    process_entry = process_entry,
}

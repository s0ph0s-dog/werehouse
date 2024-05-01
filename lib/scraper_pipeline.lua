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
    require_only("scrapers.test"),
}

local MIME_TO_EXT = {
    ["image/jpeg"] = ".jpg",
    ["image/png"] = ".png",
    ["image/webp"] = ".webp",
    ["text/plain"] = ".txt",
}

local function multipart_body(boundary, image_data, content_type)
    local result = '--%s\r\nContent-Disposition: form-data; name="image"; filename="purple%s"\r\nContent-Type: %s\r\n\r\n%s\r\n--%s--\r\n\r\n'
        % {
            boundary,
            MIME_TO_EXT[content_type],
            content_type,
            image_data,
            boundary,
        }
    return result
end

local function transform_fuzzysearch_response(json)
    return table.filtermap(json, function(result)
        return result.distance < 10
    end, function(result)
        return result.url
    end)
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
    local body = multipart_body(boundary, image_data, mime_type)
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
    if parts.host == "twitter.com" or parts.host == "vxtwitter.com" then
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
    return false
end

---@return boolean # true if this URL should be checked with FuzzySearch, false if it can be handled internally.
---@return string? errmsg An error message, if one occurred.
local function guess_with_head(link)
    local status, headers, _ = Fetch(link, { method = "HEAD" })
    if not status then
        return false, "%s while fetching %s" % { link }
    elseif status == 405 then
        -- If status is 405, assume it's not a raw image URL. Most image CDNs don't disallow HEAD (for caching/performance reasons)
        return false
    elseif status ~= 200 then
        return false, "%d while fetching %s" % { status, link }
    elseif
        headers["Content-Type"] and headers["Content-Type"]:startswith("image/")
    then
        return true
    else
        return false
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
                return nil, errmsg
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
        local maybe_source_links, errmsg2 =
            fuzzysearch_image(queue_entry.image, queue_entry.image_mime_type)
        if not maybe_source_links then
            return nil, errmsg2
        end
        return maybe_source_links
    else
        return nil,
            "No link or image data for queue entry %s" % { queue_entry.qid }
    end
    return nil, "should be unreachable"
end

---@param model Model
---@param task ArchiveEntryTask
local function check_duplicates(model, task)
    assert(
        task.archive ~= nil,
        "check_duplicates function only works with archive tasks"
    )
    local sources_with_dupes = {}
    if task.discovered_sources then
        for _, source in ipairs(task.discovered_sources) do
            table.insert(sources_with_dupes, source)
        end
    end
    for _, data in ipairs(task.archive) do
        table.insert(sources_with_dupes, data.this_source)
        if data.additional_sources then
            for _, source in ipairs(data.additional_sources) do
                table.insert(sources_with_dupes, data.additional_sources)
            end
        end
    end
    local this_item_sources = table.uniq(sources_with_dupes)
    local dupes, dupe_err = model:checkDuplicateSources(this_item_sources)
    if not dupes or dupe_err then
        return TempScraperError(dupe_err)
    end
    if #dupes > 0 then
        Log(kLogInfo, "Found duplicates: %s" % { EncodeJson(dupes) })
        return PermScraperError(
            "This source has been saved already: %s" % { EncodeJson(dupes) }
        )
    end
    Log(kLogVerbose, "Found no duplicates by source link")
    return nil
end

---@param queue_entry ActiveQueueEntry Queue entry from the database
---@return EntryTask? # A database manipulation task to do now that the queue entry has been processed, or nil if there was an error.
---@return ScraperError? # A table with information about the kind of error that occurred, or nil if there was no error.
local function process_entry(queue_entry)
    if queue_entry.disambiguation_data then
        -- TODO: implement disambiguation.
        return NoopEntryTask
    end
    if queue_entry.disambiguation_request then
        -- Do nothing here because we're waiting for the user to disambiguate.
        return NoopEntryTask
    end

    local source_links, errmsg1 = get_sources_for_entry(queue_entry)
    if
        not source_links
        or (type(source_links) == "table" and #source_links < 1)
    then
        return nil,
            TempScraperError(
                "I couldn't find sources for %s: %s"
                    % { queue_entry.qid, errmsg1 }
            )
    end
    ---@cast source_links string[]
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
        return ArchiveEntryTask(scraped_no_errors[1], source_links)
    else
        local max_results =
            math.max(table.unpack(table.map(scraped, function(item)
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
            return ArchiveEntryTask({ largest_source }, source_links)
        else
            return RequestHelpEntryTask(scraped, source_links)
        end
    end
    return nil, PermScraperError("This should be unreachable")
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
    local parent_dir = "./images/%s/%s/"
        % {
            hash:sub(1, 1),
            hash:sub(2, 2),
        }
    Log(kLogInfo, "parent_dir: %s" % { parent_dir })
    local path = parent_dir .. filename
    unix.makedirs(parent_dir, 0755)
    Barf(path, image_data, 0644, unix.O_WRONLY | unix.O_CREAT | unix.O_EXCL)
    return filename
end

---@param model Model
---@param scraped_data ScrapedSourceData[]
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
        -- 1. Download image file.
        local status, headers, body = Fetch(data.raw_image_uri)
        if status ~= 200 then
            model:rollback(SP_QUEUE)
            return nil,
                TempScraperError(
                    "I got a %d (%s) error when trying to download the image from '%s'."
                        % { status, headers, data.raw_image_uri }
                )
        end
        Log(kLogVerbose, "Successfully fetched image")
        -- The smallest possible GIF file is 35 bytes, which is smaller than PNG (68 B) or JPEG (119 B). I'm using it as a reasonable minimum for file size.
        -- https://stackoverflow.com/questions/2570633/smallest-filesize-for-transparent-single-pixel-image
        -- https://stackoverflow.com/questions/2253404/what-is-the-smallest-valid-jpeg-file-size-in-bytes
        if #body < 35 then
            model:rollback(SP_QUEUE)
            return nil,
                TempScraperError(
                    "I got an image file that was too small to be real from '%s'."
                        % { data.raw_image_uri }
                )
        end
        if not headers["Content-Type"] then
            model:rollback(SP_QUEUE)
            return nil,
                PermScraperError(
                    "%s didn't tell me what kind of image they sent."
                        % { data.raw_image_uri }
                )
        end
        local content_type = headers["Content-Type"]
        -- 2. Save image file to disk.
        local filename = save_image(body, content_type)
        Log(kLogInfo, "Saved image to disk")
        -- 3. Add image, sources, etc. to database.
        local image, errmsg2 =
            model:insertImage(filename, content_type, data.width, data.height)
        if not image then
            Log(kLogInfo, "Database error 1: %s" % { errmsg2 })
            model:rollback(SP_QUEUE)
            return nil, TempScraperError(errmsg2)
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
        if group then
            local result5, errmsg5 =
                model:addImageToGroupAtEnd(image.image_id, group.ig_id)
            if not result5 then
                Log(kLogInfo, "Database error 4: " .. errmsg5)
                model:rollback(SP_QUEUE)
                return nil, TempScraperError(errmsg5)
            end
        end
    end
    local ok, errmsg3 = model:setQueueItemStatus(queue_entry.qid, 2, "Archived")
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
    local permanent = false
    if error.type == 1 then
        permanent = true
    end
    local status_result, errmsg2 =
        model:setQueueItemStatus(queue_entry.qid, permanent, error.description)
    if not status_result then
        Log(kLogWarn, "While processing queue for user %d, item %d: %s" % {
            model.user_id,
            queue_entry.qid,
            errmsg2,
        })
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

---@param model Model
---@param queue_records ActiveQueueEntry[]
local function process_queue(model, queue_records)
    for _, queue_entry in ipairs(queue_records) do
        Log(
            kLogInfo,
            "Processing queue entry %s" % { queue_entry_tostr(queue_entry) }
        )
        local task, error = process_entry(queue_entry)
        if not task then
            ---@cast error ScraperError
            handle_queue_error(model, queue_entry, error)
        else
            if task.archive then
                local dupe_err = check_duplicates(model, task)
                if dupe_err then
                    handle_queue_error(model, queue_entry, dupe_err)
                else
                    local ok, error2 = save_sources(
                        model,
                        queue_entry,
                        task.archive,
                        task.discovered_sources
                    )
                    if not ok then
                        ---@cast error2 ScraperError
                        handle_queue_error(model, queue_entry, error2)
                    end
                end
            elseif task.help then
                local ok, errmsg3 = model:setQueueItemDisambiguationRequest(
                    queue_entry.qid,
                    task
                )
                if not ok then
                    Log(kLogWarn, "%s" % { errmsg3 })
                end
            elseif task.noop then
                -- intentionally do nothing
            else
                Log(
                    kLogFatal,
                    "Unhandled task from process_entry: %s"
                        % { EncodeJson(task) }
                )
                -- Execution stops after a fatal log event.
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
            process_queue(model, queue_records)
        else
            Log(kLogWarn, errmsg2)
        end
        Log(
            kLogInfo,
            "Finished processing queue entries for user %s" % { user_id }
        )
    end
    Log(kLogInfo, "Ending queue processing.")
end

return {
    process_all_queues = process_all_queues,
    process_entry = process_entry,
    multipart_body = multipart_body,
}

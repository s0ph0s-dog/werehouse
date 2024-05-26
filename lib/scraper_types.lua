---@alias ScrapedAuthor { handle: string, display_name: string, profile_url: string }

--- The data produced by a scraper.
---@alias ScrapedSourceData { raw_image_uri: string, mime_type: string, width: integer, height: integer, this_source: string, additional_sources: string[]?, canonical_domain: string, authors: ScrapedAuthor[], rating: integer, incoming_tags: string[]? }

--- ScraperProcess function: given a URI, scrape whatever info is needed for archiving
--- from that website.
---@alias ScraperProcess fun(uri: string): Result<ScrapedSourceData, string>

--- ScraperCanProcess: given a URI, inform the pipeline whether the associated
--- scraper is able to process that URI.
---@alias ScraperCanProcess fun(uri: string): boolean

---@alias Scraper {process_uri: ScraperProcess, can_process_uri: ScraperCanProcess}

---@alias DuplicateData { url: string, image_id: integer, source_kind: string }
---@alias HelpWithDuplicates { original_task: ArchiveEntryTask, duplicates: DuplicateData[]}
function HelpWithDuplicates(original_task, duplicates)
    return { original_task = original_task, duplicates = duplicates }
end

---@alias HelpWithHeuristicFailure ArchiveEntryTask
function HelpWithHeuristicFailure(original_task)
    return original_task
end

---@alias ArchiveEntryTask { archive: ScrapedSourceData[], discovered_sources: string[] }
function ArchiveEntryTask(data, discovered_sources)
    if discovered_sources and #discovered_sources == 1 then
        discovered_sources = nil
    end
    return { archive = data, discovered_sources = discovered_sources }
end
---@alias RequestHelpEntryTask { help: { d: HelpWithDuplicates?, h: HelpWithHeuristicFailure? }, discovered_sources: string[] }
function RequestHelpEntryTask(data, discovered_sources)
    if discovered_sources and #discovered_sources == 1 then
        discovered_sources = nil
    end
    return { help = data, discovered_sources = discovered_sources }
end
---@alias NoopEntryTask { noop: true }
NoopEntryTask = { noop = true }
---@alias EntryTask (ArchiveEntryTask|RequestHelpEntryTask|NoopEntryTask)

---@class ScraperError {description: string, type: integer}
ScraperError = {
    description = "Something went so wrong that I couldn't even describe it.",
    type = -1,
}

---@class TempScraperError : ScraperError
function TempScraperError(description)
    if not description then
        return error(
            "Must provide a non-nil description when calling this function."
        )
    end
    local result = {
        description = description,
        type = 0,
    }
    setmetatable(result, { __index = ScraperError })
    return result
end
---@class PermScraperError : ScraperError
function PermScraperError(description)
    if not description then
        return error(
            "Must provide a non-nil description when calling this function."
        )
    end
    local result = {
        description = description,
        type = 1,
    }
    setmetatable(result, { __index = ScraperError })
    return result
end
---@class RetryExceededScraperError : PermScraperError
function RetryExceededScraperError()
    local result = {
        description = "Retry count exceeded, something is broken.",
        type = 3,
    }
    setmetatable(result, { __index = ScraperError })
    return result
end

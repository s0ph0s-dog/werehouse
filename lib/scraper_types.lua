
--- The data produced by a scraper.
---@alias ScrapedSourceData { raw_image_uri: string, mime_type: string, width: integer, height: integer }

--- ScraperProcess function: given a URI, scrape whatever info is needed for archiving
--- from that website.
---@alias ScraperProcess fun(uri: string): Result<ScrapedSourceData, string>

--- ScraperCanProcess: given a URI, inform the pipeline whether the associated
--- scraper is able to process that URI.
---@alias ScraperCanProcess fun(uri: string): boolean

---@alias Scraper {process_uri: ScraperProcess, can_process_uri: ScraperCanProcess}

---@alias ArchiveEntryTask { archive: ScrapedSourceData[] }
function ArchiveEntryTask(data)
    return { archive = data }
end
---@alias RequestHelpEntryTask { help: ScrapedSourceData[][] }
function RequestHelpEntryTask(data)
    return { help = data }
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
        return error("Must provide a non-nil description when calling this function.")
    end
    local result = {
        description = description,
        type = 0
    }
    setmetatable(result, {__index = ScraperError})
    return result
end
---@class PermScraperError : ScraperError
function PermScraperError(description)
    if not description then
        return error("Must provide a non-nil description when calling this function.")
    end
    local result = {
        description = description,
        type = 1
    }
    setmetatable(result, {__index = ScraperError})
    return result
end

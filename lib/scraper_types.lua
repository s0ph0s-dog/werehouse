---@enum QueueStatus
QueueStatus = {
    ToDo = 0,
    Error = 1,
    Archived = 2,
    RetryLimitReached = 4,
    Discarded = 5,
}

---@class (exact) ScrapedAuthor
---@field handle string The author's handle on the site. Also called a username.
---@field display_name string The author's display name on the site. For sites which do not distinguish between a display name and a username, put the same value here.
---@field profile_url string The URL for the author's profile page on the site.
ScrapedAuthor = {}

--- A thumbnail for a record, if the scraper can provide one. Most useful for videos.
---@class (exact) Thumbnail
---@field image_data string The encoded image data of the thumbnail image.
---@field mime_type string The MIME type of the thumbnail image.
---@field width integer The width of the thumbnail image in pixels.
---@field height integer The height of the thumbnail image in pixels.
---@field scale integer Pixel density multiplier. `width` and `height` should always reflect the real dimensions of the image; this is meant to easily select an @2x thumbnail for high DPI displays.
Thumbnail = {}

--- The data produced by a scraper.
---@class (exact) ScrapedSourceData
---@field kind integer What kind of thing is this (image, animation, video)?
---@field rating integer The rating of the image (see DbUtil.k.Rating)
---@field media_url string The URL of the media file.
---@field width integer The width of the media file in media_data (pixels)
---@field height integer The height of the media file in media_data (pixels)
---@field this_source string The canonical URL for the source that this media came from.
---@field additional_sources string[]? For sites like e621 that have other sources listed, all the URLs found there.
---@field authors ScrapedAuthor[] All of the authors of the post at the source. This may be the artists, but it could also be the commissioner reposting the image, so I don't call it 'artist.'
---@field canonical_domain string The canonical domain name for the source this media came from.
---@field incoming_tags string[]? If the source supports tagging, any tags that were applied there.
---@field thumbnails Thumbnail[]? If the source provides a thumbnail-size version of the media file, or if the media file is a video and the source provides a cover image, that goes here.
ScrapedSourceData = {}

--- The data produced by a scraper, with downloaded media files.
---@class (exact) FetchedSourceData : ScrapedSourceData
---@field media_data string The encoded image data for the largest version of the media file found at this source.
---@field mime_type string The MIME type of the media file in media_data.
FetchedSourceData = {}

---@class (exact) DuplicateData
---@field duplicate_of integer The ID of the record that this may be a duplicate of.
---@field similarity number? How similar this image is to the one it may be a duplicate of (percentage, float 0 to 100, may not be present if the other record is not an image but does have duplicate sources)
---@field matched_sources string[] List of source links for the record referenced by duplicate_of which are also sources for this image.
DuplicateData = {}

---@class (exact) DecodedSourceData: FetchedSourceData
---@field hash integer? The gradient hash of the image. If the media file isn't an image, this will not be present.
---@field duplicates DuplicateData[]?
DecodedSourceData = {}

---@class (exact) PipelineSubtask: DecodedSourceData
PipelineSubtask = {}
---@class (exact) PipelineSubtaskArchive: PipelineSubtask
---@field archive boolean Always True
PipelineSubtaskArchive = {}

---@class (exact) PipelineSubtaskMerge: PipelineSubtask
---@field merge integer The record ID of the record to merge this scraped data into.
PipelineSubtaskMerge = {}

---@enum PipelineTaskType
PipelineTaskType = {
    LookUp = 0,
    Scrape = 1,
    Fetch = 2,
    Decode = 3,
    Decide = 4,
    Archive = 5,
    AskHelp = 6,
}

---Sum type of all the various kinds of pipeline task.  This is what passes step-specific data from one step of the scraper pipeline to the next.
---@class (exact) PipelineTask
---@field type PipelineTaskType What kind of task is this?
---@field qid integer What queue entry is this task for?
PipelineTask = {}

---Task for the scraper step of the pipeline: look up sources for an image using FuzzySearch/Fluffle.xyz.
---@class (exact) PipelineTaskLookUp: PipelineTask
---@field image_data string The encoded image data to look up sources for.
---@field mime_type string The MIME type of the encoded image data.
PipelineTaskLookUp = {}

---Task for the scraper step of the pipeline: scrape a list of sources.
---@class (exact) PipelineTaskScrape: PipelineTask
---@field sources string[] The list of sources for this queue entry, all of which will be scraped.
PipelineTaskScrape = {}

---Task for the fetch step of the pipeline: download media files.
---@class (exact) PipelineTaskFetch: PipelineTaskScrape
---@field scraped ScrapedSourceData[][] The data scraped from each source. Outer array has one element per source, inner arrays have one element per media file at that source.
PipelineTaskFetch = {}

---Task for the decoder step of the pipeline: decode all the images in the data returned by the scraper.
---@class (exact) PipelineTaskDecode: PipelineTaskScrape
---@field fetched FetchedSourceData[][] The data scraped from each source, with fetched images.  Outer array has one element per source, inner arrays have one element per media file at that source.
PipelineTaskDecode = {}

---Task for the decide step of the pipeline: given everything known about the various sources and what's already in the database, what should be done?
---@class (exact) PipelineTaskDecide: PipelineTaskScrape
---@field decoded DecodedSourceData[][] The data scraped from each source, cleaned up and with duplicate checking metadata. Outer array has one element per source, inner arrays have one element per media file at that source.
---@field any_duplicates boolean Are there any potential duplicates already archived?
PipelineTaskDecide = {}

---Task for the execute step of the pipeline: either save a new record, or merge some scraped data into an existing record.
---@class (exact) PipelineTaskArchive: PipelineTaskScrape
---@field subtasks PipelineSubtask[]
PipelineTaskArchive = {}

---Task for the execute step of the pipeline: ask the user to decide what to do because there are multiple reasonable courses of action.
---@class (exact) PipelineTaskAskHelp: PipelineTaskScrape
---@field decoded DecodedSourceData[][]
PipelineTaskAskHelp = {}

---@enum PipelineErrorType
PipelineErrorType = {
    Temporary = 0,
    Permanent = 1,
    -- 2 and 3 are disallowed here because they correspond to other statuses.
    ---@see QueueStatus
    RetryLimitReached = 4,
    Discard = 5,
}

---@class (exact) PipelineError
---@field type PipelineErrorType What kind of error is this?
---@field description string A user-understandable message explaining what caused the error.
PipelineError = {}

function PipelineErrorPermanent(description)
    return {
        type = PipelineErrorType.Permanent,
        description = description,
    }
end

function PipelineErrorTemporary(description)
    return {
        type = PipelineErrorType.Temporary,
        description = description,
    }
end

function PipelineErrorDiscard()
    return {
        type = PipelineErrorType.Discard,
        description = "When answering a help request, you marked this to discard.",
    }
end

--- ScraperProcess function: given a URI, scrape whatever info is needed for archiving
--- from that website.
---@alias ScraperProcess fun(uri: string): ScrapedSourceData[]?, PipelineError?

--- ScraperCanProcess: given a URI, inform the pipeline whether the associated
--- scraper is able to process that URI.
---@alias ScraperCanProcess fun(uri: string): boolean

--- Convert a URI from its current form to this scraper's canonical form. If it is not a URI the current scraper can process, leave it unchanged.
---@alias ScraperNormalize fun(uri: string): string

---@alias Scraper {process_uri: ScraperProcess, can_process_uri: ScraperCanProcess, normalize_uri: ScraperNormalize}

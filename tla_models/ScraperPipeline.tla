This basically needs to be able to be handed a serialized form of its
internal state, rehydrate that, run it through the pipeline, then serialize
its state back out (into a database).

The problem domain is web scraping.  Given a URL or list of URLs, this
system needs to scrape the primary image(s) from each of the URLs (along
with metadata, such as width, height, content type, author, tags, etc.),
determine if any of the images are duplicates of one that is already
archived, then archive the images.

This is divided into several stages:

1. Scrape

This stage queries all available scraper plugins to determine the first one
which reports that it is able to scrape each URL.  The first scraper plugin
that can scrape the URL is then told to scrape the URL.  This can succeed,
providing a list of image/video/animation files with metadata, or it can fail,
providing either a permanent error or a temporary error.

For video files, this stage also downloads thumbnails (if the source
provides them)

2. Decode

This stage decodes *images only* and updates their size, computes perceptual
hashes, and creates thumbnails.

3. Decide

This stage decides what to do with the scraped data. In some situations, the
decision is self-evident:
- If there is only one record, archive it.
- If there are multiple sources, and each of them have one record, choose
  the highest-resolution record.
In all other situations, this stage should indicate to the user that their
judgement is required. (More heuristics may be added in the future.)

4. Archive

This stage takes the selected entries from the previous stage and saves them
to disk, then inserts the metadata into the database.  If the user has
chosen to merge one or entries, this stage preserves whichever entry is
higher-resolution and additively merges the other metadata.


-------------------------- MODULE ScraperPipeline --------------------------


=============================================================================
\* Modification History
\* Last modified Thu Aug 15 14:45:28 EDT 2024 by s0ph0s
\* Created Fri Aug 09 20:40:37 EDT 2024 by s0ph0s

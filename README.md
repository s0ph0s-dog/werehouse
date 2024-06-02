# Werehouse

A personal, web-based art archiving tool built on [Redbean](https://redbean.dev).

# Goals

1. Archive artwork on your own computer with proper attribution and tagging, so that you can find it again and know who created it.
2. Make it easy to share artwork with proper attribution, so that other people can find the artist and support them!
3. Be small and easy to self-host.
4. Be user-friendly.
5. Support as many modern platforms as reasonably possible.
6. Give users of the system control over their data.

# Anti-goals

1. Scalability. If your usage of this tool encounters scaling problems, you're likely using it with too many other people.
2. Productizablity. This tool is built to fix a problem I had. I don't want to turn it into a product or service.

# Setup

1. Clone a copy of the [Cosmopolitan repository](https://github.com/jart/cosmopolitan). Check out the tag `3.3.6`. Build `o//tool/net/redbean`. This is because there's an important bugfix to Redbean's HTTP client that allows it to properly upload files which hasn't been released yet. If you don't want to use FuzzySearch or Telegram sharing, you can edit the Makefile to use `redbean-2.2.com` instead, and it will automatically download the latest release for you.
2. Copy the compiled `redbean` to the checkout of this repository as `./redbean-2.3.com`
3. Run `make` to zip the project files into `werehouse.com`
4. Set the following environment variables:
   - `TZ=UTC` — The code assumes that SQLite's `strftime('', 'now')` function will produce times in UTC, which is only the case when TZ variable is set to UTC.
   - `FUZZYSEARCH_API_KEY=(API key for FuzzySearch, if you have one)` — Enable looking up image URLs and raw image files with [FuzzySearch](https://fuzzysearch.net), the backend that powers [FoxBot](https://syfaro.net/blog/foxbot/).
   - `FA_AUTH_COOKIES="a=(a cookie); b=(b cookie)"` — Enable scraping from [FurAffinity](https://www.furaffinity.net).
   - `TG_BOT_TOKEN=(Telegram bot token, if you have one)` — Enable a [Telegram](https://telegram.org) bot for enqueuing images and sharing records.
5. Run `./werehouse.com -D . -p 8082`. Optionally include `-%` if you're running locally, to avoid generating a TLS certificate on startup.
6. Use the URL printed to the console on startup to register the first account.

# Contributing

Contributions are welcome, as long as they don't draw the project away from its goals. Open issues or pull requests as you like!

# License

ISC, like Redbean and Cosmopolitan.

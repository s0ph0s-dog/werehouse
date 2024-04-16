local luaunit = require("third_party.luaunit")
_ = require "functools"
local pipeline = require("scraper_pipeline")
Nu = require("network_utils")

TestFunctools = {}
    function TestFunctools:testStartswithWorks()
        local s = "hello world"
        local actual1 = s:startswith("hello")
        local actual2 = s:startswith("wombat")
        luaunit.assertEquals(actual1, true)
        luaunit.assertEquals(actual2, false)
    end

    function TestFunctools:testEndswithWorks()
        local s = "hello world"
        local actual1 = s:endswith("world")
        local actual2 = s:endswith("wombat")
        luaunit.assertEquals(actual1, true)
        luaunit.assertEquals(actual2, false)
    end

    function TestFunctools:testMapWorks()
        local seq = { 0, 1, 2, 3 }
        local adder = function (x) return x + 1 end
        local expected = { 1, 2, 3, 4 }
        local result = table.map(seq, adder)
        luaunit.assertEquals(result, expected)
    end

    function TestFunctools:testFilterWorks()
        local seq = { 1, 2, 10, 40, 90, 65536 }
        local gt50 = function (x) return x > 50 end
        local expected = { 90, 65536 }
        local result = table.filter(seq, gt50)
        luaunit.assertEquals(result, expected)
    end

    function TestFunctools:testReduceWorks()
        local seq = { "you ", "ass", "hole"}
        local cat = function (acc, next) return (acc or "") .. next end
        local expected = "you asshole"
        local result = table.reduce(seq, cat)
        luaunit.assertEquals(result, expected)
    end

    function TestFunctools:testFlattenWorks()
        local seq = { 0, 1, {2, {3, 4}}, 5, 6 }
        local expected = { 0, 1, 2, 3, 4, 5, 6 }
        local result = table.flatten(seq)
        luaunit.assertEquals(result, expected)
    end

    function TestFunctools:testFlattenDoesntMangleMapTables()
        local seq = { 0, { 1, { foo = "bar" }}, 2 }
        local expected = { 0, 1, { foo = "bar"}, 2 }
        local result = table.flatten(seq)
        luaunit.assertEquals(result, expected)
    end

    function TestFunctools:testFiltermapWorks()
        local seq = { 0, 1, 4, 0, 6, 10, 0 }
        local expected = { 2, 5, 7, 11 }
        local result = table.filtermap(
            seq,
            function (item) return item ~= 0 end,
            function (item) return item + 1 end
        )
        luaunit.assertEquals(result, expected)
    end

local function fetch_mock(data)
    local orig = Fetch
    Fetch = function(url, opts)
        for _, item in ipairs(data) do
            if type(item.whenCalledWith) == "string" then
                if item.whenCalledWith == url then
                    return table.unpack(item.thenReturn)
                end
            end
        end
        Log(kLogWarn, "No mock match for URL(%s), Options(%s)" % {url, EncodeJson(opts)})
    end
    return orig
end


TestScraperPipeline = {}

    function TestScraperPipeline:testUnansweredDisambiguationRequestIsSkipped()
        local input = { disambiguation_request = "garbage" }
        local result = pipeline.process_entry(input)
        luaunit.assertEquals(result, {noop = true})
    end

    function TestScraperPipeline:testExampleLinkPermanentFailureShouldError()
        local input = { link = "test://shouldFailPermanently" }
        TestScraperProcessUri = function()
            return nil, PermScraperError("404")
        end
        local original = fetch_mock{
            {whenCalledWith = "test://shouldFailPermanently", thenReturn={200, {}, ""}},
        }
        local result, error = pipeline.process_entry(input)
        Fetch = original
        luaunit.assertIsNil(result)
        luaunit.assertNotIsNil(error)
        ---@cast error ScraperError
        luaunit.assertEquals(error.type, 1)
    end

    function TestScraperPipeline:testValidBskyLink()
        local input = { link = "https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz/post/3kphxqgx6iv2b" }
        local original = fetch_mock{
            {
                whenCalledWith="https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz/post/3kphxqgx6iv2b",
                thenReturn={200, {}, ""}
            },
            {
                whenCalledWith="https://bsky.social/xrpc/com.atproto.repo.getRecord?repo=did%3Aplc%3A4gjc5765wbtvrkdxysyvaewz&collection=app.bsky.feed.post&rkey=3kphxqgx6iv2b",
                thenReturn={200, {}, [[{"uri":"at://did:plc:4gjc5765wbtvrkdxysyvaewz/app.bsky.feed.post/3kphxqgx6iv2b","cid":"bafyreiaawqoyfcyqd34vybfq3lvwb7luew3rijslyjmfquoy3m2lnvzaqu","value":{"text":"People often ask Pastel how he knows that Constellation actually exists. Though they often don't accept \"I personally know her\" as an answer.","$type":"app.bsky.feed.post","embed":{"$type":"app.bsky.embed.images","images":[{"alt":"Constellation, the god of the universe pastel lives in, and Pastel having sex outside at some ruins.","image":{"$type":"blob","ref":{"$link":"bafkreib2v6upf5gz7q22jpdnrh2fwhtn6yexrsnbp6uh7ythgq3obhf7ia"},"mimeType":"image/jpeg","size":523864},"aspectRatio":{"width":1905,"height":2000}},{"alt":"Same as before but pastel is cumming.","image":{"$type":"blob","ref":{"$link":"bafkreidjkqudkq2m6pojavuelcud2fez2eojxiflnxedimplumiygu76pe"},"mimeType":"image/jpeg","size":523698},"aspectRatio":{"width":1905,"height":2000}}]},"langs":["en"],"labels":{"$type":"com.atproto.label.defs#selfLabels","values":[{"val":"porn"}]},"createdAt":"2024-04-06T15:42:51.710Z"}}]]}
            }
        }
        local result = pipeline.process_entry(input)
        Fetch = original
        local expected = { archive = {
                {
                    height=2000,
                    mime_type="image/jpeg",
                    raw_image_uri="https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:4gjc5765wbtvrkdxysyvaewz/bafkreib2v6upf5gz7q22jpdnrh2fwhtn6yexrsnbp6uh7ythgq3obhf7ia@jpeg",
                    width=1905
                },
                {
                    height=2000,
                    mime_type="image/jpeg",
                    raw_image_uri="https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:4gjc5765wbtvrkdxysyvaewz/bafkreidjkqudkq2m6pojavuelcud2fez2eojxiflnxedimplumiygu76pe@jpeg",
                    width=1905
                }
        }}
        luaunit.assertEquals(result, expected)
    end

luaunit.run()

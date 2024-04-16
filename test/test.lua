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
        local result, error = pipeline.process_entry(input)
        luaunit.assertIsNil(result)
        -- TODO: also check error
    end

    function TestScraperPipeline:testValidBskyLink()
        local input = { link = "https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz/post/3kphxqgx6iv2b" }
        local result = pipeline.process_entry(input)
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

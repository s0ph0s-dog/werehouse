local luaunit = require("third_party.luaunit")
_ = require "functools"
local pipeline = require("scraper_pipeline")
Nu = require("network_utils")
HtmlParser = require("third_party.htmlparser")

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

    function TestFunctools:testCollectWorks()
        local seq_good = { Ok(1), Ok(2), Ok(3), Ok(4) }
        local seq_bad = { Ok(1), Ok(2), Err("fart"), Ok(4) }
        local expected_good = Ok({1, 2, 3, 4})
        local expected_bad = Err("fart")
        local result_good = table.collect(seq_good)
        local result_bad = table.collect(seq_bad)
        luaunit.assertEquals(result_good, expected_good)
        luaunit.assertEquals(result_bad, expected_bad)
    end

    function TestFunctools:testCollectLenientWorks()
        local tests = {
            {
                input = { Ok(1), Ok(2), Ok(3), Ok(4) },
                expected = Ok({1, 2, 3, 4}),
            },
            {
                input = { Ok(1), Ok(2), Err("fart"), Ok(4) },
                expected = Ok({1, 2, 4}),
            },
            {
                input = { Err("fart1"), Err("fart2") },
                expected = Err("fart1"),
            },
        }
        for _, test in ipairs(tests) do
            local result = table.collect_lenient(test.input)
            luaunit.assertEquals(result, test.expected)
        end
    end

---@alias MockData {whenCalledWith: string, thenReturn: any[]}

---@param data MockData[]
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

---@param url string
---@return MockData
local function fetch_mock_head_html_200(url)
    return {
        whenCalledWith = url,
        thenReturn = {
            200,
            { ["Content-Type"] = "text/html" },
            "",
        }
    }
end

---@alias ProcessEntryTest { input: ActiveQueueEntry, expected: { 1: EntryTask, 2: ScraperError } }

---@param test_data ProcessEntryTest[]
---@param mocks MockData[]
local function process_entry_framework(test_data, mocks)
    local original = fetch_mock(mocks)
    local results = {}
    for _, test in ipairs(test_data) do
        local result, errmsg = pipeline.process_entry(test.input)
        table.insert(results, {
            input = test.input,
            expected = test.expected,
            output = { result, errmsg }
        })
    end
    -- Must do this before asserting so that I don't leave global state messed up
    Fetch = original
    for _, result in ipairs(results) do
        luaunit.assertEquals(
            result.output[2],
            result.expected[2],
            "error mismatch for input: %s" % {result.input}
        )
        luaunit.assertEquals(
            result.output[1],
            result.expected[1],
            "output mismatch for input: %s" % {result.input}
        )
    end
end

TestScraperPipeline = {}

    function TestScraperPipeline:testMultipartBody()
        local expected = "--__X_PAW_BOUNDARY__\r\nContent-Disposition: form-data; name=\"image\"; filename=\"purple.txt\"\r\nContent-Type: text/plain\r\n\r\n|test|\r\n--__X_PAW_BOUNDARY__--\r\n\r\n"
        local result = pipeline.multipart_body("__X_PAW_BOUNDARY__", "|test|", "text/plain")
        luaunit.assertEquals(result, expected)
    end

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
        local mocks = {
            fetch_mock_head_html_200("https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz/post/3kphxqgx6iv2b"),
            {
                whenCalledWith="https://bsky.social/xrpc/com.atproto.repo.getRecord?repo=did%3Aplc%3A4gjc5765wbtvrkdxysyvaewz&collection=app.bsky.feed.post&rkey=3kphxqgx6iv2b",
                thenReturn={200, {}, Slurp("./test/bsky_example.json")}
            },
            {
                whenCalledWith="https://bsky.social/xrpc/com.atproto.repo.describeRepo?repo=did%3Aplc%3A4gjc5765wbtvrkdxysyvaewz",
                thenReturn={200, {}, [[{"handle":"bigcozyorca.art","did":"did:plc:4gjc5765wbtvrkdxysyvaewz","didDoc":{"@context":["https://www.w3.org/ns/did/v1","https://w3id.org/security/multikey/v1","https://w3id.org/security/suites/secp256k1-2019/v1"],"id":"did:plc:4gjc5765wbtvrkdxysyvaewz","alsoKnownAs":["at://bigcozyorca.art"],"verificationMethod":[{"id":"did:plc:4gjc5765wbtvrkdxysyvaewz#atproto","type":"Multikey","controller":"did:plc:4gjc5765wbtvrkdxysyvaewz","publicKeyMultibase":"zQ3shk8eMicPrTviAy8AFU1YDTg4Y1Vcx6KL8kScPuqn9YPhX"}],"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://puffball.us-east.host.bsky.network"}]},"collections":["app.bsky.actor.profile","app.bsky.feed.like","app.bsky.feed.post","app.bsky.feed.repost","app.bsky.graph.block","app.bsky.graph.follow"],"handleIsCorrect":true}]]}
            },
            {
                whenCalledWith="https://bsky.social/xrpc/com.atproto.repo.listRecords?repo=did%3Aplc%3A4gjc5765wbtvrkdxysyvaewz&collection=app.bsky.actor.profile&limit=1",
                thenReturn={200, {}, [[{"records":[{"uri":"at://did:plc:4gjc5765wbtvrkdxysyvaewz/app.bsky.actor.profile/self","cid":"bafyreidyznavjmovmun7bgixgxjz3zu24j7jjaj23fr5allx4pbusbn6ei","value":{"$type":"app.bsky.actor.profile","avatar":{"$type":"blob","ref":{"$link":"bafkreiabtb4hbusnizey2sqzdtdy5fza72e5d5alovjpn6hvkolvozegwa"},"mimeType":"image/jpeg","size":905826},"banner":{"$type":"blob","ref":{"$link":"bafkreibiet6367gxfkhj3ua5vdgdbbvubucpkxbyekssgngi3zcww7ukia"},"mimeType":"image/jpeg","size":362391},"description":"He/They\n18+ (NO MINORS)\nA 🔞NSFW furry artist!!\nTrying out new platforms to spread out.","displayName":"BigCozyOrca 🔞"}}],"cursor":"self"}]]},
            },
        }
        local expected = {
            archive = table.map(
                {"https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:4gjc5765wbtvrkdxysyvaewz/bafkreib2v6upf5gz7q22jpdnrh2fwhtn6yexrsnbp6uh7ythgq3obhf7ia@jpeg", "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:4gjc5765wbtvrkdxysyvaewz/bafkreidjkqudkq2m6pojavuelcud2fez2eojxiflnxedimplumiygu76pe@jpeg"},
                function (item) return {
                    authors = {{
                        display_name="BigCozyOrca 🔞",
                        handle="bigcozyorca.art",
                        profile_url="https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz"
                    }, },
                    canonical_domain="bsky.app",
                    height=2000,
                    mime_type="image/jpeg",
                    this_source="https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz/post/3kphxqgx6iv2b",
                    raw_image_uri=item,
                    width=1905
                } end
            ),
        }
        local tests = {
            { input = input, expected = { expected, nil } },
        }
        process_entry_framework(tests, mocks)
    end

    function TestScraperPipeline:testValidTwitterLinks()
        local tweetTrackingParams = "https://twitter.com/thatFunkybun/status/1778885919572979806?s=19"
        local tweetVxtwitter = "https://vxtwitter.com/thatFunkybun/status/1778885919572979806"
        local tweetNitter = "https://nitter.privacydev.net/thatFunkybun/status/1778885919572979806#m"
        local mocks = {
            fetch_mock_head_html_200(tweetTrackingParams),
            fetch_mock_head_html_200(tweetVxtwitter),
            fetch_mock_head_html_200(tweetNitter),
            {
                whenCalledWith = "https://api.fxtwitter.com/status/1778885919572979806",
                thenReturn = {200, {}, Slurp("test/twitter_fxtwitter_response.json")}}
        }
        local author = {
            handle = "thatFunkybun",
            display_name = "Funkybun",
            profile_url = "https://twitter.com/thatFunkybun",
        }
        local expected = { archive =
            table.map(
                {
                    "https://pbs.twimg.com/media/GK_fDarXQAE6yBj.jpg",
                    "https://pbs.twimg.com/media/GK_fDaaXsAATM_X.jpg",
                    "https://pbs.twimg.com/media/GK_fDaUWYAABb40.jpg",
                    "https://pbs.twimg.com/media/GK_fDaUXsAAGJng.jpg"
                },
                function (item) return {
                    this_source = "https://twitter.com/thatFunkybun/status/1778885919572979806",
                    canonical_domain="twitter.com",
                    height=2300,
                    mime_type="image/jpeg",
                    raw_image_uri=item,
                    width=1600,
                    authors = {author, },
                } end
            )
        }
        local tests = {
            {
                input = { link = tweetTrackingParams },
                expected = { expected, nil }
            },
            {
                input = { link = tweetVxtwitter },
                expected = { expected, nil }
            },
            {
                input = { link = tweetNitter },
                expected = { expected, nil }
            },
        }
        process_entry_framework(tests, mocks)
    end

    function TestScraperPipeline:testValidFuraffinityLinks()
        local inputRegular = "https://www.furaffinity.net/view/36328438"
        local regularWithFull = "https://www.furaffinity.net/full/36328438"
        local inputFx = "https://www.fxfuraffinity.net/view/36328438"
        local inputX = "https://www.xfuraffinity.net/view/36328438"
        local inputNoWwwFull = "https://furaffinity.net/full/36328438"
        local mocks = {
            fetch_mock_head_html_200(inputRegular),
            fetch_mock_head_html_200(inputFx),
            fetch_mock_head_html_200(inputX),
            fetch_mock_head_html_200(inputNoWwwFull),
            {
                whenCalledWith = regularWithFull,
                thenReturn = {200, {}, Slurp("test/fa_example.html")},
            },
        }
        local expected = { archive = { {
            authors = {
                {
                    handle = "Glopossum",
                    display_name = "Glopossum",
                    profile_url = "https://www.furaffinity.net/user/glopossum/"
                },
            },
            canonical_domain="www.furaffinity.net",
            height=1280,
            mime_type="image/png",
            raw_image_uri="https://d.furaffinity.net/art/glopossum/1589320262/1589320262.glopossum_chloelatex.png",
            this_source = regularWithFull,
            width=960,
        } } }
        local tests = {
            {
                input = { link = inputRegular },
                expected = { expected, nil }
            },
            {
                input = { link = inputFx },
                expected = { expected, nil }
            },
            {
                input = { link = inputX },
                expected = { expected, nil }
            },
            {
                input = { link = inputNoWwwFull },
                expected = { expected, nil }
            },
        }
        process_entry_framework(tests, mocks)
    end

    function TestScraperPipeline:testValidE6Links()
        local inputRegular = "https://e621.net/posts/4366241"
        local inputQueryParams = "https://e621.net/posts/4366241?q=filetype%3Ajpg+order%3Ascore"
        local inputQueryParamsWithJson = "https://e621.net/posts/4366241.json?q=filetype%3Ajpg%2Border%3Ascore"
        local expectedRegular = {
            archive = { {
                canonical_domain="e621.net",
                height = 1100,
                mime_type = "image/jpeg",
                raw_image_uri = "https://static1.e621.net/data/63/f2/63f28a75d91d42252326235a03efe93e.jpg",
                this_source = inputRegular,
                additional_sources = {
                    "https://twitter.com/BeaganBong/status/1715891189566881976",
                    "https://pbs.twimg.com/media/F9AR0lUagAAq1wc?format=jpg&name=orig",
                },
                width = 880,
                authors = {
                    {
                        display_name="reagan_long",
                        handle="reagan_long",
                        profile_url="https://e621.net/posts?tags=reagan_long"
                    }
                },
            }, },
        }
        local inputVideo = "https://e621.net/posts/2848682"
        local inputGif = "https://e621.net/posts/3105830"
        local tests = {
            {
                input = { link = inputRegular },
                expected = { expectedRegular, nil },
            },
            {
                input = { link = inputQueryParams },
                expected = { expectedRegular, nil },
            },
            {
                input = { link = inputVideo },
                expected = { nil, PermScraperError("This post is a webm, which isn't supported yet") },
            },
            {
                input = { link = inputGif },
                expected = { { archive = { {
                    canonical_domain="e621.net",
                    height = 1920,
                    mime_type = "image/gif",
                    this_source = inputGif,
                    additional_sources = {
                        "https://twitter.com/its_a_mok/status/1478372140542042114",
                    },
                    raw_image_uri = "https://static1.e621.net/data/f6/d9/f6d9af24b4a47fd324bd41ebe21aeb42.gif",
                    width = 1080,
                    authors = {
                        {
                            handle = "its_a_mok",
                            display_name = "its_a_mok",
                            profile_url = "https://e621.net/posts?tags=its_a_mok"
                        },
                    }
                }, } }, nil}
            }
        }
        local regular_response_body = Slurp("test/e6_regular_example.json")
        local mocks = {
            fetch_mock_head_html_200(inputRegular),
            fetch_mock_head_html_200(inputQueryParams),
            fetch_mock_head_html_200(inputVideo),
            fetch_mock_head_html_200(inputGif),
            {
                whenCalledWith = inputRegular .. ".json",
                thenReturn = {200, {}, regular_response_body},
            },
            {
                whenCalledWith = inputQueryParamsWithJson,
                thenReturn = {200, {}, regular_response_body},
            },
            {
                whenCalledWith = inputVideo .. ".json",
                thenReturn = {200, {}, Slurp("test/e6_video_example.json")},
            },
            {
                whenCalledWith = inputGif .. ".json",
                thenReturn = {200, {}, Slurp("test/e6_gif_example.json")},
            },
        }
        process_entry_framework(tests, mocks)
    end

luaunit.run()

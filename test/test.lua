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
            fetch_mock_head_html_200("https://bsky.app/profile/did:plc:4gjc5765wbtvrkdxysyvaewz/post/3kphxqgx6iv2b"),
            {
                whenCalledWith="https://bsky.social/xrpc/com.atproto.repo.getRecord?repo=did%3Aplc%3A4gjc5765wbtvrkdxysyvaewz&collection=app.bsky.feed.post&rkey=3kphxqgx6iv2b",
                thenReturn={200, {}, [[{"uri":"at://did:plc:4gjc5765wbtvrkdxysyvaewz/app.bsky.feed.post/3kphxqgx6iv2b","cid":"bafyreiaawqoyfcyqd34vybfq3lvwb7luew3rijslyjmfquoy3m2lnvzaqu","value":{"text":"People often ask Pastel how he knows that Constellation actually exists. Though they often don't accept \"I personally know her\" as an answer.","$type":"app.bsky.feed.post","embed":{"$type":"app.bsky.embed.images","images":[{"alt":"Constellation, the god of the universe pastel lives in, and Pastel having sex outside at some ruins.","image":{"$type":"blob","ref":{"$link":"bafkreib2v6upf5gz7q22jpdnrh2fwhtn6yexrsnbp6uh7ythgq3obhf7ia"},"mimeType":"image/jpeg","size":523864},"aspectRatio":{"width":1905,"height":2000}},{"alt":"Same as before but pastel is cumming.","image":{"$type":"blob","ref":{"$link":"bafkreidjkqudkq2m6pojavuelcud2fez2eojxiflnxedimplumiygu76pe"},"mimeType":"image/jpeg","size":523698},"aspectRatio":{"width":1905,"height":2000}}]},"langs":["en"],"labels":{"$type":"com.atproto.label.defs#selfLabels","values":[{"val":"porn"}]},"createdAt":"2024-04-06T15:42:51.710Z"}}]]}
            }
        }
        local result, errmsg = pipeline.process_entry(input)
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
        luaunit.assertIsNil(errmsg)
    end

    function TestScraperPipeline:testValidTwitterLinks()
        local tweetTrackingParams = "https://twitter.com/thatFunkybun/status/1778885919572979806?s=19"
        local tweetVxtwitter = "https://vxtwitter.com/thatFunkybun/status/1778885919572979806"
        local tweetNitter = "https://nitter.privacydev.net/thatFunkybun/status/1778885919572979806#m"
        local inputs = table.map(
            {tweetTrackingParams, tweetVxtwitter, tweetNitter},
            function (i) return { link = i } end
        )
        local original = fetch_mock{
            fetch_mock_head_html_200(tweetTrackingParams),
            fetch_mock_head_html_200(tweetVxtwitter),
            fetch_mock_head_html_200(tweetNitter),
            {
                whenCalledWith = "https://api.fxtwitter.com/status/1778885919572979806",
                thenReturn = {200, {}, [[{"code":200,"message":"OK","tweet":{"url":"https://twitter.com/thatFunkybun/status/1778885919572979806","id":"1778885919572979806","text":"each second month I spend some time making an exclusive project for the €5 patrons, and this is that project from november! now released for the public.\nsorry I took so long on this month's exclusive X) it's only 14 pages but still took me 3 weeks","author":{"id":"986175872515362816","name":"Funkybun","screen_name":"thatFunkybun","avatar_url":"https://pbs.twimg.com/profile_images/1466055016880422925/TrD9-bqQ_200x200.jpg","banner_url":"https://pbs.twimg.com/profile_banners/986175872515362816/1638369730","description":"I am Funkybun (she/her), making NSFW exhibitionism art for all of you! \nyou can find my art over at:\nhttp://patreon.com/funkybun","location":"","url":"https://twitter.com/thatFunkybun","followers":77430,"following":31,"joined":"Tue Apr 17 09:33:45 +0000 2018","likes":2606,"website":{"url":"https://www.patreon.com/funkybun","display_url":"patreon.com/funkybun"},"tweets":828,"avatar_color":null},"replies":34,"retweets":690,"likes":4048,"created_at":"Fri Apr 12 20:40:27 +0000 2024","created_timestamp":1712954427,"possibly_sensitive":true,"views":80815,"is_note_tweet":false,"lang":"en","replying_to":null,"replying_to_status":null,"media":{"all":[{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDarXQAE6yBj.jpg","width":1600,"height":2300,"altText":""},{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDaaXsAATM_X.jpg","width":1600,"height":2300,"altText":""},{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDaUWYAABb40.jpg","width":1600,"height":2300,"altText":""},{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDaUXsAAGJng.jpg","width":1600,"height":2300,"altText":""}],"photos":[{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDarXQAE6yBj.jpg","width":1600,"height":2300,"altText":""},{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDaaXsAATM_X.jpg","width":1600,"height":2300,"altText":""},{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDaUWYAABb40.jpg","width":1600,"height":2300,"altText":""},{"type":"photo","url":"https://pbs.twimg.com/media/GK_fDaUXsAAGJng.jpg","width":1600,"height":2300,"altText":""}],"mosaic":{"type":"mosaic_photo","formats":{"jpeg":"https://mosaic.fxtwitter.com/jpeg/1778885919572979806/GK_fDarXQAE6yBj/GK_fDaaXsAATM_X/GK_fDaUWYAABb40/GK_fDaUXsAAGJng","webp":"https://mosaic.fxtwitter.com/webp/1778885919572979806/GK_fDarXQAE6yBj/GK_fDaaXsAATM_X/GK_fDaUWYAABb40/GK_fDaUXsAAGJng"}}},"source":"Twitter Web App","twitter_card":"summary_large_image","color":null}}]]}}
        }
        local expected = {
            archive = {
                {
                    height=2300,
                    mime_type="image/jpeg",
                    raw_image_uri="https://pbs.twimg.com/media/GK_fDarXQAE6yBj.jpg",
                    width=1600
                },
                {
                    height=2300,
                    mime_type="image/jpeg",
                    raw_image_uri="https://pbs.twimg.com/media/GK_fDaaXsAATM_X.jpg",
                    width=1600
                },
                {
                    height=2300,
                    mime_type="image/jpeg",
                    raw_image_uri="https://pbs.twimg.com/media/GK_fDaUWYAABb40.jpg",
                    width=1600
                },
                {
                    height=2300,
                    mime_type="image/jpeg",
                    raw_image_uri="https://pbs.twimg.com/media/GK_fDaUXsAAGJng.jpg",
                    width=1600
                },
            }
        }
        local results = {}
        for _, input in ipairs(inputs) do
            local result, errmsg = pipeline.process_entry(input)
            table.insert(results, {input, result, errmsg})
        end
        -- Must do this before asserting so that I don't leave global state messed up
        Fetch = original
        for _, result in ipairs(results) do
            luaunit.assertIsNil(result[3], "input: %s" % {result[1]})
            luaunit.assertEquals(result[2], expected, "input: %s" % {result[1]})
        end
    end

    function TestScraperPipeline:testValidFuraffinityLinks()
        local inputRegular = "https://www.furaffinity.net/view/36328438"
        local inputFx = "https://www.fxfuraffinity.net/view/36328438"
        local inputX = "https://www.xfuraffinity.net/view/36328438"
        local inputNoWwwFull = "https://furaffinity.net/full/36328438"
        local inputs = table.map(
            {inputRegular, inputFx, inputX, inputNoWwwFull},
            function (i) return { link = i } end
        )
        local original = fetch_mock{
            fetch_mock_head_html_200(inputRegular),
            fetch_mock_head_html_200(inputFx),
            fetch_mock_head_html_200(inputX),
            fetch_mock_head_html_200(inputNoWwwFull),
            {
                whenCalledWith = "https://www.furaffinity.net/full/36328438",
                thenReturn = {200, {}, Slurp("./test/fa_example.html")},
            },
        }
        local expected = {
            archive = {
                {
                    height=1280,
                    mime_type="image/png",
                    raw_image_uri="https://d.furaffinity.net/art/glopossum/1589320262/1589320262.glopossum_chloelatex.png",
                    width=960,
                }
            }
        }
        local results = {}
        for _, input in ipairs(inputs) do
            local result, errmsg = pipeline.process_entry(input)
            table.insert(results, {input, result, errmsg})
        end
        -- Must do this before asserting so that I don't leave global state messed up
        Fetch = original
        for _, result in ipairs(results) do
            luaunit.assertIsNil(result[3], "input: %s" % {result[1]})
            luaunit.assertEquals(result[2], expected, "input: %s" % {result[1]})
        end
    end

luaunit.run()

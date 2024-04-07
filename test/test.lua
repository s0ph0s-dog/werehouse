local luaunit = require("third_party.luaunit")
_ = require "functools"

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

luaunit.run()

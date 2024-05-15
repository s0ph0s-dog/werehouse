local ALPHABET_BASE64 = {
    "-",
    "_",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h",
    "i",
    "j",
    "k",
    "l",
    "m",
    "n",
    "o",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "w",
    "x",
    "y",
    "z",
    "A",
    "B",
    "C",
    "D",
    "E",
    "F",
    "G",
    "H",
    "I",
    "J",
    "K",
    "L",
    "M",
    "N",
    "O",
    "P",
    "Q",
    "R",
    "S",
    "T",
    "U",
    "V",
    "W",
    "X",
    "Y",
    "Z",
}
local ALPHABET_BASE58 = {
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h",
    "i",
    "j",
    "k",
    "m",
    "n",
    "o",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "w",
    "x",
    "y",
    "z",
    "A",
    "B",
    "C",
    "D",
    "E",
    "F",
    "G",
    "H",
    "J",
    "K",
    "L",
    "M",
    "N",
    "P",
    "Q",
    "R",
    "S",
    "T",
    "U",
    "V",
    "W",
    "X",
    "Y",
    "Z",
}

local RAND_MAX = 1 << 32

local function int64_to_uint32(int64)
    local int32 = int64 & 0xFFFFFFFF
    if int32 < 0 then
        return ~int32 + 1
    end
    return int32
end

local function custom(alphabet, length)
    local result = {}
    for i = 1, (length + 1) do
        local random_num
        repeat
            random_num = int64_to_uint32(Rand64())
        until random_num < (RAND_MAX - RAND_MAX % #alphabet)

        -- Add 1 because Lua arrays are 1-indexed.
        random_num = (random_num % #alphabet) + 1
        result[i] = alphabet[random_num]
    end

    return table.concat(result, "")
end

local function generate(length)
    return custom(ALPHABET_BASE58, length)
end

local function simple()
    return generate(21)
end

local function simple_with_prefix(prefix)
    if not prefix then
        error("prefix was nil! Check the prefix name.")
    end
    return prefix .. simple()
end

return {
    custom = custom,
    generate = generate,
    simple = simple,
    simple_with_prefix = simple_with_prefix,
    alphabet = {
        BASE64 = ALPHABET_BASE64,
        BASE58 = ALPHABET_BASE58,
    },
}

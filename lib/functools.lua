---@param s (string) A string
---@param prefix (string) Another string
---@return (boolean) # True if prefix is a substring of s at index 1, false otherwise.
function string.startswith(s, prefix)
    if not s then
        return false
    end
    if not prefix then
        return true
    end
    if #s < #prefix then
        return false
    end
    local maybe_prefix = s:sub(1, #prefix)
    -- print(maybe_prefix)
    return prefix == maybe_prefix
end

---@param s (string)
---@param suffix (string)
---@return (boolean) # True if suffix is a substring of s at index (len(s) - len(suffix)), false otherwise.
function string.endswith(s, suffix)
    if not s then
        return false
    end
    if not suffix then
        return true
    end
    if #s < #suffix then
        return false
    end
    local maybe_suffix = s:sub(#s - #suffix + 1)
    return suffix == maybe_suffix
end

function string.strip(s)
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

--- Given a UTF16 code unit count, return the corresponding index into the string.
---@param s string
---@param utf16i integer
---@return integer
function string.utf16index(s, utf16i)
    local code_units_so_far = 0
    for i = 1, #s do
        local char = string.byte(s, i)
        if (char & 192) ~= 128 then
            if (char & 240) == 240 then
                code_units_so_far = code_units_so_far + 2
            else
                code_units_so_far = code_units_so_far + 1
            end
        end
        if code_units_so_far >= utf16i then
            return i
        end
    end
    return nil
end

function string.utf16sub(s, i, j)
    local real_i = s:utf16index(i)
    local real_j = s:utf16index(j)
    return s:sub(real_i, real_j)
end

---@generic T : any, U : any
---@param sequence (T[])
---@param transformation (fun(item: T): U)
---@return (U[])
function table.map(sequence, transformation)
    if not sequence then
        return {}
    end
    local result = {}
    for i = 1, #sequence do
        result[i] = transformation(sequence[i])
    end
    return result
end

---@generic T : any
---@param sequence (T[])
---@param predicate (fun(item: T): boolean)
---@return (T[])
function table.filter(sequence, predicate)
    if not sequence then
        return {}
    end
    local result = {}
    for i = 1, #sequence do
        if predicate(sequence[i]) then
            result[#result + 1] = sequence[i]
        end
    end
    return result
end

---@generic T : any, U : any
---@param sequence (T[])
---@param operator (fun(accumulator: U?, next: T): U?)
---@return (U?)
function table.reduce(sequence, operator)
    if not sequence then
        return {}
    end
    if #sequence == 0 then
        return nil
    end
    local result = nil
    for i = 1, #sequence do
        result = operator(result, sequence[i])
    end
    return result
end

---@generic T : any, U : any
---@param sequence (T[])
---@param predicate (fun(item: T): boolean)
---@param transformation (fun(item: T): U)
---@return (U[])
function table.filtermap(sequence, predicate, transformation)
    if not sequence then
        return {}
    end
    local result = {}
    for i = 1, #sequence do
        local item = sequence[i]
        if predicate(item) then
            result[#result + 1] = transformation(item)
        end
    end
    return result
end

--- Given a list-table that contains arbitrarily nested other list-tables, flatten all of the nested lists into one list.
---@param sequence (any[])
---@param result (any[]?)
---@return any[]
function table.flatten(sequence, result)
    if not sequence then
        return {}
    end
    result = result or {}
    for i = 1, #sequence do
        local item = sequence[i]
        if type(item) == "table" and #item > 0 then
            myResult = table.flatten(item, result)
        elseif type(item) == "table" and not next(item) then
        else
            result[#result + 1] = item
        end
    end
    return result
end

function table.find(sequence, needle)
    if not sequence then
        return nil
    end
    for i = 1, #sequence do
        if sequence[i] == needle then
            return i
        end
    end
    return nil
end

---@generic T
---@generic E
---@class ResultInternal<T, E>
---@field result `T`?
---@field err `E`?
Result = {}
---@return boolean
function Result:is_ok()
    return not not self.result
end
---@return boolean
function Result:is_err()
    return not self.result
end
---@generic T
---@return `T`
function Result:unwrap()
    if self.result then
        return self.result
    else
        error("tried to unwrap an Err")
    end
end
---@generic T
---@param default `T`
---@return `T`
function Result:unwrap_or(default)
    if self.result then
        return self.result
    else
        return default
    end
end

function Result:map(transformation)
    if self.result then
        return Ok(transformation(self.result))
    else
        return self
    end
end

---@generic T
---@class Ok<T>: ResultInternal
---@field result `T`

---@generic T
---@param t `T`
---@return Ok<T>
function Ok(t)
    local r = { result = t }
    return setmetatable(r, { __index = Result })
end

---@generic E
---@class Err<E>: ResultInternal
---@field err `E`

---@generic E
---@param e `E`
---@return Err<E>
function Err(e)
    local r = { err = e }
    return setmetatable(r, { __index = Result })
end

---@alias Result<T, E> (Ok<T>|Err<E>)

---@generic T
---@generic E
---@param sequence Result<T, E>[]
---@return Result<T[], E>
function table.collect(sequence)
    local result = {}
    for _, item in ipairs(sequence) do
        ---@cast item ResultInternal
        if item:is_err() then
            return item
        else
            table.insert(result, item:unwrap())
        end
    end
    return Ok(result)
end

--- Like table.collect, but only returns an Err if nothing in the collection is an Ok.
---@see table.collect
---@generic T
---@generic E
---@param sequence Result<T, E>[]
---@return Result<T[], E>
function table.collect_lenient(sequence)
    local result = {}
    local first_error = nil
    for _, item in ipairs(sequence) do
        ---@cast item ResultInternal
        if item:is_err() and not first_error then
            first_error = item
        elseif item:is_ok() then
            table.insert(result, item:unwrap())
        end
    end
    if #result < 1 then
        return first_error
    else
        return Ok(result)
    end
end

--- Return only the unique elements from the provided arguments.
---@param sequence string[]
---@return string[]
function table.uniq(sequence)
    local set = {}
    for _, item in ipairs(sequence) do
        set[item] = true
    end
    local result = {}
    for item, _ in pairs(set) do
        table.insert(result, item)
    end
    return result
end

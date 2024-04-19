
---@param s (string) A string
---@param prefix (string) Another string
---@return (boolean) # True if prefix is a substring of s at index 1, false otherwise.
function string.startswith(s, prefix)
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
    if #s < #suffix then
        return false
    end
    local maybe_suffix = s:sub(#s - #suffix + 1)
    return suffix == maybe_suffix
end

---@generic T : any, U : any
---@param sequence (T[])
---@param transformation (fun(item: T): U)
---@return (U[])
function table.map(sequence, transformation)
    local result = {}
    for i, v in pairs(sequence) do
        result[i] = transformation(v)
    end
    return result
end

---@generic T : any
---@param sequence (T[])
---@param predicate (fun(item: T): boolean)
---@return (T[])
function table.filter(sequence, predicate)
    local result = {}
    for _, v in ipairs(sequence) do
        if predicate(v) then
            table.insert(result, v)
        end
    end
    return result
end

---@generic T : any, U : any
---@param sequence (T[])
---@param operator (fun(accumulator: U?, next: T): U?)
---@return (U?)
function table.reduce(sequence, operator)
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
    return table.map(
        table.filter(sequence, predicate),
        transformation
    )
end

--- Given a list-table that contains arbitrarily nested other list-tables, flatten all of the nested lists into one list.
---@param sequence (any[])
---@param result (any[]?)
---@return any[]
function table.flatten(sequence, result)
    local myResult = result or {}
    for _, item in ipairs(sequence) do
        if type(item) == "table" and #item > 0 then
            myResult = table.flatten(item, myResult)
        else
            table.insert(myResult, item)
        end
    end
    return myResult
end

---@generic T
---@generic E
---@class ResultInternal<T, E>
---@field result `T`?
---@field err `E`?
Result = {}
---@return boolean
function Result:is_ok()
    return not (not self.result)
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

---@generic T
---@class Ok<T>: ResultInternal
---@field result `T`

---@generic T
---@param t `T`
---@return Ok<T>
function Ok(t)
    local r = { result = t }
    return setmetatable(r, {__index = Result})
end

---@generic E
---@class Err<E>: ResultInternal
---@field err `E`

---@generic E
---@param e `E`
---@return Err<E>
function Err(e)
    local r = { err = e }
    return setmetatable(r, {__index = Result})
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

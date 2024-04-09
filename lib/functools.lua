
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

local Result = {}
function Result:is_ok()
    return not (not self.result)
end
function Result:is_err()
    return not self.result
end
function Result:unwrap()
    if self.is_ok then
        return self.result
    else
        error("tried to unwrap an Err")
    end
end

---@class Ok<T> { result: T }

---@generic T
---@param t `T`
---@return Ok<T>
function Ok(t)
    local r = { result = t }
    return setmetatable(r, Result)
end

---@class Err<E> { err: E }

---@generic E
---@param e `E`
---@return Err<E>
function Err(e)
    local r = { err = e }
    return setmetatable(r, Result)
end

---@alias Result<T, E> (Ok<T>|Err<E>)

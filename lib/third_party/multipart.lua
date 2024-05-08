-- From https://github.com/catwell/lua-multipart-post/commit/cce2161b61caf3b4724021ff832fded016b87d22
local unpack = table.unpack or unpack

local _M = {}

_M.CHARSET = "UTF-8"
_M.LANGUAGE = ""

local function fmt(p, ...)
    if select('#', ...) == 0 then
        return p
    end
    return string.format(p, ...)
end

local function tprintf(t, p, ...)
    t[#t+1] = fmt(p, ...)
end

local function section_header(r, k, extra)
    tprintf(r, "content-disposition: form-data; name=\"%s\"", k)
    if extra.filename then
        tprintf(r, "; filename=\"%s\"", extra.filename)
        tprintf(
            r, "; filename*=%s'%s'%s",
            _M.CHARSET, _M.LANGUAGE, EscapePath(extra.filename)
        )
    end
    if extra.content_type then
        tprintf(r, "\r\ncontent-type: %s", extra.content_type)
    end
    if extra.content_transfer_encoding then
        tprintf(
            r, "\r\ncontent-transfer-encoding: %s",
            extra.content_transfer_encoding
        )
    end
    tprintf(r, "\r\n\r\n")
end

local function gen_boundary()
  local t = {"BOUNDARY-"}
  for i=2,17 do t[i] = string.char(math.random(65, 90)) end
  t[18] = "-BOUNDARY"
  return table.concat(t)
end

local function encode_header_to_table(r, k, v, boundary)
    local _t = type(v)

    tprintf(r, "--%s\r\n", boundary)
    if _t == "string" then
        section_header(r, k, {})
    elseif _t == "table" then
        assert(v.data, "invalid input")
        local extra = {
            filename = v.filename or v.name,
            content_type = v.content_type or v.mimetype
                or "application/octet-stream",
            content_transfer_encoding = v.content_transfer_encoding
                or "binary",
        }
        section_header(r, k, extra)
    else
        error(string.format("unexpected type %s", _t))
    end
end

local function encode_header_as_source(k, v, boundary, ctx)
    local r = {}
    encode_header_to_table(r, k, v, boundary, ctx)
    local s = table.concat(r)
    if ctx then
        ctx.headers_length = ctx.headers_length + #s
    end
    return s
end

local function data_len(d)
    local _t = type(d)

    if _t == "string" then
        return string.len(d)
    elseif _t == "table" then
        if type(d.data) == "string" then
            return string.len(d.data)
        end
        if d.len then return d.len end
        error("must provide data length for non-string datatypes")
    end
end

local function content_length(t, boundary, ctx)
    local r = ctx and ctx.headers_length or 0
    for k, v in pairs(t) do
        if not ctx then
            local tmp = {}
            encode_header_to_table(tmp, k, v, boundary)
            r = r + #table.concat(tmp)
        end
        r = r + data_len(v) + 2; -- `\r\n`
    end
    return r + #boundary + 6; -- `--BOUNDARY--\r\n`
end

local function get_data_src(v)
    local _t = type(v)
    if v.source then
        return v.source
    elseif _t == "string" then
        return v
    elseif _t == "table" then
        _t = type(v.data)
        if _t == "string" then
            return v.data
        elseif _t == "table" then
            return table.concat(v.data)
        elseif _t == "userdata" then
            -- return ltn12.source.file(v.data)
            return nil
        elseif _t == "function" then
            return v.data
        end
    end
    error("invalid input")
end

local function source(t, boundary, ctx)
    local sources, n = {}, 1
    for k, v in pairs(t) do
        sources[n] = encode_header_as_source(k, v, boundary, ctx)
        sources[n+1] = get_data_src(v)
        sources[n+2] = "\r\n"
        n = n + 3
    end
    sources[n] = string.format("--%s--\r\n", boundary)
    return table.concat(sources)
end
_M.source = source

function _M.gen_request(t)
    local boundary = gen_boundary()
    -- This is an optimization to avoid re-encoding headers twice.
    -- The length of the headers is stored when computing the source,
    -- and re-used when computing the content length.
    local ctx = {headers_length = 0}
    return {
        method = "POST",
        source = source(t, boundary, ctx),
        headers = {
            ["content-length"] = content_length(t, boundary, ctx),
            ["content-type"] = fmt(
                "multipart/form-data; boundary=%s", boundary
            ),
        },
    }
end

function _M.encode(t, boundary)
    boundary = boundary or gen_boundary()
    local r = source(t, boundary)
    return r, boundary
end

return _M

local api = {}
local config = {
    endpoint = "https://api.telegram.org/bot",
}
local multipart = Multipart

function api.configure(token, debug)
    if not token or type(token) ~= "string" then
        token = nil
    end
    api.debug = debug and true or false
    api.token =
        assert(token, "Must specify Telegram bot API token (from BotFather)")
    repeat
        api.info = api.get_me()
    until api.info.result
    api.info = api.info.result
    api.info.name = api.info.first_name
    return api
end

function api.request(endpoint, parameters, file)
    assert(endpoint, "Must specify endpoint")
    parameters = parameters or {}
    for k, v in pairs(parameters) do
        parameters[k] = tostring(v)
    end
    if api.debug then
        Log(kLogDebug, EncodeJson(parameters))
    end
    parameters = next(parameters) == nil and { "" } or parameters
    local body, boundary = multipart.encode(parameters)
    local status, headers, resp_body = Fetch(endpoint, {
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = string.format(
                'multipart/form-data; boundary="%s"',
                boundary
            ),
        },
    })
    if status ~= 200 then
        return nil, headers
    end
    local json, json_err = DecodeJson(resp_body)
    if not json then
        return nil, json_err
    end
    if not json.ok then
        return nil, json
    end
    return json
end

function api.get_me()
    return api.request(config.endpoint .. api.token .. "/getMe")
end

function api.log_out()
    return api.request(config.endpoint .. api.token .. "/logOut")
end

function api.close()
    return api.request(config.endpoint .. api.token .. "/close")
end

function api.get_updates(timeout, offset, limit, allowed_updates)
    allowed_updates = type(allowed_updates) == "table"
            and EncodeJson(allowed_updates)
        or allowed_updates
    return api.request(config.endpoint .. api.token .. "/getUpdates", {
        timeout = timeout,
        offset = offset,
        limit = limit,
        allowed_updates = allowed_updates,
    })
end

function api.send_message(
    message,
    text,
    message_thread_id,
    parse_mode,
    entities,
    link_preview_options,
    disable_notification,
    protect_content,
    reply_parameters,
    reply_markup
) -- https://core.telegram.org/bots/api#sendmessage
    entities = type(entities) == "table" and EncodeJson(entities) or entities
    link_preview_options = type(link_preview_options) == "table"
            and EncodeJson(link_preview_options)
        or link_preview_options
    reply_parameters = type(reply_parameters) == "table"
            and EncodeJson(reply_parameters)
        or reply_parameters
    reply_markup = type(reply_markup) == "table" and EncodeJson(reply_markup)
        or reply_markup
    message = (type(message) == "table" and message.chat and message.chat.id)
            and message.chat.id
        or message
    parse_mode = (type(parse_mode) == "boolean" and parse_mode == true)
            and "plaintext"
        or parse_mode
    if disable_web_page_preview == nil then
        disable_web_page_preview = true
    end
    local ok, err =
        api.request(config.endpoint .. api.token .. "/sendMessage", {
            ["chat_id"] = message,
            ["message_thread_id"] = message_thread_id,
            ["text"] = text,
            ["parse_mode"] = parse_mode,
            ["entities"] = entities,
            ["link_preview_options"] = link_preview_options,
            ["disable_notification"] = disable_notification,
            ["protect_content"] = protect_content,
            ["reply_parameters"] = reply_parameters,
            ["reply_markup"] = reply_markup,
        })
    return ok, err
end

function api.on_update(_) end
function api.on_message(_) end

function api.process_update(update)
    if update then
        api.on_update(update)
    end
    if update.message then
        return api.on_message(update.message)
    end
    return false
end

function api.run(limit, timeout, offset, allowed_updates)
    limit = tonumber(limit) ~= nil and limit or 10
    timeout = tonumber(timeout) ~= nil and timeout or 30
    offset = tonumber(offset) ~= nil and offset or 0
    while true do
        local updates, err =
            api.get_updates(timeout, offset, limit, allowed_updates)
        if updates and type(updates) == "table" and updates.result then
            print(updates)
            for _, v in pairs(updates.result) do
                if v then
                    api.process_update(v)
                    offset = v.update_id + 1
                end
            end
        end
    end
end

return api

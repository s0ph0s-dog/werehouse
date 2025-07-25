-- Code included selectively from https://github.com/wrxck/telegram-bot-lua/tree/cdcc49ab57763f2c68ce83f8c9514ebdb10e5fcf, and modified slightly to work with Redbean's Lua.
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
    --[[repeat
        api.info = api.get_me()
    until api.info.result
    api.info = api.info.result
    api.info.name = api.info.first_name]]
    return api
end

function api.request(endpoint, parameters, files)
    assert(endpoint, "Must specify endpoint")
    parameters = parameters or {}
    for k, v in pairs(parameters) do
        parameters[k] = tostring(v)
    end
    if api.debug then
        Log(kLogDebug, EncodeJson(parameters))
    end
    for file_key, file_name in pairs(files or {}) do
        local file_data, err
        if type(file_name) == "table" and file_name.data then
            file_data = file_name.data
            file_name = file_key
        else
            file_data, err = Slurp(file_name)
        end
        if file_data then
            parameters[file_key] = {
                filename = file_name,
                data = file_data,
            }
        else
            Log(
                kLogDebug,
                "Error reading from file %s: %s" % { file_name, err }
            )
            parameters[file_key] = file_name
        end
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
    if not status then
        return nil, headers
    end
    if status ~= 200 then
        Log(kLogDebug, "Error from telegram: %s" % { resp_body })
        return nil, resp_body
    end
    if api.debug then
        Log(kLogDebug, resp_body)
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
    if not link_preview_options then
        link_preview_options = { is_disabled = true }
    end
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

function api.reply_to_message(message, text, message_thread_id, parse_mode)
    return api.send_message(message, text, message_thread_id, parse_mode, nil, nil, nil, nil, {
        message_id = message.message_id,
    })
end

function api.send_photo(
    chat_id,
    photo,
    message_thread_id,
    caption,
    parse_mode,
    caption_entities,
    has_spoiler,
    disable_notification,
    protect_content,
    reply_parameters,
    reply_markup
) -- https://core.telegram.org/bots/api#sendphoto
    caption_entities = type(caption_entities) == "table"
            and EncodeJson(caption_entities)
        or caption_entities
    reply_parameters = type(reply_parameters) == "table"
            and EncodeJson(reply_parameters)
        or reply_parameters
    reply_markup = type(reply_markup) == "table" and EncodeJson(reply_markup)
        or reply_markup
    local success, res = api.request(
        config.endpoint .. api.token .. "/sendPhoto",
        {
            ["chat_id"] = chat_id,
            ["message_thread_id"] = message_thread_id,
            ["caption"] = caption,
            ["parse_mode"] = parse_mode,
            ["caption_entities"] = caption_entities,
            ["has_spoiler"] = has_spoiler,
            ["disable_notification"] = disable_notification,
            ["protect_content"] = protect_content,
            ["reply_parameters"] = reply_to_message_id,
            ["reply_markup"] = reply_markup,
        },
        {
            ["photo"] = photo,
        }
    )
    return success, res
end

function api.send_animation(chat_id, animation, message_thread_id, duration, width, height, thumbnail, caption,
    parse_mode, caption_entities, has_spoiler, disable_notification, protect_content, reply_parameters, reply_markup) -- https://core.telegram.org/bots/api#sendanimation
    caption_entities = type(caption_entities) == 'table' and EncodeJson(caption_entities) or caption_entities
    reply_parameters = type(reply_parameters) == 'table' and EncodeJson(reply_parameters) or reply_parameters
    reply_markup = type(reply_markup) == 'table' and EncodeJson(reply_markup) or reply_markup
    local success, res = api.request(config.endpoint .. api.token .. '/sendAnimation', {
        ['chat_id'] = chat_id,
        ['message_thread_id'] = message_thread_id,
        ['duration'] = duration,
        ['width'] = width,
        ['height'] = height,
        ['caption'] = caption,
        ['parse_mode'] = parse_mode,
        ['caption_entities'] = caption_entities,
        ['has_spoiler'] = has_spoiler,
        ['disable_notification'] = disable_notification,
        ['protect_content'] = protect_content,
        ['reply_parameters'] = reply_parameters,
        ['reply_markup'] = reply_markup
    }, {
        ['animation'] = animation,
        ['thumbnail'] = thumbnail
    })
    return success, res
end

function api.send_video(
    chat_id,
    video,
    message_thread_id,
    duration,
    width,
    height,
    caption,
    parse_mode,
    has_spoiler,
    supports_streaming,
    disable_notification,
    protect_content,
    reply_parameters,
    reply_markup
) -- https://core.telegram.org/bots/api#sendvideo
    caption_entities = type(caption_entities) == "table"
            and EncodeJson(caption_entities)
        or caption_entities
    reply_parameters = type(reply_parameters) == "table"
            and EncodeJson(reply_parameters)
        or reply_parameters
    reply_markup = type(reply_markup) == "table" and EncodeJson(reply_markup)
        or reply_markup
    local success, res = api.request(
        config.endpoint .. api.token .. "/sendVideo",
        {
            ["chat_id"] = chat_id,
            ["message_thread_id"] = message_thread_id,
            ["duration"] = duration,
            ["width"] = width,
            ["height"] = height,
            ["caption"] = caption,
            ["parse_mode"] = parse_mode,
            ["caption_entities"] = caption_entities,
            ["has_spoiler"] = has_spoiler,
            ["supports_streaming"] = supports_streaming,
            ["disable_notification"] = disable_notification,
            ["protect_content"] = protect_content,
            ["reply_parameters"] = reply_parameters,
            ["reply_markup"] = reply_markup,
        },
        {
            ["video"] = video,
        }
    )
    return success, res
end

function api.send_media_group(chat_id, media, media_map, message_thread_id, disable_notification, protect_content, reply_parameters) -- https://core.telegram.org/bots/api#sendmediagroup
    reply_parameters = type(reply_parameters) == 'table' and EncodeJson(reply_parameters) or reply_parameters
    media = type(media) == "table" and EncodeJson(media) or media
    local success, res = api.request(config.endpoint .. api.token .. '/sendMediaGroup', {
        ['chat_id'] = chat_id,
        ['message_thread_id'] = message_thread_id,
        ['media'] = media,
        ['disable_notification'] = disable_notification,
        ['protect_content'] = protect_content,
        ['reply_parameters'] = reply_parameters
    }, media_map)
    return success, res
end

function api.edit_message_text(
    chat_id,
    message_id,
    text,
    parse_mode,
    entities,
    link_preview_options,
    reply_markup,
    inline_message_id
) -- https://core.telegram.org/bots/api#editmessagetext
    entities = type(entities) == "table" and EncodeJson(entities) or entities
    link_preview_options = type(link_preview_options) == "table"
            and EncodeJson(link_preview_options)
        or link_preview_options
    reply_markup = type(reply_markup) == "table" and EncodeJson(reply_markup)
        or reply_markup
    parse_mode = (type(parse_mode) == "boolean" and parse_mode == true)
            and "MarkdownV2"
        or parse_mode
    local success, res =
        api.request(config.endpoint .. api.token .. "/editMessageText", {
            ["chat_id"] = chat_id,
            ["message_id"] = message_id,
            ["text"] = text,
            ["parse_mode"] = parse_mode,
            ["entities"] = entities,
            ["link_preview_options"] = link_preview_options,
            ["reply_markup"] = reply_markup,
        })
    return success, res
end

function api.get_file(file_id) -- https://core.telegram.org/bots/api#getfile
    local success, res =
        api.request(config.endpoint .. api.token .. "/getFile", {
            ["file_id"] = file_id,
        })
    return success, res
end

function api.get_file_url(file_id)
    local file, err = api.get_file(file_id)
    if not file then
        return nil, err
    end
    local file_path = file.result.file_path
    if not file_path then
        return nil, "bad response from Telegram"
    end
    local file_url = "https://api.telegram.org/file/bot%s/%s"
        % {
            api.token,
            file_path,
        }
    return file_url
end

function api.download_file(file_id)
    local file_url = api.get_file_url(file_id)
    local status, headers, body = Fetch(file_url)
    if status ~= 200 then
        return nil, headers
    end
    local mime_type = headers["Content-Type"]
    return { data = body, mime_type = mime_type }
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
            for _, v in pairs(updates.result) do
                if v then
                    xpcall(api.process_update, debug.traceback, v)
                    offset = v.update_id + 1
                end
            end
        end
    end
end

return api

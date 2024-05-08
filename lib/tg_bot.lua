local api = require("telegram_lib")

local bot = {}

local function handle_start(message)
    local user_record, user_err =
        Accounts:findUserByTelegramUserID(message.from.id)
    if user_err then
        Log(kLogInfo, user_err)
        return
    end
    if user_record and user_record.username then
        api.send_message(
            message,
            "You've connected this Telegram account to the user "
                .. user_record.username
        )
        return
    end
    local request_id = Uuid()
    local display_name = "%s %s"
        % { message.from.first_name, message.from.last_name }
    local insert_ok, insert_err = Accounts:addTelegramLinkRequest(
        request_id,
        display_name,
        message.from.username,
        message.from.id
    )
    if not insert_ok then
        Log(kLogInfo, insert_err)
        api.send_message(
            message,
            "I encountered a database error while trying to do that. Please try again later."
        )
        return
    end
    local response = [[Hello! To get started with this bot, please connect your account: http://127.0.0.1:8082/link-telegram/%s. This link expires after 30 minutes.

If you don’t have an account already, this bot only works with an invite-only service. You’ll have to be invited by someone else who has an account.]] % {
        request_id,
    }
    api.send_message(message, response)
end

local function get_all_links_from_message(message)
    if not message.text and not message.caption then
        return {}
    end
    local entities = message.entities or message.caption_entities
    local text = message.text or message.caption
    local links = table.filtermap(entities, function(entity)
        return entity and (entity.type == "url" or entity.type == "text_link")
    end, function(entity)
        if entity.type == "url" then
            local start_pos = entity.offset + 1
            local end_pos = start_pos + entity.length
            return text:sub(start_pos, end_pos)
        elseif entity.type == "text_link" then
            return entity.url
        else
            return nil
        end
    end)
    return links
end

local function select_best_link(links)
    if #links == 1 then
        return links[1]
    end
    local max_score = 0
    local best_link = nil
    for i = 1, #links do
        local link = links[i]
        local score = bot.score_link(link)
        if score > max_score then
            best_link = link
            max_score = score
        end
    end
    return best_link
end

local function handle_enqueue(message)
    local user_record, user_err =
        Accounts:findUserByTelegramUserID(message.from.id)
    if user_err then
        Log(kLogInfo, user_err)
        return
    end
    local model = DbUtil.Model:new(nil, user_record.user_id)
    if not user_record or not user_record.username then
        return
    end
    if not message.text and not message.photo then
        if message.video then
            api.send_message(message, "I can’t save videos yet, sorry :(")
        else
            api.send_message(
                message,
                "I can’t find anything to save in that message."
            )
        end
        return
    end
    local links = get_all_links_from_message(message)
    local best_link = select_best_link(links)
    if best_link then
        local ok, err = model:enqueueLink(best_link)
        if not ok then
            Log(kLogInfo, "Error while enqueuing from bot: %s" % { err })
            api.send_message(
                message,
                "I encountered an error while trying to add that to the queue: %s"
                    % { err }
            )
            return
        end
        if #links == 1 then
            api.send_message(message, "Added that to the queue!")
        else
            api.send_message(message, "Added %s to the queue!" % { best_link })
        end
        return
    end
    if message.photo then
        print("processing photo")
        local max_width = 0
        local max_height = 0
        local largest_photo = nil
        for i = 1, #message.photo do
            local photo = message.photo[i]
            print("Found", EncodeJson(photo))
            if photo.width > max_width and photo.height > max_height then
                max_width = photo.width
                max_height = photo.height
                largest_photo = photo
            end
        end
        if not largest_photo then
            print("No photos in list")
            return
        end
        print("downloading image file", largest_photo.file_id)
        local photo_data, photo_err = api.download_file(largest_photo.file_id)
        if not photo_data then
            Log(kLogInfo, photo_err)
            return
        end
        print("adding to queue")
        local ok, err =
            model:enqueueImage(photo_data.mime_type, photo_data.data)
        if not ok then
            Log(kLogInfo, err)
            api.send_message(
                message,
                "I couldn’t add that photo to the queue: %s" % { err }
            )
            return
        end
        api.send_message(message, "Added that to the queue!")
        return
    end
    api.send_message(
        message,
        "I encountered an error while trying to add that to the queue."
    )
end

function bot.setup(token, debug, link_checker)
    bot.api = api.configure(token, debug)
    bot.link_checker = link_checker
end

function bot.score_link(link)
    local score = 1
    if bot.link_checker(link) then
        score = score + 1
    end
    -- Prefer e621 post page links, because they give more sources.
    if link:find("e621.net/posts/") or link:find("e926.net/posts/") then
        score = score + 1
    end
    return score
end

function bot.run()
    local pid = unix.fork()
    if pid == 0 then
        api.run(10)
    else
        return pid
    end
end

function api.on_message(message)
    Log(kLogDebug, EncodeJson(message))
    if message.text then
        if message.chat.type == "private" and message.text == "/start" then
            return handle_start(message)
        end
    end
    if message.chat.type == "private" then
        handle_enqueue(message)
    end
end

return bot

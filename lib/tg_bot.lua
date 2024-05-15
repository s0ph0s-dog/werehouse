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
    local request_id =
        NanoID.simple_with_prefix(IdPrefixes.telegram_link_request)
    local display_name = message.from.first_name
    if message.from.last_name then
        display_name = "%s %s" % { display_name, message.from.last_name }
    end
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
    local response = [[Hello! To get started with this bot, please connect your account: http://10.4.0.183:8082/link-telegram/%s. This link expires after 30 minutes.

If you don’t have an account already, this bot only works with an invite-only service. You’ll have to be invited by someone else who has an account.]] % {
        request_id,
    }
    api.send_message(message, response)
end

function bot.get_all_links_from_message(message)
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
            local end_pos = start_pos + entity.length - 1
            return text:utf16sub(start_pos, end_pos)
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
        local link = links[1]
        return link, bot.score_link(link)
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
    return best_link, max_score
end

local function handle_enqueue(message)
    local user_record, user_err =
        Accounts:findUserByTelegramUserID(message.from.id)
    if user_err then
        Log(kLogInfo, user_err)
        return
    end
    if user_record == Accounts.conn.NONE then
        return
    end
    local model = DbUtil.Model:new(nil, user_record.user_id)
    if not user_record or not user_record.username then
        return
    end
    if not message.text and not message.photo then
        if message.video then
            api.reply_to_message(message, "I can’t save videos yet, sorry :(")
        else
            api.reply_to_message(
                message,
                "I can’t find anything to save in this message."
            )
        end
        return
    end
    local links = bot.get_all_links_from_message(message)
    local best_link, score = select_best_link(links)
    if best_link then
        -- If score is greater than 0 or there's no photo part of the message,
        -- try adding the link to the queue.
        -- Score of 0 means none of the scraper plugins could process the link,
        -- so it's either a raw file URL or an unsupported URL.  Raw files might
        -- work, but unsupported URLs won't.  If there's an image, that has a
        -- better shot at finding something, so prefer that.
        if score > 0 or not message.photo then
            local ok, err = model:enqueueLink(best_link)
            if not ok then
                Log(kLogInfo, "Error while enqueuing from bot: %s" % { err })
                api.reply_to_message(
                    message,
                    "I encountered an error while trying to add this to the queue: %s"
                        % { err }
                )
                return
            end
            if #links == 1 then
                api.reply_to_message(message, "Added this to the queue!")
            else
                api.reply_to_message(
                    message,
                    "Added %s to the queue!" % { best_link }
                )
            end
            return
        end
    end
    if message.photo then
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
            Log(kLogDebug, "No photos in list")
            return
        end
        local photo_data, photo_err = api.download_file(largest_photo.file_id)
        if not photo_data then
            Log(kLogInfo, photo_err)
            return
        end
        local ok, err =
            model:enqueueImage(photo_data.mime_type, photo_data.data)
        if not ok then
            Log(kLogInfo, err)
            api.reply_to_message(
                message,
                "I couldn’t add this photo to the queue: %s" % { err }
            )
            return
        end
        api.reply_to_message(message, "Added this to the queue!")
        return
    end
    api.reply_to_message(
        message,
        "I encountered an error while trying to add this to the queue."
    )
end

function bot.setup(token, debug, link_checker)
    bot.api = api.configure(token, debug)
    bot.link_checker = link_checker
end

function bot.score_link(link)
    local score = 0
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

local api = require("third_party.telegram_lib")

local bot = {}

local function handle_start(message)
    local user_record, user_err =
        Accounts:findUserByTelegramUserID(message.from.id)
    if user_err then
        Log(kLogInfo, user_err)
        return
    end
    if user_record and user_record.username then
        bot.notify_account_linked(message, user_record.username)
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
    local response = [[Hello! To get started with this bot, please connect your account: https://werehouse.s0ph0s.dog/link-telegram/%s. This link expires after 30 minutes.

If you don’t have an account already, this bot only works with an invite-only service. You’ll have to be invited by someone else who has an account.]] % {
        request_id,
    }
    api.send_message(message, response)
end

local function handle_chatid(message)
    local chat_id = message.chat.id
    api.reply_to_message(message, "The ID of this chat is %d" % { chat_id })
end

function bot.get_all_links_from_message(message)
    if
        not message.text
        and not message.caption
        and not message.reply_markup
    then
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
    if message.reply_markup and message.reply_markup.inline_keyboard then
        local button_links = table.filtermap(
            table.flatten(message.reply_markup.inline_keyboard),
            function(i)
                return i.url and i.url:startswith("http")
            end,
            function(i)
                return i.url
            end
        )
        for i = 1, #button_links do
            links[#links + 1] = button_links[i]
        end
    end
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

local function update_queue_with_tg_ids(result, tg_err, model, queue_entry)
    Log(kLogDebug, "Telegram result: %s" % { EncodeJson(result) })
    if result and result.ok and result.result then
        local q_ok, q_err = model:updateQueueItemTelegramIds(
            queue_entry.qid,
            result.result.chat.id,
            result.result.message_id
        )
        if not q_ok then
            Log(
                kLogInfo,
                "Error while updating queue entry with TG message IDs: %s"
                    % { q_err }
            )
        end
    else
        Log(
            kLogInfo,
            "Error from Telegram while replying to the user's message: %s"
                % { tostring(tg_err) }
        )
    end
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
            local queue_entry, err = model:enqueueLink(
                best_link,
                message.chat.id,
                message.message_id
            )
            if not queue_entry then
                Log(kLogInfo, "Error while enqueuing from bot: %s" % { err })
                api.reply_to_message(
                    message,
                    "I encountered an error while trying to add this to the queue: %s"
                        % { err }
                )
                return
            end
            local result, tg_err
            if #links == 1 then
                result, tg_err =
                    api.reply_to_message(message, "Added this to the queue!")
            else
                result, tg_err = api.reply_to_message(
                    message,
                    "Added %s to the queue!" % { best_link }
                )
            end
            update_queue_with_tg_ids(result, tg_err, model, queue_entry)
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
        local queue_entry, err = model:enqueueImage(
            photo_data.mime_type,
            photo_data.data,
            message.chat.id,
            message.message_id
        )
        if not queue_entry then
            Log(kLogInfo, err)
            api.reply_to_message(
                message,
                "I couldn’t add this photo to the queue: %s" % { err }
            )
            return
        end
        local result, tg_err =
            api.reply_to_message(message, "Added this to the queue!")
        update_queue_with_tg_ids(result, tg_err, model, queue_entry)
        return
    end
    api.reply_to_message(
        message,
        "I encountered an error while trying to add this to the queue."
    )
end

function bot.notify_account_linked(tg_userid, username)
    api.send_message(
        tg_userid,
        "You've connected this Telegram account to the user " .. username
    )
end

function bot.post_image(to_chat, image_file, caption, follow_up, spoiler)
    local photo_result, err =
        api.send_photo(to_chat, image_file, nil, caption, nil, nil, spoiler)
    if not photo_result or not photo_result.ok then
        Log(kLogWarn, EncodeJson(err))
        return
    end
    if follow_up then
        local ping_result
        ping_result, err = api.reply_to_message(photo_result.result, follow_up)
        if not ping_result then
            Log(kLogWarn, EncodeJson(err))
        end
    end
end

function bot.post_animation(
    to_chat,
    animation_file,
    caption,
    follow_up,
    spoiler
)
    local animation_result, err = api.send_video(
        to_chat,
        animation_file,
        nil,
        nil,
        nil,
        caption,
        nil,
        spoiler
    )
    if not animation_result or not animation_result.ok then
        Log(kLogWarn, tostring(EncodeJson(err)))
        return
    end
    if follow_up then
        local ping_result
        ping_result, err =
            api.reply_to_message(animation_result.result, follow_up)
        if not ping_result then
            Log(kLogWarn, tostring(EncodeJson(err)))
        end
    end
end

function bot.post_video(to_chat, video_file, caption, follow_up, spoiler)
    local video_result, err = api.send_video(
        to_chat,
        video_file,
        nil,
        nil,
        nil,
        nil,
        caption,
        nil,
        spoiler
    )
    if not video_result or not video_result.ok then
        Log(kLogWarn, EncodeJson(err))
        return
    end
    if follow_up then
        local ping_result
        ping_result, err = api.reply_to_message(video_result.result, follow_up)
        if not ping_result then
            Log(kLogWarn, EncodeJson(err))
        end
    end
end

local TYPE_MAP = {
    [DbUtil.k.ImageKind.Video] = "video",
    [DbUtil.k.ImageKind.Image] = "photo",
    [DbUtil.k.ImageKind.Animation] = "animation",
}

function bot.post_media_group(to_chat, media_list, follow_up)
    assert(media_list)
    assert(#media_list > 0)
    if #media_list < 2 then
        local media = media_list[1]
        if media.kind == DbUtil.k.ImageKind.Image then
            bot.post_image(
                to_chat,
                media.file_path,
                media.caption,
                follow_up,
                media.spoiler
            )
        elseif media.kind == DbUtil.k.ImageKind.Video then
            bot.post_video(
                to_chat,
                media.file_path,
                media.caption,
                follow_up,
                media.spoiler
            )
        elseif media.kind == DbUtil.k.ImageKind.Animation then
            bot.post_animation(
                to_chat,
                media.file_path,
                media.caption,
                follow_up,
                media.spoiler
            )
        end
    end
    local media_upload = {}
    local api_media_list = table.map(media_list, function(item)
        media_upload[item.file] = item.file_path
        return {
            type = TYPE_MAP[item.kind],
            caption = item.sources_text,
            has_spoiler = item.spoiler,
            media = "attach://" .. item.file,
        }
    end)
    local batches = table.batch(api_media_list, 10)
    local fist_media_group_result = nil
    local media_group_result, mg_err
    for i = 1, #batches do
        media_group_result, mg_err =
            api.send_media_group(to_chat, batches[i], media_upload)
        if not media_group_result then
            Log(kLogWarn, tostring(EncodeJson(mg_err)))
            return
        end
        if not first_media_group_result then
            first_media_group_result = media_group_result
        end
    end
    if follow_up then
        -- TODO: confirm that this actually replies.
        local ping_result, p_err =
            api.reply_to_message(media_group_result.result, follow_up)
        if not ping_result then
            Log(kLogWarn, tostring(EncodeJson(p_err)))
        end
    end
end

function bot.update_queue_message_with_status(chat_id, message_id, new_text)
    api.edit_message_text(chat_id, message_id, new_text)
end

function bot.setup(token, debug, link_checker)
    if token then
        bot.api = api.configure(token, debug)
    end
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
        if bot.api then
            bot.api.run(10)
        else
            Log(
                kLogWarn,
                "Not starting Telegram bot because no token provided."
            )
        end
    else
        return pid
    end
end

function api.on_message(message)
    Log(kLogDebug, EncodeJson(message))
    if message.text then
        if message.chat.type == "private" and message.text == "/start" then
            return handle_start(message)
        elseif message.text == "/chatid" then
            return handle_chatid(message)
        end
    end
    if message.chat.type == "private" then
        handle_enqueue(message)
    end
end

return bot

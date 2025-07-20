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
    local display_name = message.from.first_name
    if message.from.last_name then
        display_name = "%s %s" % { display_name, message.from.last_name }
    end
    local request_id, insert_err = Accounts:addTelegramLinkRequest(
        display_name,
        message.from.username,
        message.from.id
    )
    if not request_id then
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
    local negative_warn = chat_id < 0 and " (the negative sign is important)"
        or ""
    api.reply_to_message(
        message,
        "The ID of this chat is `%d`%s" % { chat_id, negative_warn },
        nil,
        "MarkdownV2"
    )
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

local function update_queue_with_tg_source_and_cache(
    model,
    queue_entry,
    message
)
    local fo = message.forward_origin
    if fo and fo.type == "channel" then
        if fo.chat.username then
            local source_link = "https://t.me/%s/%d?single"
                % {
                    fo.chat.username,
                    fo.message_id,
                }
            model:updateQueueItemTelegramLink(queue_entry.qid, source_link)
            local cache = DbUtil.TGForwardCache:new()
            local kinds = {
                -- Animation needs to come before document because sometimes Telegram includes both for a single message, and the rest of the code will see mime_type = "video/mp4" and assume it's a video.
                "animation",
                "document",
                "video",
                "photo",
            }
            local media_kind = nil
            local media = nil
            for i = 1, #kinds do
                local kind = kinds[i]
                if message[kind] then
                    media_kind = kind
                    media = message[kind]
                end
            end
            local c_ok, c_err = cache:insertChannelPost(
                fo.chat.id,
                fo.chat.title,
                fo.chat.username,
                fo.message_id,
                media_kind,
                media
            )
            if not c_ok then
                Log(kLogInfo, c_err)
            end
        end
    end
end

local function message_is_saveable(message)
    if message.text or message.caption then
        return true
    elseif message.photo then
        return true
    elseif message.document then
        local mime_type = message.document.mime_type
        if not mime_type then
            return false,
                "This file was sent without information to tell me what kind of file it is, so I can’t tell if I can save it."
        elseif not Ris.SEARCHABLE_MIME_TYPES[mime_type] then
            return false,
                "This file is %s, which I can’t automatically find sources for."
                    % { mime_type }
        end
        return true
    elseif message.video then
        return false,
            "I can’t find sources for a video, so I can’t save this."
    elseif message.animation then
        return false,
            "I can’t find sources for a video-pretending-to-be-a-GIF, so I can’t save this."
    else
        return false, "I can’t find anything to save in this message."
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
    local is_saveable, why_not = message_is_saveable(message)
    if not is_saveable then
        api.reply_to_message(message, why_not)
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
            local queue_entry, err = model:enqueueLink(best_link)
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
    if message.photo or message.document then
        local file_id = nil
        if message.photo then
            local max_width = 0
            local max_height = 0
            local largest_photo = nil
            for i = 1, #message.photo do
                local photo = message.photo[i]
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
            file_id = largest_photo.file_id
        else
            file_id = message.document.file_id
        end
        local photo_data, photo_err = api.download_file(file_id)
        if not photo_data then
            Log(kLogInfo, tostring(photo_err))
            return
        end
        -- Telegram images are always image/jpeg, so the MIME type is not included anywhere. The server response is application/octet-stream, which is not helpful.
        local queue_entry, err =
            model:enqueueImage("image/jpeg", photo_data.data)
        if not queue_entry then
            Log(kLogInfo, tostring(err))
            api.reply_to_message(
                message,
                "I couldn’t add this photo to the queue: %s" % { err }
            )
            return
        end
        local result, tg_err =
            api.reply_to_message(message, "Added this to the queue!")
        update_queue_with_tg_ids(result, tg_err, model, queue_entry)
        update_queue_with_tg_source_and_cache(model, queue_entry, message)
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
    if follow_up and #follow_up > 0 then
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

local function clone_media_table(t)
    local t2 = {}
    for k, v in pairs(t) do
        if type(v) == "string" and string.len(v) > 100 then
            t2[k] = "[redacted long string]"
        elseif type(v) == "table" then
            t2[k] = clone_media_table(v)
        else
            t2[k] = v
        end
    end
    return t2
end

local ALLOWED_MEDIA_KEYS = {
    type = true,
    media = true,
    caption = true,
    parse_mode = true,
    caption_entities = true,
    show_caption_above_media = true,
    has_spoiler = true,
    thumbnail = true,
    cover = true,
    start_timestamp = true,
    width = true,
    height = true,
    duration = true,
    supports_streaming = true,
    performer = true,
    title = true,
    disable_content_type_detection = true,
}

---Remove any keys from a media object which are not used by the Telegram API.
---I forgot to scrub the `file` key which contained a complete copy of the
---original data, so this will prevent similar mistakes in the future.
---@param media table
local function filter_keys(media)
    for key, _ in pairs(media) do
        if not ALLOWED_MEDIA_KEYS[key] then
            Log(kLogDebug, "Removed disallowed key: " .. key)
            media[key] = nil
        end
    end
end

function bot.post_media_group(to_chat, media_list, follow_up)
    assert(media_list)
    assert(#media_list > 0)
    if #media_list < 2 then
        local media = media_list[1]
        if media.kind == DbUtil.k.ImageKind.Image then
            bot.post_image(
                to_chat,
                media.resized and { data = media.resized } or media.file_path,
                media.sources_text,
                follow_up,
                media.spoiler
            )
        elseif media.kind == DbUtil.k.ImageKind.Video then
            bot.post_video(
                to_chat,
                media.file_path,
                media.sources_text,
                follow_up,
                media.spoiler
            )
        elseif media.kind == DbUtil.k.ImageKind.Animation then
            bot.post_animation(
                to_chat,
                media.file_path,
                media.sources_text,
                follow_up,
                media.spoiler
            )
        end
        return true
    end
    local api_media_list = table.map(media_list, function(item)
        return {
            type = TYPE_MAP[item.kind],
            caption = item.sources_text,
            has_spoiler = item.spoiler,
            media = "attach://" .. item.file,
            file = item.file,
            file_path = item.resized and { data = item.resized }
                or item.file_path,
        }
    end)
    local batches = table.batch(api_media_list, 10)
    if not batches or #batches == 0 then
        return
    end
    local first_media_group_result = nil
    local media_group_result, mg_err
    for i = 1, #batches do
        local batch = batches[i]
        local media_upload = {}
        for j = 1, #batch do
            local media = batch[j]
            media_upload[media.file] = media.file_path
            filter_keys(media)
        end
        media_group_result, mg_err =
            api.send_media_group(to_chat, batch, media_upload)
        Log(
            kLogDebug,
            "media_group_result=%s" % { EncodeJson(media_group_result) }
        )
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
            api.reply_to_message(first_media_group_result.result[1], follow_up)
        if not ping_result then
            Log(kLogWarn, tostring(EncodeJson(p_err)))
        end
    end
end

local function resize_image(image)
    local f = img.loadfile(image.file_path)
    if not f then
        return nil, "unable to load image file"
    end
    local smaller, err = f:resize(1200)
    if not smaller then
        return nil, "unable to resize image file: " .. err
    end
    local result = smaller:savebufferjpeg()
    if not result then
        return nil, "unable to encode resized image as JPEG"
    end
    image.resized = result
    return true
end

local function check_rules(media)
    if media.kind == DbUtil.k.ImageKind.Image then
        if
            media.file_size > 10485760
            or (media.width + media.height) > 10000
        then
            local ok = resize_image(media)
            if not ok then
                return false,
                    "I couldn't resize this image to fit within Telegram's limits (size < 10,485,760 bytes and width + height < 10,000 px): "
                        .. ok
            end
        end
        local aspect_ratio = media.width / media.height
        if aspect_ratio > 20 or aspect_ratio < 0.05 then
            return false,
                "Image aspect ratio is too extreme (must be at most 20:1)"
        end
        return true
    elseif media.kind == DbUtil.k.ImageKind.Video then
        if media.file_size > 50 * 1000 * 1000 then
            return false,
                "Video file size is too large (must be smaller than 50 MB)"
        end
        if media.mime_type ~= "video/mp4" then
            return false,
                "Video file container is not supported by Telegram (must be mp4)"
        end
        return true
    elseif media.kind == DbUtil.k.ImageKind.Animation then
        if media.file_size > 50 * 1000 * 1000 then
            return false,
                "Animation file size is too large (must be smaller than 50 MB)"
        end
        return true
    else
        return false, "Telegram doesn't support this kind of file"
    end
end

---Version of the function below which tries to resize all of the media files in
---a batch if the sum of their sizes is too large for a POST request. This isn't
---used currently, but I didn't want to throw the code away if I need it in the
---future.
local function share_media_check_batch(chat_id, media_list, follow_up)
    local errors = {}
    local batches = table.batch(media_list, 10)
    if not batches then
        return nil, "Unable to divide media list into batches of 10."
    end
    for i = 1, #batches do
        local batch = batches[i]
        local batch_size = 0
        for j = 1, #batch do
            local media = batch[j]
            local ok, err = check_rules(media)
            if not ok then
                errors[#errors + 1] = "Image %d: %s" % { media.image_id, err }
            end
            batch_size = batch_size
                + (media.resized and media.resized:len() or media.file_size)
        end
        if batch_size > 10 * 1000 * 1000 then
            batch_size = 0
            for j = 1, #batch do
                local media = batch[j]
                local ok, err = resize_image(media)
                if not ok then
                    errors[#errors + 1] = "Image %d: %s"
                        % { media.image_id, err }
                end
                batch_size = batch_size + media.resized:len()
            end
            if batch_size > 10 * 1000 * 1000 then
                errors[#errors + 1] =
                    "Could not resize images to a small enough size to upload to Telegram."
            end
        end
    end
    if #errors > 0 then
        return nil, errors
    end
    bot.post_media_group(chat_id, media_list, follow_up)
    return true
end

function bot.share_media(chat_id, media_list, follow_up)
    local errors = {}
    for i = 1, #media_list do
        local media = media_list[i]
        local ok, err = check_rules(media)
        if not ok then
            errors[#errors + 1] = "Image %d: %s" % { media.image_id, err }
        end
    end
    if #errors > 0 then
        return nil, errors
    end
    bot.post_media_group(chat_id, media_list, follow_up)
    return true
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
                kLogFatal,
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

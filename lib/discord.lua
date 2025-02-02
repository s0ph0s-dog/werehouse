local function process_media(media, idx, payload_json, payload_multipart)
    local embeds = payload_json.embeds
    embeds[#embeds + 1] = {
        url = "",
        image = {
            url = "attachment://" .. media.file,
        },
        author = {
            name = "",
        },
        description = "",
    }
    payload_multipart["files[" .. idx .. "]"] = {
        data = media.file,
    }
end

local function prepare_request(media, boundary, msg_idx, msg_count)
    Log(kLogDebug, "media to send: " .. EncodeJson(media))
    local message_text = "(%d/%d) %s"
        % {
            msg_idx,
            msg_count,
            media.sources_text,
        }
    local filename = media.file
    local ext = FsTools.MIME_TO_EXT[media.mime_type]
    if not filename:endswith(ext) then
        Log(kLogDebug, "Adding %s to end of filename" % { ext })
        filename = filename .. ext
    end
    if media.spoiler then
        filename = "SPOILER_" .. filename
    end
    local payload_json = {
        content = message_text,
        allowed_mentions = {
            parse = { [0] = false },
        },
        attachments = {
            {
                id = msg_idx,
                filename = filename,
                content_type = media.mime_type,
            },
        },
    }
    local media_data
    if media.resized then
        media_data = media.resized
    else
        media_data = Slurp(media.file_path)
    end
    local payload_multipart = {
        ["files[" .. msg_idx .. "]"] = {
            data = media_data,
            filename = filename,
        },
    }
    payload_multipart.payload_json = {
        data = EncodeJson(payload_json),
        content_type = "application/json",
    }
    return Multipart.encode(payload_multipart, boundary)
end

local function wait_for_ratelimit(headers)
    if type(headers) ~= "table" then
        return
    end
    local remaining = tonumber(headers["X-RateLimit-Remaining"])
    local reset_at = tonumber(headers["X-RateLimit-Reset"])
    local reset_after = tonumber(headers["X-RateLimit-Reset-After"])
    if remaining and remaining < 2 then
        local now = unix.clock_gettime(unix.CLOCK_REALTIME)
        local duration = 0
        if reset_at then
            duration = reset_at - now
        end
        local wait_time = math.max(duration, reset_after or 0)
        Sleep(wait_time)
    end
end

local function send_media(webhook_url, media_list, ping_text)
    local total_msgs = #media_list + 1
    for i = 1, #media_list do
        local media = media_list[i]
        local boundary = "__X_HELLO_DISCORD__"
        local request_body, err =
            prepare_request(media, boundary, i, total_msgs)
        if not request_body then
            return nil, err
        end
        repeat
            local status, headers, resp = Fetch(webhook_url .. "?wait=true", {
                method = "POST",
                body = request_body,
                headers = {
                    ["Content-Type"] = "multipart/form-data; charset=utf-8; boundary="
                        .. boundary,
                },
            })
            wait_for_ratelimit(headers)
            if status ~= 200 then
                return nil, resp or headers
            end
        until status ~= 429
    end
    local ping_message = "(%d/%d)\n%s"
        % {
            total_msgs,
            total_msgs,
            ping_text:trim(),
        }
    local ping_json = {
        content = ping_message,
        allowed_mentions = {
            parse = { "users" },
        },
    }
    local ping_body = EncodeJson(ping_json)
    repeat
        local status, headers, resp = Fetch(webhook_url .. "?wait=true", {
            method = "POST",
            body = ping_body,
            headers = {
                ["Content-Type"] = "application/json",
            },
        })
        wait_for_ratelimit(headers)
        if status ~= 200 then
            return nil, resp or headers
        end
    until status ~= 429
    return true
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
    local result = smaller:savebufferwebp()
    if not result then
        return nil, "unable to encode resized image as WebP"
    end
    image.resized = result
    image.file_size = #result
    image.width = smaller:width()
    image.height = smaller:height()
    return true
end

local function check_rules(media)
    if media.kind == DbUtil.k.ImageKind.Image then
        if
            media.file_size > 10 * 1000 * 1000
            or media.width > 2000
            or media.height > 2000
        then
            local ok = resize_image(media)
            if not ok then
                return false,
                    "I couldn't resize this image to fit within Discord's limits (size < 10 MB): "
                        .. ok
            end
        end
        return true
    elseif media.kind == DbUtil.k.ImageKind.Video then
        if media.file_size > 10 * 1000 * 1000 then
            return false,
                "Video file size is too large (must be smaller than 10 MB)"
        end
        --[[
        if media.mime_type ~= "video/mp4" then
            return false,
                "Video file container is not supported by Discord (must be mp4)"
        end
        ]]
        return true
    elseif media.kind == DbUtil.k.ImageKind.Animation then
        if media.file_size > 10 * 1000 * 1000 then
            return false,
                "Animation file size is too large (must be smaller than 10 MB)"
        end
        return true
    else
        return false, "Discord doesn't support this kind of file"
    end
end

local function share_media(webhook_url, media_list, ping_text)
    local errors = {}
    for i = 1, #media_list do
        local media = media_list[i]
        local ok, err = check_rules(media)
        if not ok then
            errors[#errors + 1] = "Record %d: %s" % { media.image_id, err }
        end
    end
    if #errors > 0 then
        return nil, errors
    end
    local ok, err = send_media(webhook_url, media_list, ping_text)
    if not ok then
        Log(kLogInfo, "Unable to share to Discord: " .. err)
        return false, "Request to send messages on Discord failed."
    end
    return true
end

return {
    share_media = share_media,
}

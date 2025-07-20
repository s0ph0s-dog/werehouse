local sharing = require("web.sharing")

local function render_invite(r)
    local invite_record = Accounts:findInvite(r.params.invite_code)
    -- If the invite doesn't exist, or if it has already been used.
    if not invite_record or invite_record.invitee then
        return Fm.serve404()
    end
    local params = { error = r.session.error, invite_record = invite_record }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.render("accept_invite", params)
end

local function serve_error_page(code)
    return function(errormsg, value)
        return Fm.serveResponse(
            code,
            nil,
            Fm.render(tostring(code), {
                error = errormsg,
                value = value,
            })
        )
    end
end

local username_validator_rule = {
    "username",
    minlen = 2,
    maxlen = 128,
    msg = "%s must be between 2 and 128 characters",
}
local password_validator_rule = {
    "password",
    minlen = 16,
    maxlen = 128,
    msg = "%s must be between 16 and 128 characters",
}
local confirm_password_validator_rule = {
    "password_confirm",
    minlen = 16,
    maxlen = 128,
    msg = "%s must be between 16 and 128 characters",
}
local invite_validator_rule = { "invite_code", minlen = 24, maxlen = 24 }

local invite_validator = Fm.makeValidator {
    invite_validator_rule,
    username_validator_rule,
    password_validator_rule,
    confirm_password_validator_rule,
    all = true,
    otherwise = serve_error_page(400),
}

local login_validator = Fm.makeValidator {
    username_validator_rule,
    password_validator_rule,
    all = true,
    otherwise = serve_error_page(400),
}

local change_password_validator = Fm.makeValidator {
    {
        "current_password",
        minlen = 16,
        maxlen = 128,
        msg = "%s must be between 16 and 128 characters",
    },
    password_validator_rule,
    confirm_password_validator_rule,
    all = true,
    otherwise = serve_error_page(400),
}

local function hash_password(password)
    return argon2.hash_encoded(password, GetRandomBytes(32), {
        variant = "id",
        m_cost = 65536,
        t_cost = 16,
        parallelism = 4,
    })
end

local function hex_encode(str)
    return (
        str:gsub(".", function(char)
            return string.format("%02x", char:byte())
        end)
    )
end

local function check_password_breach(password)
    local sha1 = hex_encode(GetCryptoHash("SHA1", password))
    local prefix = sha1:sub(1, 5)
    local suffix = sha1:sub(6)
    suffix = suffix:upper()
    local status, headers, body =
        Fetch("https://api.pwnedpasswords.com/range/" .. prefix)
    if not status then
        return nil,
            "Unable to query pwnedpasswords.com: " .. EncodeJson(headers)
    end
    if status ~= 200 then
        return nil, "HTTP error " .. tostring(status)
    end
    for result in body:gmatch("(%x+):%d+") do
        if result == suffix then
            return true
        end
    end
    return false
end

local function accept_invite(r)
    r.session.error = nil
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        Log(
            kLogInfo,
            "No invite records in database for %s" % { r.params.invite_code }
        )
        return Fm.serve404()
    end
    local valid, val_err = invite_validator(r.params)
    if not valid then
        Log(
            kLogInfo,
            "invite form validation error: %s" % { EncodeJson(val_err) }
        )
        r.session.error = table.concat(val_err, ", ")
        return Fm.serveRedirect(r.path, 302)
    end
    if r.params.tos ~= "accepted" then
        r.session.error =
            "You must accept the Terms of Service if you want to register."
        return Fm.serveRedirect(r.path, 302)
    end
    if r.params.password ~= r.params.password_confirm then
        -- TODO: password mismatch
        r.session.error = "Passwords do not match."
        return Fm.serveRedirect(r.path, 302)
    end
    local breached, b_err = check_password_breach(r.params.password)
    if b_err then
        return Fm.serve500()
    end
    if breached then
        r.session.error =
            "That password has previously been found in a password breach. Please choose a different one."
        return Fm.serveRedirect(r.path, 302)
    end
    local pw_hash = hash_password(r.params.password)
    local result, errmsg =
        Accounts:acceptInvite(r.params.invite_code, r.params.username, pw_hash)
    if not result then
        Log(kLogInfo, "Invitation acceptance failed: %s" % { errmsg })
        return Fm.serve400()
    end
    Log(kLogInfo, "Registration success!")
    r.session.toast = {
        msg = 'Welcome to Werehouse! Check out the <a href="/help/getting-started">Getting Started</a> guide.',
    }
    return Fm.serveRedirect("/login", 302)
end

local function render_login(r)
    return Fm.serveContent("login", { error = r.session.error })
end

local function accept_login(r)
    r.session.error = nil
    local user_record, errmsg = Accounts:findUser(r.params.username)
    if not user_record then
        Log(kLogDebug, errmsg)
        -- Resist timing-based oracle attack for username discovery.
        local _ = argon2.verify("foobar", r.params.password)
        r.session.error = "Invalid credentials"
        return Fm.serveRedirect("/login", 302)
    end
    Log(kLogDebug, tostring(EncodeJson(user_record)))
    local result, verify_err =
        argon2.verify(user_record.password, r.params.password)
    if not result then
        r.session.error = "Invalid credentials"
        Log(
            kLogVerbose,
            "Denying attempted login for %s due to error from argon2: %s"
                % { tostring(r.params.username), tostring(verify_err) }
        )
        return Fm.serveRedirect("/login", 302)
    end
    local ip = WebUtility.get_client_ip(r)
    local session_id, errmsg2 = Accounts:createSessionForUser(
        user_record.user_id,
        r.headers["User-Agent"],
        ip
    )
    if not session_id then
        Log(kLogDebug, errmsg2)
        r.session.error = errmsg
        return Fm.serveRedirect("/login", 302)
    end
    WebUtility.set_login_cookie(r, session_id)
    local redirect_url = "/home"
    if r.session.after_login_url then
        redirect_url = r.session.after_login_url
        -- r.session.after_login_url = nil
    end
    return Fm.serveRedirect(redirect_url, 302)
end

local function set_after_dialog_action(r)
    local path = r.makePath(r.path, r.params)
    -- Explicitly list every query parameter we might care about, because metatable __index indirection prevents this from getting all of them.
    local url = r.makeUrl(
        path,
        { params = {
            page = r.params.page,
        } }
    )
    Log(kLogDebug, "Updating after-dialog redirect to: " .. url)
    r.session.after_dialog_action = url
end

local render_home = WebUtility.login_required(function(r, _)
    local queue_records, errmsg2 = Model:getRecentQueueEntries()
    if not queue_records then
        Log(kLogDebug, tostring(errmsg2))
        return Fm.serve500()
    end
    local image_records, errmsg3 = Model:getRecentImageEntries()
    if not image_records then
        Log(kLogDebug, errmsg3)
        return Fm.serve500()
    end
    set_after_dialog_action(r)
    return Fm.serveContent("home", {
        queue_records = queue_records,
        image_records = image_records,
        fn = WebUtility.image_functions,
    })
end)

local render_queue_image = WebUtility.login_required(function(r, _)
    local content_type = Nu.guess_mime_from_url(r.params.filename)
        or "application/octet-stream"
    local image_data = FsTools.load_queue(r.params.filename, Model.user_id)
    if not image_data then
        return Fm.serve404()
    end
    return Fm.serveResponse(200, {
        ContentType = content_type,
        ["Cache-Control"] = "private, max-age=31536000",
    }, image_data)
end)

local render_thumbnail_file = WebUtility.login_required(function(r, _)
    local result, errmsg = Model:getThumbnailImageById(r.params.thumbnail_id)
    if not result then
        Log(kLogDebug, tostring(errmsg))
        return Fm.serve404()
    end
    if r.headers["If-None-Match"] == result.thumbnail_hash then
        return Fm.serveResponse(304)
    end
    r.headers.ContentType = result.mime_type
    return Fm.serveResponse(200, {
        ContentType = result.mime_type,
        ETag = result.thumbnail_hash,
        ["Cache-Control"] = "max-age=3600",
    }, result.thumbnail)
end)

local allowed_image_types = {
    ["image/png"] = true,
    ["image/jpeg"] = true,
    ["image/webp"] = true,
    ["image/gif"] = true,
}

local render_enqueue = WebUtility.login_required(function(r, _)
    local params = {}
    if r.session.error then
        Fm.setTemplateVar("error", r.session.error)
        r.headers["HX-Retarget"] = "#dialog"
        r.session.error = nil
    end
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("enqueue", params)
end)

local accept_enqueue = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/home")
    if r.params.cancel then
        return redirect
    end
    if
        r.params.link
        and #r.params.link > 0
        and r.params.multipart.image
        and r.params.multipart.image.filename
        and #r.params.multipart.image.filename > 0
    then
        return Fm.serveError(
            400,
            nil,
            "Must provide either link or image, not both."
        )
    end
    if r.params.link and #r.params.link > 0 then
        local result, errmsg = Model:enqueueLink(r.params.link)
        if not result then
            Log(kLogWarn, errmsg)
            r.session.error = errmsg
            return Fm.serveRedirect(302, "/enqueue")
        end
        return redirect
    elseif
        r.params.multipart.image
        and allowed_image_types[r.params.multipart.image.headers["content-type"]]
    then
        local image_data = r.params.multipart.image.data
        local result, errmsg = Model:enqueueImage(
            r.params.multipart.image.headers["content-type"],
            image_data
        )
        if not result then
            Log(kLogWarn, tostring(errmsg))
        end
        return redirect
    else
        return Fm.serve400(
            "Must provide either link or PNG/JPEG/GIF image file."
        )
    end
    return Fm.serve500("This should have been unreachable")
end)

local mime_to_encoder_map = {
    ["image/jxl"] = function(i)
        return i:savebufferjxl()
    end,
    ["image/jpeg"] = function(i)
        return i:savebufferjpeg()
    end,
    ["image/webp"] = function(i)
        return i:savebufferwebp()
    end,
}

local function make_preview(filename, ext, real_path)
    Log(
        kLogInfo,
        "Making preview for '%s'. Encoding as '%s'. Source file on disk at '%s'."
            % { filename, ext, real_path }
    )
    local mime = Nu.ext_to_mime[ext]
    Log(kLogInfo, "Preview MIME type: " .. tostring(mime))
    local fullsize, err = img.loadfile(real_path)
    if not fullsize then
        return nil, err
    end
    local width = fullsize:width()
    local max_view_width = 1524
    if width > max_view_width then
        local new_height =
            math.floor((max_view_width / width) * fullsize:height())
        local shrunk, resize_err = fullsize:resize(new_height, max_view_width)
        if not shrunk then
            return nil, resize_err
        end
        fullsize = shrunk
    end
    local preview_data, encode_err = mime_to_encoder_map[mime](fullsize)
    if not preview_data then
        return nil, encode_err
    end
    local preview_filename = filename .. "." .. ext
    local saved, save_err =
        FsTools.save_preview(preview_data, mime, preview_filename)
    if not saved then
        return nil, save_err
    end
    local _, cache_path =
        FsTools.make_preview_path_from_filename(nil, preview_filename)
    return cache_path
end

local render_preview_file = WebUtility.login_required(function(r)
    local preview_filename = r.params.filename
    if not preview_filename then
        return Fm.serve400()
    end
    local source_filename, ext = preview_filename:match("(.+)%.(%a%a%a%a?)$")
    if not source_filename then
        return Fm.serve400()
    end
    local preview_path = "previews/%s/%s/%s"
        % {
            preview_filename:sub(1, 1),
            preview_filename:sub(2, 2),
            preview_filename,
        }
    SetHeader("Cache-Control", "private, max-age=31536000")
    if unix.access(preview_path, unix.R_OK) then
        return Fm.serveAsset(preview_path)
    end
    local real_path = "images/%s/%s/%s"
        % {
            source_filename:sub(1, 1),
            source_filename:sub(2, 2),
            source_filename,
        }
    local preview, preview_err = make_preview(source_filename, ext, real_path)
    if not preview then
        Log(kLogInfo, "Unable to generate preview: " .. preview_err)
        return Fm.serve500()
    end
    return Fm.serveAsset(preview)
end)

local render_image_file = WebUtility.login_required(function(r)
    if not r.params.filename then
        return Fm.serve400()
    end
    local path = "images/%s/%s/%s"
        % {
            r.params.filename:sub(1, 1),
            r.params.filename:sub(2, 2),
            r.params.filename,
        }
    SetHeader("Cache-Control", "private, max-age=31536000")
    return Fm.serveAsset(path)
end)

local function render_share_widget(user_id, params)
    local share_ping_lists, spl_err = Model:getAllSharePingLists()
    if not share_ping_lists then
        Log(kLogInfo, tostring(spl_err))
    end
    local telegram_accounts, tg_err =
        Accounts:getAllTelegramAccountsForUser(user_id)
    if not telegram_accounts then
        Log(kLogInfo, tg_err)
    end

    params.share_ping_lists = share_ping_lists
    params.telegram_accounts = telegram_accounts
end

local function render_image_internal(r, user_record)
    local image_id = r.params.image_id
    if not image_id then
        return Fm.serve400()
    end
    local image, image_err = Model:getImageById(image_id)
    if not image then
        Log(kLogInfo, tostring(image_err))
        return Fm.serve404()
    end
    local image_with_thumb, iwt_err = Model:getFirstThumbnailByImageId(image_id)
    if not image_with_thumb then
        Log(kLogInfo, tostring(iwt_err))
        return Fm.serve500()
    end
    image.first_thumbnail_id = image_with_thumb.first_thumbnail_id
    local artists, artists_err = Model:getArtistsForImage(image_id)
    if not artists then
        Log(kLogInfo, artists_err)
    end
    local delete_artists = r.params.delete_artists
    if delete_artists then
        artists = table.filter(artists, function(a)
            return table.find(delete_artists, a.artist_id) ~= nil
        end)
    end
    local allartists, allartists_err = Model:getAllArtists()
    if not allartists then
        Log(kLogInfo, allartists_err)
    end
    local tags, tags_err = Model:getTagsForImage(image_id)
    if not tags then
        Log(kLogInfo, tags_err)
    end
    local delete_tags = r.params.delete_tags
    if delete_tags then
        tags = table.filter(tags, function(t)
            return table.find(delete_tags, t.tag_id) ~= nil
        end)
    end
    local alltags, alltags_err = Model:getAllTags()
    if not alltags then
        Log(kLogInfo, alltags_err)
    end
    local incoming_tags, it_err = Model:getIncomingTagsForImage(image_id)
    if not incoming_tags then
        Log(kLogInfo, it_err)
    end
    local sources, sources_err = Model:getSourcesForImage(image_id)
    if not sources then
        Log(kLogInfo, sources_err)
    end
    local delete_sources = r.params.delete_sources
    if delete_sources then
        sources = table.filter(sources, function(s)
            return table.find(delete_sources, s.source_id) ~= nil
        end)
    end
    local groups, group_errmsg = Model:getGroupsForImage(image_id)
    if not groups then
        Log(kLogInfo, group_errmsg)
    end
    for _, ig in ipairs(groups) do
        local siblings, sibling_errmsg =
            Model:getPrevNextImagesInGroupForImage(ig.ig_id, image_id)
        if not siblings then
            Log(kLogInfo, tostring(sibling_errmsg))
        end
        ig.siblings = siblings
    end
    local share_records, sr_err = Model:getShareRecordsForImage(image_id)
    if not share_records then
        Log(kLogInfo, sr_err)
    end
    local pending_artists = r.params.pending_artists
    if pending_artists then
        pending_artists = table.filter(pending_artists, WebUtility.not_emptystr)
    end
    local pending_tags = r.params.pending_tags
    if pending_tags then
        pending_tags = table.filter(pending_tags, WebUtility.not_emptystr)
    end
    local pending_sources = r.params.pending_sources
    if pending_sources then
        pending_sources = table.filter(pending_sources, WebUtility.not_emptystr)
    end
    local template_name = "image"
    if r.path:endswith("/edit") then
        template_name = "image_edit"
    end
    -- This is nil when the parameter is missing and false when it's there with
    -- no value.
    local show_full_size = r.params.fullsize ~= nil
    Fm.setTemplateVar("rv_fullsize", show_full_size)
    local params = {
        image = image,
        artists = artists,
        delete_artists = delete_artists,
        pending_artists = pending_artists,
        allartists = allartists,
        tags = tags,
        delete_tags = delete_tags,
        pending_tags = pending_tags,
        alltags = alltags,
        incoming_tags = incoming_tags,
        sources = sources,
        delete_sources = delete_sources,
        pending_sources = pending_sources,
        groups = groups,
        share_records = share_records,
        category = r.params.category or image.category,
        rating = r.params.rating or image.rating,
        fn = WebUtility.image_functions,
        DbUtilK = DbUtil.k,
    }
    render_share_widget(user_record.user_id, params)
    return Fm.serveContent(template_name, params)
end

local render_image = WebUtility.login_required(function(r, user_record)
    set_after_dialog_action(r)
    if r.params.share then
        if not r.params.share_option then
            return Fm.serveError(400, nil, "Must provide share_option")
        end
        for share_option_str in r.params.share_option:gmatch("(%d+):") do
            local share_option = tonumber(share_option_str)
            if not share_option then
                return Fm.serveError(400, nil, "Invalid share option")
            end
            local spl, spl_err = Model:getSharePingListById(share_option, true)
            if not spl then
                Log(
                    kLogInfo,
                    "Error while looking up share ping list: %s" % { spl_err }
                )
                return Fm.serveError(400, nil, "Invalid share option")
            end
            local share_id, sh_err = Model:createPendingShareRecordForImage(
                r.params.image_id,
                spl.name
            )
            if not share_id then
                Log(kLogInfo, tostring(sh_err))
                return Fm.serve500()
            end
            local redirect_url = EncodeUrl {
                path = "/image/%d/share" % { r.params.image_id },
                params = {
                    { "to", tostring(share_option) },
                    { "t", share_id },
                },
            }
            return Fm.serveRedirect(redirect_url, 302)
        end
        for tg_userid_str in r.params.share_option:gmatch("%((%d+)%)") do
            local tg_userid = tonumber(tg_userid_str)
            if not tg_userid then
                return Fm.serveError(400, nil, "Invalid Telegram user ID")
            end
            local tg_account, tg_err =
                Accounts:getTelegramAccountByUserIdAndTgUserId(
                    user_record.user_id,
                    tg_userid
                )
            if not tg_account then
                Log(
                    kLogInfo,
                    "Error while looking up Telegram account for user %s: %s"
                        % { user_record.user_id, tg_err }
                )
                return Fm.serveError(
                    400,
                    nil,
                    "That isn't your Telegram account"
                )
            end
            local share_id, sh_err = Model:createPendingShareRecordForImage(
                r.params.image_id,
                "@" .. tg_account.tg_username
            )
            if not share_id then
                Log(kLogInfo, tostring(sh_err))
                return Fm.serve500()
            end
            local redirect_url = EncodeUrl {
                path = "/image/%d/share" % { r.params.image_id },
                params = {
                    { "to_user", tostring(tg_userid) },
                    { "t", share_id },
                },
            }
            return Fm.serveRedirect(redirect_url, 302)
        end
    end
    return render_image_internal(r, user_record)
end)

local function delete_from_primary_and_return(
    r,
    user_record,
    list_key,
    index_key
)
    local to_delete = r.params[list_key] or {}
    to_delete[#to_delete + 1] = r.params[index_key]
    r.params[list_key] = to_delete
    r.params[index_key] = nil
    return render_image_internal(r, user_record)
end

local function delete_from_pending_and_return(
    r,
    user_record,
    list_key,
    index_key
)
    local pending = r.params[list_key]
    local index = tonumber(r.params[index_key])
    if not index then
        return Fm.serve400()
    end
    table.remove(pending, index)
    r.params[list_key] = pending
    r.params[index_key] = nil
    return render_image_internal(r, user_record)
end

local accept_edit_image = WebUtility.login_required(function(r, user_record)
    local redirect_url = "/image/" .. r.params.image_id
    if r.params.cancel then
        Log(kLogDebug, "Cancelling edit")
        return Fm.serveRedirect(redirect_url, 302)
    end
    -- Validation & Cleanup
    Log(kLogDebug, "Beginning validation & cleanup")
    local rating = tonumber(r.params.rating)
    if r.params.rating and not rating then
        return Fm.serveError(400, nil, "Bad rating")
    end
    r.params.rating = rating
    local categories = table.reduce(
        r.params.category or {},
        0,
        function(acc, next)
            return acc | (tonumber(next) or 0)
        end
    )
    if not categories and r.params.category then
        return Fm.serveError(400, nil, "Bad categories")
    end
    r.params.category = categories
    local pending_artists = r.params.pending_artists
    if pending_artists then
        r.params.pending_artists =
            table.filter(pending_artists, WebUtility.not_emptystr)
    end
    local pending_tags = r.params.pending_tags
    if pending_tags then
        r.params.pending_tags =
            table.filter(pending_tags, WebUtility.not_emptystr)
    end
    local pending_sources = r.params.pending_sources
    if pending_sources then
        r.params.pending_sources =
            table.filter(pending_sources, WebUtility.not_emptystr)
    end
    -- Submit handlers
    if r.params.delete_artist then
        return delete_from_primary_and_return(
            r,
            "delete_artists",
            "delete_artist"
        )
    end
    if r.params.delete_pending_artist then
        return delete_from_pending_and_return(
            r,
            "pending_artists",
            "delete_pending_artist"
        )
    end
    if r.params.delete_tag then
        return delete_from_primary_and_return(r, "delete_tags", "delete_tag")
    end
    if r.params.delete_pending_tag then
        return delete_from_pending_and_return(
            r,
            "pending_tags",
            "delete_pending_tag"
        )
    end
    if r.params.delete_source then
        return delete_from_primary_and_return(
            r,
            "delete_sources",
            "delete_source"
        )
    end
    if r.params.delete_pending_source then
        return delete_from_pending_and_return(
            r,
            "pending_sources",
            "delete_pending_source"
        )
    end
    if r.params.add_artist or r.params.add_tag or r.params.add_source then
        return render_image_internal(r)
    end
    -- Save handler
    if r.params.save then
        local image_id = r.params.image_id
        -- Image Metadata
        if not r.params.rating then
            return Fm.serveError(400, nil, "Missing rating")
        end
        local metadata_ok, metadata_err = Model:updateImageMetadata(
            image_id,
            r.params.category,
            r.params.rating
        )
        if not metadata_ok then
            Log(kLogInfo, metadata_err)
            return Fm.serve500()
        end
        -- Artists
        if r.params.delete_artists then
            local dartists_ok, dartists_err = Model:deleteArtistsForImageById(
                image_id,
                r.params.delete_artists
            )
            if not dartists_ok then
                Log(kLogInfo, tostring(dartists_err))
                return Fm.serve500()
            end
        end
        if r.params.pending_artists then
            local aartists_ok, aartists_err = Model:addArtistsForImageByName(
                image_id,
                r.params.pending_artists
            )
            if not aartists_ok then
                Log(kLogInfo, tostring(aartists_err))
                return Fm.serve500()
            end
        end
        -- Tags
        if r.params.delete_tags then
            local dtags_ok, dtags_err =
                Model:deleteTagsForImageById(image_id, r.params.delete_tags)
            if not dtags_ok then
                Log(kLogInfo, tostring(dtags_err))
                return Fm.serve500()
            end
        end
        if r.params.pending_tags then
            local atags_ok, atags_err =
                Model:addTagsForImageByName(image_id, r.params.pending_tags)
            if not atags_ok then
                Log(kLogInfo, tostring(atags_err))
                return Fm.serve500()
            end
        end
        -- Sources
        if r.params.delete_sources then
            local dsources_ok, dsources_err = Model:deleteSourcesForImageById(
                image_id,
                r.params.delete_sources
            )
            if not dsources_ok then
                Log(kLogInfo, tostring(dsources_err))
                return Fm.serve500()
            end
        end
        if r.params.pending_sources then
            local asources_ok, asources_err =
                Model:insertSourcesForImage(image_id, r.params.pending_sources)
            if not asources_ok then
                Log(kLogInfo, tostring(asources_err))
                return Fm.serve500()
            end
        end
        -- Create tag rules.
        local itids = r.params.itids
        if not itids or #itids < 1 then
            return Fm.serveRedirect("/image/" .. r.params.image_id, 302)
        end
        local params = table.map(itids, function(i)
            return { "itids[]", i }
        end)
        local tr_redirect_url = EncodeUrl {
            path = "/tag-rule/add-bulk",
            params = params,
        }
        r.session.retarget_to = "dialog"
        return Fm.serveRedirect(302, tr_redirect_url)
    end
    return render_image_internal(r, user_record)
end)

local lowerList = {
    ["at"] = true,
    ["but"] = true,
    ["by"] = true,
    ["down"] = true,
    ["for"] = true,
    ["from"] = true,
    ["in"] = true,
    ["into"] = true,
    ["like"] = true,
    ["near"] = true,
    ["of"] = true,
    ["off"] = true,
    ["on"] = true,
    ["onto"] = true,
    ["out"] = true,
    ["over"] = true,
    ["past"] = true,
    ["plus"] = true,
    ["to"] = true,
    ["up"] = true,
    ["upon"] = true,
    ["with"] = true,
    ["nor"] = true,
    ["yet"] = true,
    ["so"] = true,
    ["the"] = true,
}

local function titleCase(word, first, rest)
    word = word:lower()
    if lowerList[word] then
        return word
    else
        return first:upper() .. rest:lower()
    end
end

local function canonicalize_tag_name(incoming_name)
    local no_underscores = incoming_name:gsub("_", " ")
    return string.gsub(no_underscores, "((%a)([%w_']*))", titleCase)
end

local render_add_tag_rule_bulk = WebUtility.login_required(function(r, _)
    if r.params.add then
        local incoming_names = r.params.incoming_names
        local incoming_domains = r.params.incoming_domains
        local tag_names = r.params.tag_names
        if not incoming_names or not incoming_domains or not tag_names then
            return Fm.serveError(
                400,
                nil,
                "incoming_names[], incoming_domains[], and tag_names[] are all required parameters"
            )
        end
        if
            not #incoming_names == #incoming_domains
            and #incoming_domains == #tag_names
        then
            return Fm.serveError(
                400,
                nil,
                "All three list parameters must contain the same number of values"
            )
        end
        local SP = "bulk_add_tag_rule"
        Model:create_savepoint(SP)
        local tag_rule_ids = {}
        for i = 1, #incoming_names do
            local tr_ok, tr_err = Model:createTagRule(
                incoming_names[i],
                incoming_domains[i],
                tag_names[i]
            )
            if not tr_ok then
                Model:rollback(SP)
                Log(kLogInfo, tostring(tr_err))
                return Fm.serve500()
            end
            tag_rule_ids[#tag_rule_ids + 1] = tr_ok
        end
        Model:release_savepoint(SP)
        local changes, change_err =
            Model:applyIncomingTagsNowMatchedBySpecificTagRules(tag_rule_ids)
        assert((changes == nil) ~= (change_err == nil))
        if not changes then
            Log(kLogInfo, tostring(change_err))
            return Fm.serve500()
        end
        if #changes < 1 then
            return WebUtility.get_post_dialog_redirect(r, "/tag-rule")
        end
        local params = { changes = changes }
        WebUtility.add_htmx_param(r)
        WebUtility.add_form_path(r, params)
        return Fm.serveContent("tag_rule_changelist", params)
    elseif r.params.ok then
        return WebUtility.get_post_dialog_redirect(r, "/tag-rule")
    else
        r.session.after_dialog_action = r.headers["HX-Current-URL"]
            or r.headers.Referer
    end
    local itids = r.params.itids
    if not itids then
        return Fm.serveError(
            400,
            nil,
            "Must provide list of incoming tag IDs to create rules from"
        )
    end
    local incoming_tags, it_err = Model:getIncomingTagsByIds(itids)
    if not incoming_tags then
        Log(kLogInfo, tostring(it_err))
        return Fm.serve500()
    end
    local alltags, at_err = Model:getAllTags()
    if not alltags then
        Log(kLogInfo, at_err)
        return Fm.serve500()
    end
    local params = {
        incoming_tags = incoming_tags,
        alltags = alltags,
        canonicalize_tag_name = canonicalize_tag_name,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    if r.session.retarget_to then
        r.headers["HX-Retarget"] = r.session.retarget_to
        r.headers["HX-Replace-Url"] = "false"
        r.session.retarget_to = nil
    end
    return Fm.serveContent("tag_rule_bulk_add", params)
end)

local function pagination_data(
    current_page,
    item_count,
    max_items_per_page,
    items_this_page
)
    local pages = {
        current = current_page,
    }
    if items_this_page > 0 then
        pages.total = math.ceil(item_count / max_items_per_page)
        pages.first_row = ((pages.current - 1) * max_items_per_page) + 1
        pages.last_row = pages.first_row + items_this_page - 1
        pages.item_count = item_count
        if pages.current ~= pages.total then
            pages.after = {
                num = pages.current + 1,
            }
        end
        if pages.current ~= 1 then
            pages.before = {
                num = pages.current - 1,
            }
        end
    end
    return pages
end

local render_queue = WebUtility.login_required(function(r, _)
    local per_page = 50
    local queue_count, count_errmsg = Model:getQueueEntryCount()
    if not queue_count then
        Log(kLogDebug, tostring(count_errmsg))
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local queue_records, queue_errmsg =
        Model:getPaginatedQueueEntries(cur_page, per_page)
    if not queue_records then
        Log(kLogInfo, tostring(queue_errmsg))
        return Fm.serve500()
    end
    local pages =
        pagination_data(cur_page, queue_count, per_page, #queue_records)
    local error = r.session.error
    r.session.error = nil
    set_after_dialog_action(r)
    return Fm.serveContent("queue", {
        error = error,
        queue_records = queue_records,
        pages = pages,
    })
end)

local accept_queue = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/queue")
    if r.params.cleanup then
        local ok, err = Model:cleanUpQueue()
        if not ok then
            r.session.error = err
        end
    else
        if not r.params.qids then
            return Fm.serve400("Must select at least one queue entry.")
        end
        if r.params.delete then
            local ok, err = Model:deleteFromQueue(r.params.qids)
            if not ok then
                r.session.error = err
            end
        elseif r.params.tryagain then
            local ok, err = Model:resetQueueItemStatus(r.params.qids)
            if not ok then
                r.session.error = err
            end
        elseif r.params.error then
            local ok, err = Model:setQueueItemsStatusAndDescription(
                r.params.qids,
                1,
                "Manually forced error"
            )
            if not ok then
                r.session.error = err
            end
        else
            return Fm.serve400()
        end
    end
    return redirect
end)

local render_about = WebUtility.login_optional(function(r, _)
    set_after_dialog_action(r)
    return Fm.serveContent("about", {})
end)

local render_tos = WebUtility.login_optional(function(r, _)
    set_after_dialog_action(r)
    return Fm.serveContent("tos", {})
end)

local render_queue_help = WebUtility.login_required(function(r, _)
    local queue_entry, _ = Model:getQueueEntryById(r.params.qid)
    if not queue_entry then
        return Fm.serve404()
    end
    local help_ask_str = queue_entry.help_ask
    if not help_ask_str then
        help_ask_str = "{}"
    end
    local help_ask, json_err = DecodeJson(help_ask_str)
    if json_err then
        Log(
            kLogWarn,
            "JSON decode error while decoding qid %d: %s"
                % { queue_entry.qid, json_err }
        )
        return Fm.serve500()
    end
    local params = {
        queue_entry = queue_entry,
        help_ask = help_ask,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("queue_help", params)
end)

local function queue_help_dupes(r)
    if
        r.params.save and r.params.discard
        or (not r.params.save and not r.params.discard)
    then
        return nil, Fm.serve400()
    end
    local result = {}
    if r.params.save then
        result = { d = "save" }
    else
        result = { d = "discard" }
    end
    return result
end

local function queue_help_heuristic(r, dr_data)
    if
        r.params.cancel and r.params.archive_selected
        or (not r.params.cancel and not r.params.archive_selected)
    then
        return Fm.serve400()
    end
    if r.params.archive_selected then
        local images_to_save = r.params.save_images
        if not images_to_save then
            return nil, Fm.serve400()
        end
        local to_archive = {}
        for i = 1, #images_to_save do
            local image_indexes = images_to_save[i]
            local _, _, outer, inner = image_indexes:find("(%d+),(%d+)")
            outer = tonumber(outer)
            inner = tonumber(inner)
            if not outer or not inner then
                return nil, Fm.serve400()
            end
            to_archive[#to_archive + 1] = dr_data.h[outer][inner]
        end
        return { h = to_archive }
    end
end

local function queue_help_new(r, help_ask_data)
    if r.params.discard then
        return { discard_all = true }
    elseif r.params.ok then
        local subtasks = {}
        for source_idx = 1, #help_ask_data.decoded do
            local source = help_ask_data.decoded[source_idx]
            for image_idx = 1, #source do
                local image = source[image_idx]
                local key = "s_%d_i_%d" % { source_idx, image_idx }
                local decision = r.params[key]
                if not decision then
                    return nil, Fm.serve400()
                end
                if decision == "Discard" then
                    Log(kLogDebug, "Doing nothing for discard")
                elseif decision == "Archive" then
                    ---@cast image PipelineSubtaskArchive
                    image.archive = true
                    subtasks[#subtasks + 1] = image
                elseif decision:startswith("Merge with") then
                    local _, _, merge_id_str = decision:find("(%d+)")
                    local merge_id = tonumber(merge_id_str)
                    if not merge_id then
                        return Fm.serve400()
                    end
                    ---@cast image PipelineSubtaskMerge
                    image.merge = merge_id
                    subtasks[#subtasks + 1] = image
                else
                    return nil, Fm.serve400()
                end
            end
        end
        return {
            type = PipelineTaskType.Archive,
            qid = help_ask_data.qid,
            sources = help_ask_data.sources,
            subtasks = subtasks,
        }
    end
end

local accept_queue_help = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/home")
    local qid = r.params.qid
    if not qid then
        return Fm.serve400()
    end
    if r.params.cancel then
        return redirect
    end
    local queue_record, queue_err = Model:getQueueEntryById(qid)
    if not queue_record then
        Log(kLogInfo, "Database error: %s" % { queue_err })
        return Fm.serve500()
    end
    local dr_data = DecodeJson(queue_record.help_ask)
    if not dr_data then
        return Fm.serve500()
    end
    local result, r_err = queue_help_new(r, dr_data)
    if not result then
        return r_err
    end
    local ok, err = Model:setQueueItemHelpAnswer(qid, result)
    if not ok or err then
        Log(kLogInfo, "Database error: %s" % { err })
        return Fm.serve500()
    end
    return redirect
end)

local render_images = WebUtility.login_required(function(r, _)
    local per_page = 50
    local image_count, count_errmsg = Model:getImageEntryCount()
    if not image_count then
        Log(kLogDebug, tostring(count_errmsg))
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local image_records, image_errmsg =
        Model:getPaginatedImageEntries(cur_page, per_page)
    if not image_records then
        Log(kLogInfo, image_errmsg)
        return Fm.serve500()
    end
    local pages =
        pagination_data(cur_page, image_count, per_page, #image_records)
    local error = r.session.error
    r.session.error = nil
    set_after_dialog_action(r)
    return Fm.serveContent("images", {
        error = error,
        image_records = image_records,
        pages = pages,
        fn = WebUtility.image_functions,
    })
end)

local accept_images = WebUtility.login_required(function(r, _)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/image")
    if r.params.delete then
        local ok, errmsg = Model:deleteImages(r.params.image_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return Fm.serveRedirect(r.headers.Referer, 302)
    elseif r.params.new_group then
        local image_ids = r.params.image_ids
        image_ids = table.map(image_ids, tonumber)
        table.sort(image_ids)
        if #image_ids < 1 then
            r.session.error =
                "You must select at least one record to add to the group!"
            return redirect
        end
        local ig_id, g_err =
            Model:createImageGroupWithImages("Untitled group", image_ids)
        if not ig_id then
            Log(kLogInfo, tostring(g_err))
            return Fm.serve500()
        end
        return Fm.serveRedirect("/image-group/%d/edit" % { ig_id }, 302)
    end
    return redirect
end)

---Render a list view for non-image items.
---@param r any The request context.
---@param model Model A Model object to use for DB queries.
---@param settings {kind: string, title: string, singular: string, plural: string, add_link: string|nil} Settings which control how the page is rendered.  Each supported kind has a slightly different layout.  Title is the page title. Singular and Plural are the singular and plural forms of the word for whatever's being listed. Singular should be title cased, plural should be lowercase.  URL path to the "add" page for the kind of item being listed. May be omitted if the add page doesn't exist (e.g. for record groups).
---@param per_page integer The number of records to show per page.
---@param count_fn function Function on the model object which counts the total number of results. This should match `get*CountForSearch`.
---@param search_fn function Function on the model object which actually does
---the search. This should match `searchPaginated*`.
---@return any # Rendered page output.
local function render_generic_list(
    r,
    model,
    settings,
    per_page,
    count_fn,
    search_fn
)
    local query = r.params.search ~= "" and r.params.search or nil
    if query then
        query = query:trim()
    end
    local count, count_errmsg = count_fn(model, query)
    if not count then
        Log(kLogDebug, tostring(count_errmsg))
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    -- When someone adds a search query while they're far into the list, the
    -- page parameter from where they *were* may be on a page that doesn't exist
    -- for where they're *going*.  Reset them to the first page, which probably
    -- matches their intent.
    if query and ((cur_page * per_page) - count) > per_page then
        cur_page = 1
    end
    local records, rec_errmsg = search_fn(model, cur_page, per_page, query)
    if not records then
        Log(kLogInfo, rec_errmsg)
        return Fm.serve500()
    end
    local pages = pagination_data(cur_page, count, per_page, #records)
    local error = r.session.error
    r.session.error = nil
    set_after_dialog_action(r)
    return Fm.serveContent("generic_list", {
        error = error,
        settings = settings,
        records = records,
        pages = pages,
        page = cur_page,
        search = query,
    })
end

local render_artists = WebUtility.login_required(function(r, _)
    local settings = {
        kind = "artist",
        title = "Artists",
        singular = "Artist",
        plural = "artists",
        add_link = "/artist/add",
    }
    return render_generic_list(
        r,
        Model,
        settings,
        50,
        Model.getArtistCountForSearch,
        Model.searchPaginatedArtists
    )
end)

local accept_artists = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/artist")
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteArtists(r.params.artist_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    elseif r.params.merge == "Merge" then
        local artist_ids = r.params.artist_ids
        artist_ids = table.map(artist_ids, tonumber)
        table.sort(artist_ids)
        if #artist_ids < 2 then
            r.session.error = "You must select at least two artists to merge!"
            return redirect
        end
        -- Yes, this is slower because it moves everything down, but it preserves
        -- earlier artist IDs, which makes me happier.
        local merge_into_id = table.remove(artist_ids, 1)
        local ok, errmsg = Model:mergeArtists(merge_into_id, artist_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    end
    return redirect
end)

local render_artist = WebUtility.login_required(function(r, _)
    local artist_id = r.params.artist_id
    if not artist_id then
        return Fm.serve400()
    end
    local artist, errmsg1 = Model:getArtistById(artist_id)
    if not artist then
        Log(kLogInfo, tostring(errmsg1))
        return Fm.serve404()
    end
    local handles, errmsg2 = Model:getHandlesForArtist(artist_id)
    if not handles then
        Log(kLogInfo, errmsg2)
        return Fm.serve500()
    end
    local images, images_err = Model:getRecentImagesForArtist(artist_id, 20)
    if not images then
        Log(kLogInfo, images_err)
        return Fm.serve500()
    end
    set_after_dialog_action(r)
    return Fm.serveContent("artist", {
        artist = artist,
        handles = handles,
        images = images,
        fn = WebUtility.image_functions,
    })
end)

local render_add_artist = WebUtility.login_required(function(r)
    local params = {}
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("artist_add", params)
end)

local function render_edit_artist_internal(r)
    local artist_id = r.params.artist_id
    if not artist_id then
        return Fm.serve400()
    end
    local artist, errmsg1 = Model:getArtistById(artist_id)
    if not artist then
        Log(kLogInfo, tostring(errmsg1))
        return Fm.serve404()
    end
    local handles, errmsg2 = Model:getHandlesForArtist(artist_id)
    if not handles then
        Log(kLogInfo, errmsg2)
    end
    local delete_handles = r.params.delete_handles
    if delete_handles then
        handles = table.filter(handles, function(h)
            return table.find(delete_handles, tostring(h.handle_id)) == nil
        end)
    end
    local pending_usernames = r.params.pending_usernames
    if pending_usernames then
        pending_usernames =
            table.filter(pending_usernames, WebUtility.not_emptystr)
    end
    local pending_profile_urls = r.params.pending_profile_urls
    if pending_profile_urls then
        pending_profile_urls =
            table.filter(pending_profile_urls, WebUtility.not_emptystr)
    end
    local params = {
        artist = artist,
        handles = handles,
        pending_usernames = pending_usernames,
        delete_handles = delete_handles,
        pending_profile_urls = pending_profile_urls,
        name = r.params.name or artist.name,
        manually_confirmed = r.params.confirmed or artist.manually_confirmed,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("artist_edit", params)
end

local render_edit_artist =
    WebUtility.login_required(render_edit_artist_internal)

local accept_edit_artist = WebUtility.login_required(function(r)
    local redirect =
        WebUtility.get_post_dialog_redirect(r, "/artist/" .. r.params.artist_id)
    if r.params.cancel then
        return redirect
    end
    local pending_usernames = r.params.pending_usernames
    local pending_profile_urls = r.params.pending_profile_urls
    local pending_handles = {}
    if pending_usernames and pending_profile_urls then
        if #pending_usernames ~= #pending_profile_urls then
            return Fm.serveError(
                400,
                nil,
                "Number of usernames and profile URLs must match!"
            )
        end
        for i = 1, #pending_usernames do
            local pending_username = pending_usernames[i]
            local pending_profile_url = pending_profile_urls[i]
            if (#pending_username > 0) ~= (#pending_profile_url > 0) then
                return Fm.serveError(
                    400,
                    nil,
                    "Both the username and profile URL are mandatory."
                )
            end
            if (#pending_username ~= 0) and (#pending_profile_url ~= 0) then
                local domain = ParseUrl(pending_profile_url).host
                if not domain then
                    return Fm.serveError(400, nil, "Invalid profile URL.")
                end
                pending_handles[#pending_handles + 1] = {
                    pending_username,
                    domain,
                    pending_profile_url,
                }
            end
        end
        r.params.pending_usernames =
            table.filter(pending_usernames, WebUtility.not_emptystr)
        r.params.pending_profile_urls =
            table.filter(pending_profile_urls, WebUtility.not_emptystr)
    end
    if r.params.delete_handle then
        local to_delete = r.params.delete_handles or {}
        to_delete[#to_delete + 1] = r.params.delete_handle
        r.params.delete_handles = to_delete
        r.params.delete_handle = nil
        return render_edit_artist_internal(r)
    end
    if r.params.delete_pending_handle then
        local index = tonumber(r.params.delete_pending_handle)
        if not index then
            return Fm.serve400()
        end
        table.remove(pending_usernames, index)
        table.remove(pending_profile_urls, index)
        r.params.pending_usernames = pending_usernames
        r.params.pending_profile_urls = pending_profile_urls
        r.params.delete_pending_handle = nil
        return render_edit_artist_internal(r)
    end
    if r.params.add_handle then
        return render_edit_artist_internal(r)
    end
    if r.params.update then
        local artist_id = r.params.artist_id
        if not r.params.name then
            return Fm.serveError(400, nil, "Missing artist name")
        end
        local verified = r.params.confirmed ~= nil
        local artist_ok, artist_err =
            Model:updateArtist(artist_id, r.params.name, verified)
        if not artist_ok then
            Log(kLogInfo, tostring(artist_err))
            return Fm.serveError(
                400,
                nil,
                "Unable to rename artist: " .. artist_err
            )
        end
        if r.params.delete_handles then
            local delete_ok, delete_err = Model:deleteHandlesForArtistById(
                artist_id,
                r.params.delete_handles
            )
            if not delete_ok then
                Log(kLogInfo, tostring(delete_err))
                return Fm.serve500()
            end
        end
        if #pending_handles > 0 then
            local SP = "update_artist_handles"
            Model:create_savepoint(SP)
            for i = 1, #pending_handles do
                local add_ok, add_err = Model:createHandleForArtist(
                    artist_id,
                    table.unpack(pending_handles[i])
                )
                if not add_ok then
                    Log(kLogInfo, tostring(add_err))
                    Model:rollback(SP)
                    return Fm.serve500()
                end
            end
            Model:release_savepoint(SP)
        end
        return redirect
    end
end)

local accept_add_artist = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/artist")
    if r.params.cancel then
        return redirect
    end
    local usernames = r.params.usernames
    local profile_urls = r.params.profile_urls
    if not r.params.name then
        return Fm.serveError(400, nil, "Artist name is required")
    end
    if not usernames then
        return Fm.serveError(400, nil, "At least one username is required")
    end
    if not profile_urls then
        return Fm.serveError(400, nil, "At least one profile URL is required")
    end
    if #usernames ~= #profile_urls then
        return Fm.serveError(
            400,
            nil,
            "The number of usernames and profile URLs must match"
        )
    end
    local handles = {}
    for i = 1, #usernames do
        local profile_url = profile_urls[i]
        local parts = ParseUrl(profile_url)
        handles[#handles + 1] = {
            profile_url = profile_url,
            domain = parts.host,
            handle = usernames[i],
        }
    end
    local artist_id, err =
        Model:createArtistWithHandles(r.params.name, 1, handles)
    if not artist_id then
        Log(kLogInfo, tostring(err))
        return Fm.serve500(err)
    end
    return Fm.serveRedirect("/artist/" .. artist_id, 302)
end)

local render_image_groups = WebUtility.login_required(function(r, _)
    local settings = {
        kind = "ig",
        title = "Image Groups",
        singular = "Group",
        plural = "groups",
    }
    return render_generic_list(
        r,
        Model,
        settings,
        50,
        Model.getImageGroupCountForSearch,
        Model.searchPaginatedImageGroups
    )
end)

local accept_image_groups = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/image-group")
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteImageGroups(r.params.ig_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    elseif r.params.merge == "Merge" then
        local ig_ids = r.params.ig_ids
        ig_ids = table.map(ig_ids, tonumber)
        table.sort(ig_ids)
        if #ig_ids < 2 then
            r.session.error = "You must select at least two groups to merge!"
            return redirect
        end
        local merge_into_id = table.remove(ig_ids, 1)
        local ok, errmsg = Model:mergeImageGroups(merge_into_id, ig_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    end
    return redirect
end)

local render_image_group = WebUtility.login_required(function(r, user_record)
    if not r.params.ig_id then
        return Fm.serve400()
    end
    if r.params.share then
        if not r.params.share_option then
            return Fm.serveError(400, nil, "Must provide share_option")
        end
        for share_option_str in r.params.share_option:gmatch("(%d+):") do
            local share_option = tonumber(share_option_str)
            if not share_option then
                return Fm.serveError(400, nil, "Invalid share option")
            end
            local spl, spl_err = Model:getSharePingListById(share_option, true)
            if not spl then
                Log(
                    kLogInfo,
                    "Error while looking up share ping list: %s" % { spl_err }
                )
                return Fm.serveError(400, nil, "Invalid share option")
            end
            local share_id, sh_err =
                Model:createPendingShareRecordForImageGroup(
                    r.params.ig_id,
                    spl.name
                )
            if not share_id then
                Log(kLogInfo, tostring(sh_err))
                return Fm.serve500()
            end
            local redirect_url = EncodeUrl {
                path = "/image-group/%d/share" % { r.params.ig_id },
                params = {
                    { "to", tostring(share_option) },
                    { "t", share_id },
                },
            }
            return Fm.serveRedirect(redirect_url, 302)
        end
        for tg_userid_str in r.params.share_option:gmatch("%((%d+)%)") do
            local tg_userid = tonumber(tg_userid_str)
            if not tg_userid then
                return Fm.serveError(400, nil, "Invalid Telegram user ID")
            end
            local tg_account, tg_err =
                Accounts:getTelegramAccountByUserIdAndTgUserId(
                    user_record.user_id,
                    tg_userid
                )
            if not tg_account then
                Log(
                    kLogInfo,
                    "Error while looking up Telegram account for user %s: %s"
                        % { user_record.user_id, tg_err }
                )
                return Fm.serveError(
                    400,
                    nil,
                    "That isn't your Telegram account"
                )
            end
            local share_id, sh_err =
                Model:createPendingShareRecordForImageGroup(
                    r.params.ig_id,
                    "@" .. tg_account.tg_username
                )
            if not share_id then
                Log(kLogInfo, tostring(sh_err))
                return Fm.serve500()
            end
            local redirect_url = EncodeUrl {
                path = "/image-group/%d/share" % { r.params.ig_id },
                params = {
                    { "to_user", tostring(tg_userid) },
                    { "t", share_id },
                },
            }
            return Fm.serveRedirect(redirect_url, 302)
        end
    end
    local ig, ig_errmsg = Model:getImageGroupById(r.params.ig_id)
    if not ig then
        Log(kLogInfo, tostring(ig_errmsg))
        return Fm.serve404()
    end
    local images, image_errmsg = Model:getImagesForGroup(r.params.ig_id)
    if not images then
        Log(kLogInfo, image_errmsg)
    end
    local share_records, sr_err =
        Model:getShareRecordsForImageGroup(r.params.ig_id)
    if not share_records then
        Log(kLogInfo, sr_err)
    end
    set_after_dialog_action(r)
    local params = {
        ig = ig,
        images = images,
        share_records = share_records,
        fn = WebUtility.image_functions,
    }
    render_share_widget(user_record.user_id, params)
    return Fm.serveContent("image_group", params)
end)

local render_edit_image_group = WebUtility.login_required(function(r, _)
    if not r.params.ig_id then
        return Fm.serve400()
    end
    local ig, ig_errmsg = Model:getImageGroupById(r.params.ig_id)
    if not ig then
        Log(kLogInfo, tostring(ig_errmsg))
        return Fm.serve404()
    end
    local images, image_errmsg = Model:getImagesForGroup(r.params.ig_id)
    if not images then
        Log(kLogInfo, image_errmsg)
    end
    local params = {
        ig = ig,
        images = images,
        fn = WebUtility.image_functions,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("image_group_edit", params)
end)

local function normalize_order_values(image_ids, new_orders)
    local merged = table.zip(image_ids, new_orders)
    table.sort(merged, function(a, b)
        return a[2] < b[2]
    end)
    if not merged then
        error("wtf")
    end
    local reordered = table.mapIdx(merged, function(item, idx)
        item[2] = idx
        return item
    end)
    return reordered
end

local accept_edit_image_group = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/image-group")
    if r.params.cancel then
        return redirect
    end
    local ig_id = r.params.ig_id
    local image_ids = r.params.image_ids
    local new_orders = r.params.new_orders
    local new_name = r.params.name
    if not ig_id or not image_ids or not new_orders or not new_name then
        return Fm.serve400()
    end
    if #image_ids ~= #new_orders then
        return Fm.serveError(
            400,
            nil,
            "Must have the same number of image_ids as new_orders"
        )
    end
    local new_orders_num, new_orders_err = table.maperr(
        new_orders,
        function(item)
            local number = tonumber(item)
            if not number then
                return nil, '"%s" is not a number'
            end
            return number
        end
    )
    if not new_orders_num then
        return Fm.serveError(400, nil, new_orders_err)
    end
    local normalized_images_orders =
        normalize_order_values(image_ids, new_orders_num)
    local SP = "reorder_images_in_group"
    Model:create_savepoint(SP)
    local existing_images, ei_err = Model:getImagesForGroup(ig_id)
    if not existing_images then
        Model:rollback(SP)
        Log(kLogInfo, ei_err)
        return Fm.serve500()
    end
    Log(
        kLogVerbose,
        "existing images: " .. tostring(EncodeJson(existing_images))
    )
    local existing_image_ids = {}
    for i = 1, #existing_images do
        local ex_id = existing_images[i].image_id
        Log(kLogDebug, "wtf: " .. ex_id)
        existing_image_ids[ex_id] = true
    end
    Log(
        kLogVerbose,
        "existing image IDs: " .. tostring(EncodeJson(existing_image_ids))
    )
    local rename_ok, rename_err = Model:renameImageGroup(ig_id, new_name)
    if not rename_ok then
        Model:rollback(SP)
        Log(kLogInfo, rename_err)
        return Fm.serve500()
    end
    local untouched_image_ids_set = existing_image_ids
    for i = 1, #normalized_images_orders do
        local image_id, new_order = table.unpack(normalized_images_orders[i])
        local reorder_ok, reorder_err =
            Model:setOrderForImageInGroup(ig_id, image_id, new_order)
        if not reorder_ok then
            Model:rollback(SP)
            Log(kLogInfo, reorder_err)
            return Fm.serve500()
        end
        untouched_image_ids_set[tonumber(image_id)] = nil
    end
    Log(
        kLogVerbose,
        "untouched_image_ids_set: "
            .. tostring(EncodeJson(untouched_image_ids_set))
    )
    local to_delete_ids = table.keys(untouched_image_ids_set)
    Log(kLogVerbose, "to_delete_ids: " .. tostring(EncodeJson(to_delete_ids)))
    if #to_delete_ids > 0 then
        local del_ok, del_err =
            Model:removeImagesFromGroupById(ig_id, to_delete_ids)
        if not del_ok then
            Model:rollback(SP)
            Log(kLogInfo, tostring(del_err))
            return Fm.serve500()
        end
    end
    Model:release_savepoint(SP)
    return redirect
end)

local render_telegram_link = WebUtility.login_required(function(r, _)
    if not r.params.request_id then
        return Fm.serve404()
    end
    local tg, tg_errmsg =
        Accounts:getTelegramLinkRequestById(r.params.request_id)
    if not tg then
        Log(kLogInfo, tg_errmsg)
        return Fm.serve404()
    end
    local now = unix.clock_gettime()
    if not now then
        return Fm.serve500()
    end
    if tg.created_at - now > (30 * 60) then
        return Fm.serve404()
    end
    local params = {
        tg = tg,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("link_telegram", params)
end)

local accept_telegram_link = WebUtility.login_required(function(r, user_record)
    if not r.params.request_id then
        return Fm.serve404()
    end
    local tg, tg_errmsg =
        Accounts:getTelegramLinkRequestById(r.params.request_id)
    if not tg then
        Log(kLogInfo, tg_errmsg)
        return Fm.serve404()
    end
    local now = unix.clock_gettime()
    if not now then
        return Fm.serve500()
    end
    if tg.created_at - now > (30 * 60) then
        return Fm.serve404()
    end
    if r.params.link == "Link" then
        local link_ok, link_err =
            Accounts:setTelegramUserIDForUserAndDeleteLinkRequest(
                user_record.user_id,
                tg.tg_userid,
                tg.username,
                r.params.request_id
            )
        if not link_ok then
            Log(kLogInfo, link_err)
            return Fm.serve500()
        end
        Bot.notify_account_linked(tg.tg_userid, user_record.username)
    else
        local delete_ok, delete_err =
            Accounts:deleteTelegramLinkRequest(r.params.request_id)
        if not delete_ok then
            Log(kLogInfo, delete_err)
            return Fm.serve500()
        end
    end
    return Fm.serveRedirect("/home", 302)
end)

local render_tags = WebUtility.login_required(function(r, _)
    local settings = {
        kind = "tag",
        title = "Tags",
        singular = "Tag",
        plural = "tags",
        add_link = "/tag/add",
    }
    return render_generic_list(
        r,
        Model,
        settings,
        50,
        Model.getTagCountForSearch,
        Model.searchPaginatedTags
    )
end)

local accept_tags = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/tag")
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteTags(r.params.tag_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    elseif r.params.merge == "Merge" then
        local tag_ids = r.params.tag_ids
        tag_ids = table.map(tag_ids, tonumber)
        table.sort(tag_ids)
        if #tag_ids < 2 then
            r.session.error = "You must select at least two tags to merge!"
            return redirect
        end
        -- Yes, this is slower because it moves everything down, but it preserves
        -- earlier tag IDs, which makes me happier.
        local merge_into_id = table.remove(tag_ids, 1)
        local ok, errmsg = Model:mergeTags(merge_into_id, tag_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    end
    return redirect
end)

local render_tag = WebUtility.login_required(function(r, _)
    local tag_id = r.params.tag_id
    if not tag_id then
        return Fm.serve400()
    end
    local tag_record, tr_err = Model:getTagById(tag_id)
    if not tag_record then
        Log(kLogInfo, tostring(tr_err))
        return Fm.serve404()
    end
    local images, images_err = Model:getRecentImagesForTag(tag_id, 20)
    if not images then
        Log(kLogInfo, images_err)
        return Fm.serve500()
    end
    set_after_dialog_action(r)
    return Fm.serveContent("tag", {
        tag = tag_record,
        images = images,
        fn = WebUtility.image_functions,
    })
end)

local render_edit_tag = WebUtility.login_required(function(r, _)
    if not r.params.tag_id then
        return Fm.serve400()
    end
    local tag, tag_errmsg = Model:getTagById(r.params.tag_id)
    if not tag then
        Log(kLogInfo, tostring(tag_errmsg))
        return Fm.serve404()
    end
    local params = {
        tag = tag,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("tag_edit", params)
end)

local accept_edit_tag = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/tag")
    if r.params.cancel then
        return redirect
    end
    local tag_id = r.params.tag_id
    local new_name = r.params.name
    local new_desc = r.params.description
    if not tag_id or not new_name or not new_desc then
        return Fm.serve400()
    end
    if r.params.update then
        local update_ok, update_err =
            Model:updateTag(tag_id, new_name, new_desc)
        if not update_ok then
            Log(kLogInfo, update_err)
            return Fm.serve500()
        end
    end
    return redirect
end)

local render_add_tag = WebUtility.login_required(function(r)
    local params = {}
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("tag_add", params)
end)

local accept_add_tag = WebUtility.login_required(function(r)
    if r.params.cancel then
        return Fm.serveRedirect("/tag", 302)
    end
    if not r.params.name then
        return Fm.serveError(400, nil, "Tag name is required")
    end
    if not r.params.description then
        return Fm.serveError(400, nil, "Tag description is required")
    end
    local tag_id, err = Model:createTag(r.params.name, r.params.description)
    if not tag_id then
        Log(kLogInfo, tostring(err))
        return Fm.serve500(err)
    end
    return Fm.serveRedirect("/tag/" .. tag_id, 302)
end)

local render_account = WebUtility.login_required(function(r, user_record)
    local image_stats, stats_err = Model:getImageStats()
    if not image_stats then
        Log(kLogDebug, stats_err)
        return Fm.serve500()
    end
    local artist_count, as_err = Model:getArtistCount()
    if not artist_count then
        Log(kLogDebug, tostring(as_err))
        artist_count = 0
    end
    local tag_count, ts_err = Model:getTagCount()
    if not tag_count then
        Log(kLogDebug, tostring(ts_err))
        tag_count = 0
    end
    local data_size, ds_err = Model:getDiskSpaceUsage()
    if not data_size then
        Log(kLogDebug, tostring(ds_err))
        data_size = 0
    end
    local telegram_accounts, tg_err =
        Accounts:getAllTelegramAccountsForUser(user_record.user_id)
    if not telegram_accounts then
        Log(kLogDebug, tostring(tg_err))
        return Fm.serve500()
    end
    local sessions, sess_err =
        Accounts:getAllSessionsForUser(user_record.user_id)
    if not sessions then
        Log(kLogDebug, sess_err)
        return Fm.serve50()
    end
    local invites, invites_err =
        Accounts:getAllInvitesCreatedByUser(user_record.user_id)
    if not invites then
        Log(kLogDebug, invites_err)
        return Fm.serve500()
    end
    local share_ping_lists, spl_err = Model:getAllSharePingLists()
    if not share_ping_lists then
        Log(kLogDebug, tostring(spl_err))
        return Fm.serve500()
    end
    local pw_change_error = r.session.pw_change_error
    r.session.pw_change_error = nil
    set_after_dialog_action(r)
    return Fm.serveContent("account", {
        image_stats = image_stats,
        artist_count = artist_count,
        tag_count = tag_count,
        data_size = data_size,
        telegram_accounts = telegram_accounts,
        share_ping_lists = share_ping_lists,
        sessions = sessions,
        invites = invites,
        pw_change_error = pw_change_error,
    })
end)

local accept_end_sessions = WebUtility.login_required(function(r, user_record)
    if r.params.end_all_sessions then
        local ok, err = Accounts:deleteAllSessionsForUser(user_record.user_id)
        if not ok then
            Log(kLogInfo, "Unable to delete sessions: %s" % { err })
            return Fm.serve500()
        end
        return Fm.serveRedirect(302, "/account")
    end
    return Fm.serve400()
end)

local accept_change_password = WebUtility.login_required(
    function(r, user_record)
        if r.params.change_password then
            if r.params.password ~= r.params.password_confirm then
                r.session.pw_change_error = "New passwords do not match."
                return Fm.serveRedirect("/account#change-password", 302)
            end
            local result, verify_err =
                argon2.verify(user_record.password, r.params.current_password)
            if not result then
                r.session.pw_change_error = "Invalid password"
                Log(
                    kLogVerbose,
                    "Denying attempted password change for %s due to error from argon2: %s"
                        % { r.params.username, verify_err }
                )
                return Fm.serveRedirect("/account#change-password", 302)
            end
            local breached, b_err = check_password_breach(r.params.password)
            if b_err then
                return Fm.serve500()
            end
            if breached then
                r.session.pw_change_error =
                    "That password has previously been found in a password breach. Please choose a different one."
                return Fm.serveRedirect("/account#change-password", 302)
            end
            local pw_hash = hash_password(r.params.password)
            local ok, err =
                Accounts:updatePasswordForuser(user_record.user_id, pw_hash)
            if not ok then
                Log(
                    kLogInfo,
                    "error updating password hash for user: %s" % { err }
                )
                return Fm.serve500()
            end
            r.session.toast = { msg = "Password updated!" }
            return Fm.serveRedirect("/account", 302)
        end
        return Fm.serve400()
    end
)

local render_tag_rules = WebUtility.login_required(function(r, _)
    local per_page = 50
    local tag_rule_count, trc_errmsg = Model:getTagRuleCount()
    if not tag_rule_count then
        Log(kLogDebug, tostring(trc_errmsg))
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local tag_rule_records, tag_rule_errmsg =
        Model:getPaginatedTagRules(cur_page, per_page)
    if not tag_rule_records then
        Log(kLogInfo, tostring(tag_rule_errmsg))
        return Fm.serve500()
    end
    local pages =
        pagination_data(cur_page, tag_rule_count, per_page, #tag_rule_records)
    local error = r.session.error
    r.session.error = nil
    if r.session.retarget_to then
        r.headers["HX-Retarget"] = r.session.retarget_to
        r.session.retarget_to = nil
    end
    set_after_dialog_action(r)
    return Fm.serveContent("tag_rules", {
        error = error,
        tag_rule_records = tag_rule_records,
        pages = pages,
    })
end)

local accept_tag_rules = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/tag-rule")
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteTagRules(r.params.tag_rule_ids)
        if not ok then
            Log(kLogInfo, tostring(errmsg))
            return Fm.serve500()
        end
        return redirect
    end
    return redirect
end)

local render_tag_rule = WebUtility.login_required(function(r, _)
    local tag_rule_id = r.params.tag_rule_id
    if not tag_rule_id then
        return Fm.serve400()
    end
    local tag_rule_record, trr_err = Model:getTagRuleById(tag_rule_id)
    if not tag_rule_record then
        Log(kLogInfo, trr_err)
        return Fm.serve404()
    end
    set_after_dialog_action(r)
    return Fm.serveContent("tag_rule", {
        tag_rule = tag_rule_record,
    })
end)

local render_edit_tag_rule = WebUtility.login_required(function(r, _)
    if not r.params.tag_rule_id then
        return Fm.serve400()
    end
    local tag_rule, tag_rule_errmsg = Model:getTagRuleById(r.params.tag_rule_id)
    if not tag_rule then
        Log(kLogInfo, tag_rule_errmsg)
        return Fm.serve404()
    end
    local alltags, alltags_err = Model:getAllTags()
    if not alltags then
        Log(kLogInfo, alltags_err)
    end
    local params = {
        tag_rule = tag_rule,
        alltags = alltags,
        alldomains = ScraperPipeline.CANONICAL_DOMAINS_WITH_TAGS,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("tag_rule_edit", params)
end)

local accept_edit_tag_rule = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/tag-rule")
    if r.params.cancel then
        return redirect
    end
    local tag_rule_id = r.params.tag_rule_id
    local new_incoming_name = r.params.incoming_name
    local new_incoming_domain = r.params.incoming_domain
    local new_tag_name = r.params.tag_name
    if
        not tag_rule_id
        or not new_incoming_name
        or not new_incoming_domain
        or not new_tag_name
    then
        return Fm.serve400()
    end
    local update_ok, update_err = Model:updateTagRule(
        tag_rule_id,
        new_incoming_name,
        new_incoming_domain,
        new_tag_name
    )
    if not update_ok then
        Log(kLogInfo, tostring(update_err))
        return Fm.serve500()
    end
    return redirect
end)

local render_add_tag_rule = WebUtility.login_required(function(r)
    local alltags, alltags_err = Model:getAllTags()
    if not alltags then
        Log(kLogInfo, alltags_err)
    end
    local params = {
        alltags = alltags,
        domains_with_tags = ScraperPipeline.CANONICAL_DOMAINS_WITH_TAGS,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("tag_rule_add", params)
end)

local accept_add_tag_rule = WebUtility.login_required(function(r)
    local redirect = WebUtility.get_post_dialog_redirect(r, "/tag-rule")
    if r.params.cancel or r.params.ok then
        return redirect
    end
    if not r.params.incoming_name then
        return Fm.serveError(400, nil, "Incoming tag name is required")
    end
    if not r.params.incoming_domain then
        return Fm.serveError(400, nil, "Incoming tag description is required")
    end
    if not r.params.tag_name then
        return Fm.serveError(400, nil, "Tag name is required")
    end
    local tag_rule_id, err = Model:createTagRule(
        r.params.incoming_name,
        r.params.incoming_domain,
        r.params.tag_name
    )
    if not tag_rule_id then
        Log(kLogInfo, tostring(err))
        return Fm.serve500(err)
    end
    local changes, change_err =
        Model:applyIncomingTagsNowMatchedBySpecificTagRules { tag_rule_id }
    assert((changes == nil) ~= (change_err == nil))
    if not changes then
        Log(kLogInfo, tostring(change_err))
        return Fm.serve500()
    end
    if #changes < 1 then
        r.session.retarget_to = "body"
        return redirect
    end
    local params = { changes = changes }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("tag_rule_changelist", params)
end)

local render_help = WebUtility.login_optional(function(r, _)
    if r.params.page then
        return Fm.serveContent("help/" .. r.params.page, {})
    end
    return Fm.serveContent("help/index", {})
end)

local render_archive = WebUtility.login_required(function(r, _)
    if not img then
        return Fm.serveError(
            500,
            "This server does not support image processing. Please ask the administrator to recompile Redbean with s0ph0s' img extension."
        )
    end
    local redirect = WebUtility.get_post_dialog_redirect(r, "/home")
    if r.params.cancel then
        return redirect
    end
    if r.params.archive then
        if
            r.params.multipart.image
            and allowed_image_types[r.params.multipart.image.headers["content-type"]]
        then
            local mime_type = r.params.multipart.image.headers["content-type"]
            local image_data = r.params.multipart.image.data
            local imageu8, img_err = img.loadbuffer(image_data)
            if not imageu8 then
                Log(kLogInfo, tostring(img_err))
                r.session.error = "The file you uploaded seems to be corrupt."
                return Fm.serveRedirect(302, r.path)
            end
            local width, height = imageu8:width(), imageu8:height()
            local kind = FsTools.MIME_TO_KIND[mime_type]
            local SP = "manual_archive"
            Model:create_savepoint(SP)
            local gradient_hash = nil
            if r.params.check_duplicates then
                gradient_hash = imageu8:gradienthash()
                local hash_matches, hm_err =
                    Model:findSimilarImageHashes(gradient_hash, 0)
                if not hash_matches then
                    Log(kLogInfo, tostring(hm_err))
                    Model:rollback(SP)
                    r.session.error = "Database error: %s" % { hm_err }
                    return Fm.serveRedirect(302, r.path)
                end
                if #hash_matches > 0 then
                    Model:rollback(SP)
                    local links_list = table.map(hash_matches, function(item)
                        return '<a href="/image/%d">Record %d</a>'
                            % { item.image_id, item.image_id }
                    end)
                    local links = table.concat(links_list, ", ")
                    r.session.error = "This image has the same content hash as %s. Deselect ‘Check for duplicates’ and upload it again if you would like to save it anyway."
                        % { links }
                    return Fm.serveRedirect(302, r.path)
                end
            end
            local result, errmsg =
                Model:insertImage(image_data, mime_type, width, height, kind, 0)
            if not result then
                Model:rollback(SP)
                Log(kLogWarn, tostring(errmsg))
                r.session.error = "Database error: %s" % { errmsg }
                return Fm.serveRedirect(302, r.path)
            end
            if gradient_hash then
                local h_ok, h_err =
                    Model:insertImageHash(result.image_id, gradient_hash)
                if not h_ok then
                    Model:rollback(SP)
                    Log(kLogInfo, tostring(h_err))
                    r.session.error = "Database error: %s" % { h_err }
                    return Fm.serveRedirect(302, r.path)
                end
            end
            local thumbnail, t_err = imageu8:resize(192)
            if not thumbnail then
                Log(kLogInfo, tostring(t_err))
            else
                local thumbnail_webp, tw_err = thumbnail:savebufferwebp()
                if thumbnail_webp then
                    local ti_ok, ti_err = Model:insertThumbnailForImage(
                        result.image_id,
                        thumbnail_webp,
                        thumbnail:width(),
                        thumbnail:height(),
                        1,
                        "image/webp"
                    )
                    if not ti_ok then
                        Log(kLogInfo, tostring(ti_err))
                    end
                else
                    Log(kLogInfo, tostring(tw_err))
                end
            end
            Model:release_savepoint(SP)
            local redirect_url = "/image/%d/edit" % { result.image_id }
            r.headers["HX-Push-Url"] = redirect_url
            return Fm.serveRedirect(302, redirect_url)
        elseif not r.params.multipart.image then
            r.session.error = "You must select an image to upload."
            return Fm.serveRedirect(302, r.path)
        else
            r.session.error = "Only PNG, GIF, and JPEG are supported."
            return Fm.serveRedirect(302, r.path)
        end
    end
    local error = r.session.error
    if error then
        Log(kLogDebug, "Error: %s" % { error })
        r.headers["HX-Retarget"] = "#dialog"
        r.headers["HX-Reselect"] = "#dialog-contents"
    end
    r.session.error = nil
    local params = { error_str = error }
    WebUtility.add_htmx_param(r)
    -- Error conditions:
    -- - Exact file already in archive -> error on form
    -- - Duplicate dHash -> confirm dialog that displays both
    -- - Unable to read file -> error on form
    -- - Unsupported file type -> error on form
    -- - No file uploaded -> error on form
    return Fm.serveContent("archive", params)
end)

local function accept_csp_report(r)
    Log(kLogWarn, "Content-Security-Policy Report: " .. r.body)
    return Fm.serveResponse(204)
end

local function render_query_stats(_)
    local stat_data, err = DbUtil.get_query_stats()
    if not stat_data then
        Log(kLogInfo, tostring(err))
        return Fm.serve500()
    end
    return Fm.serveContent("query_stats", {
        stat_data = stat_data,
    })
end

local function setup_static()
    Fm.setRoute("/favicon.ico", Fm.serveAsset)
    Fm.setRoute("/icon.svg", Fm.serveAsset)
    Fm.setRoute("/apple-touch-icon.png", function(_)
        return Fm.serveAsset("/icon-180.png")
    end)
    Fm.setRoute("/icon-180.png", Fm.serveAsset)
    Fm.setRoute("/icon-192.png", Fm.serveAsset)
    Fm.setRoute("/icon-512.png", Fm.serveAsset)
    Fm.setRoute("/icon-192-maskable.png", Fm.serveAsset)
    Fm.setRoute("/icon-512-maskable.png", Fm.serveAsset)
    Fm.setRoute("/manifest.webmanifest", Fm.serveAsset)
    Fm.setRoute("/style.css", Fm.serveAsset)
    Fm.setRoute("/htmx@2.0.1.min.js", Fm.serveAsset)
    Fm.setRoute("/index.js", Fm.serveAsset)
    Fm.setRoute("/sw.js", Fm.serveAsset)
end

local function setup_login_signup()
    Fm.setRoute(Fm.GET { "/accept-invite/:invite_code" }, render_invite)
    Fm.setRoute(
        Fm.POST { "/accept-invite/:invite_code", _ = invite_validator },
        accept_invite
    )
    Fm.setRoute(Fm.GET { "/login" }, render_login)
    Fm.setRoute(
        Fm.POST { "/login", _ = login_validator, otherwise = 405 },
        accept_login
    )
end

local function setup_queue()
    Fm.setRoute(Fm.GET { "/queue" }, render_queue)
    Fm.setRoute(Fm.POST { "/queue" }, accept_queue)
    Fm.setRoute(Fm.GET { "/queue/:qid[%d]/help" }, render_queue_help)
    Fm.setRoute(Fm.POST { "/queue/:qid[%d]/help" }, accept_queue_help)
    Fm.setRoute("/queue-image/:filename", render_queue_image)
    Fm.setRoute(Fm.GET { "/enqueue" }, render_enqueue)
    Fm.setRoute(Fm.POST { "/enqueue" }, accept_enqueue)
end

local function setup_images()
    Fm.setRoute("/image-file/:filename", render_image_file)
    Fm.setRoute("/preview-file/:filename", render_preview_file)
    Fm.setRoute("/thumbnail-file/:thumbnail_id[%d]", render_thumbnail_file)
    Fm.setRoute(Fm.GET { "/image" }, render_images)
    Fm.setRoute(Fm.POST { "/image" }, accept_images)
    Fm.setRoute("/image/:image_id", render_image)
    Fm.setRoute(Fm.GET { "/image/:image_id[%d]/edit" }, render_image)
    Fm.setRoute(Fm.POST { "/image/:image_id[%d]/edit" }, accept_edit_image)
    -- Manual record upload:
    Fm.setRoute("/archive", render_archive)
end

local function setup_artists()
    Fm.setRoute(Fm.GET { "/artist" }, render_artists)
    Fm.setRoute(Fm.POST { "/artist" }, accept_artists)
    Fm.setRoute(Fm.GET { "/artist/add" }, render_add_artist)
    Fm.setRoute(Fm.POST { "/artist/add" }, accept_add_artist)
    Fm.setRoute("/artist/:artist_id[%d]", render_artist)
    Fm.setRoute(Fm.GET { "/artist/:artist_id[%d]/edit" }, render_edit_artist)
    Fm.setRoute(Fm.POST { "/artist/:artist_id[%d]/edit" }, accept_edit_artist)
end

local function setup_groups()
    Fm.setRoute(Fm.GET { "/image-group" }, render_image_groups)
    Fm.setRoute(Fm.POST { "/image-group" }, accept_image_groups)
    Fm.setRoute("/image-group/:ig_id[%d]", render_image_group)
    Fm.setRoute(
        Fm.GET { "/image-group/:ig_id[%d]/edit" },
        render_edit_image_group
    )
    Fm.setRoute(
        Fm.POST { "/image-group/:ig_id[%d]/edit" },
        accept_edit_image_group
    )
end

local function setup_tags()
    Fm.setRoute(Fm.GET { "/tag" }, render_tags)
    Fm.setRoute(Fm.POST { "/tag" }, accept_tags)
    Fm.setRoute(Fm.GET { "/tag/add" }, render_add_tag)
    Fm.setRoute(Fm.POST { "/tag/add" }, accept_add_tag)
    Fm.setRoute(Fm.GET { "/tag/:tag_id[%d]" }, render_tag)
    Fm.setRoute(Fm.GET { "/tag/:tag_id[%d]/edit" }, render_edit_tag)
    Fm.setRoute(Fm.POST { "/tag/:tag_id[%d]/edit" }, accept_edit_tag)
    Fm.setRoute(Fm.GET { "/tag-rule" }, render_tag_rules)
    Fm.setRoute(Fm.POST { "/tag-rule" }, accept_tag_rules)
    Fm.setRoute(Fm.GET { "/tag-rule/add" }, render_add_tag_rule)
    Fm.setRoute(Fm.POST { "/tag-rule/add" }, accept_add_tag_rule)
    Fm.setRoute("/tag-rule/add-bulk", render_add_tag_rule_bulk)
    Fm.setRoute(Fm.GET { "/tag-rule/:tag_rule_id[%d]" }, render_tag_rule)
    Fm.setRoute(
        Fm.GET { "/tag-rule/:tag_rule_id[%d]/edit" },
        render_edit_tag_rule
    )
    Fm.setRoute(
        Fm.POST { "/tag-rule/:tag_rule_id[%d]/edit" },
        accept_edit_tag_rule
    )
end

local function setup_account()
    Fm.setRoute(Fm.GET { "/link-telegram/:request_id" }, render_telegram_link)
    Fm.setRoute(Fm.POST { "/link-telegram/:request_id" }, accept_telegram_link)
    Fm.setRoute("/account", render_account)
    Fm.setRoute("/account/end-sessions", accept_end_sessions)
    Fm.setRoute(
        Fm.POST { "/account/change-password", _ = change_password_validator },
        accept_change_password
    )
end

local function setup()
    Fm.setTemplate { "/templates/", html = "fmt" }
    setup_static()
    Fm.setRoute("/", render_about)
    Fm.setRoute("/tos", render_tos)
    -- User-facing routes
    Fm.setRoute("/home", render_home)
    setup_login_signup()
    setup_queue()
    setup_images()
    setup_artists()
    setup_groups()
    sharing.setup()
    setup_tags()
    setup_account()
    Fm.setRoute("/help(/:page)", render_help)
    Fm.setRoute("/csp-report", accept_csp_report)
    Fm.setRoute("/query-stats", render_query_stats)
end

local function run()
    return Fm.run()
end

return {
    setup = setup,
    run = run,
}

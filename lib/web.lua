local function render_invite(r)
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        return Fm.serve404()
    end
    return Fm.render(
        "accept_invite",
        { error = r.session.error, invite_record = invite_record }
    )
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
local invite_validator_rule = { "invite_code", minlen = 36, maxlen = 36 }

local invite_validator = Fm.makeValidator {
    invite_validator_rule,
    username_validator_rule,
    password_validator_rule,
    {
        "password_confirm",
        minlen = 16,
        maxlen = 128,
        msg = "%s must be between 16 and 128 characters",
    },
    all = true,
}

local login_validator = Fm.makeValidator {
    username_validator_rule,
    password_validator_rule,
    all = true,
}

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
    local pw_hash = argon2.hash_encoded(r.params.password, GetRandomBytes(32), {
        m_cost = 65536,
        parallelism = 4,
    })
    local result, errmsg =
        Accounts:acceptInvite(r.params.invite_code, r.params.username, pw_hash)
    print(result)
    if not result then
        Log(kLogInfo, "Invitation acceptance failed: %s" % { errmsg })
        return Fm.serve400()
    end
    Log(kLogInfo, "Registration success!")
    return Fm.serveRedirect("/login", 302)
end

local function render_login(r)
    return Fm.serveContent("login", { error = r.session.error })
end

local function login_required(handler)
    return function(r)
        Log(kLogInfo, "session token: %s" % { EncodeJson(r.session.token) })
        if not r.session.token then
            r.session.after_login_url = r.url
            return Fm.serveRedirect("/login", 302)
        end
        local session, errmsg = Accounts:findSessionById(r.session.token)
        if not session then
            Log(kLogDebug, errmsg)
            r.session.after_login_url = r.url
            return Fm.serveRedirect("/login", 302)
        end
        -- TODO: enforce session expiry
        Model = DbUtil.Model:new(nil, session.user_id)
        return handler(r)
    end
end

local function accept_login(r)
    r.session.error = nil
    local user_record, errmsg = Accounts:findUser(r.params.username)
    if not user_record then
        Log(kLogDebug, errmsg)
        -- Resist timing-based oracle attack for username discovery.
        argon2.verify("foobar", r.params.password)
        r.session.error = "Invalid credentials"
        return Fm.serveRedirect("/login", 302)
    end
    Log(kLogDebug, EncodeJson(user_record))
    if not argon2.verify(user_record.password, r.params.password) then
        r.session.error = "Invalid credentials"
        return Fm.serveRedirect("/login", 302)
    end
    local session_id, errmsg2 =
        Accounts:createSessionForUser(user_record.user_id)
    if not session_id then
        Log(kLogDebug, errmsg2)
        r.session.error = errmsg
        return Fm.serveRedirect("/login", 302)
    end
    r.session.token = session_id
    local redirect_url = "/home"
    if r.session.after_login_url then
        redirect_url = r.session.after_login_url
        -- r.session.after_login_url = nil
    end
    return Fm.serveRedirect(redirect_url, 302)
end

local render_home = login_required(function(r)
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local queue_records, errmsg2 = Model:getRecentQueueEntries()
    if not queue_records then
        Log(kLogDebug, errmsg2)
        return Fm.serve500()
    end
    local image_records, errmsg3 = Model:getRecentImageEntries()
    if not image_records then
        Log(kLogDebug, errmsg3)
        return Fm.serve500()
    end
    return Fm.serveContent("home", {
        user = user_record,
        queue_records = queue_records,
        image_records = image_records,
    })
end)

local render_queue_image = login_required(function(r)
    local result, errmsg = Model:getQueueImageById(r.params.id)
    if not result then
        Log(kLogDebug, errmsg)
        return Fm.serve404()
    end
    r.headers.ContentType = result.image_mime_type
    return result.image
end)

local allowed_image_types = {
    ["image/png"] = true,
    ["image/jpeg"] = true,
    ["image/webp"] = true,
    ["image/gif"] = true,
}

local render_enqueue = login_required(function(r)
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    return Fm.serveContent("enqueue", {
        user = user_record,
    })
end)

local accept_enqueue = login_required(function(r)
    if r.params.link then
        local result, errmsg = Model:enqueueLink(r.params.link)
        if not result then
            Log(kLogWarn, errmsg)
        end
        -- TODO: check errors
        return Fm.serveRedirect("/home", 302)
    elseif
        r.params.multipart.image
        and allowed_image_types[r.params.multipart.image.headers["content-type"]]
    then
        local result, errmsg = Model:enqueueImage(
            r.params.multipart.image.headers["content-type"],
            r.params.multipart.image.data
        )
        if not result then
            Log(kLogWarn, errmsg)
        end
        return Fm.serveRedirect("/home", 302)
    else
        return Fm.serve400("Must provide link or PNG/JPEG image file.")
    end
    return Fm.serve500("This should have been unreachable")
end)

local render_image_file = login_required(function(r)
    if not r.params.filename then
        return Fm.serve400()
    end
    local path = "images/%s/%s/%s"
        % {
            r.params.filename:sub(1, 1),
            r.params.filename:sub(2, 2),
            r.params.filename,
        }
    return Fm.serveAsset(path)
end)

local render_image = login_required(function(r)
    if not r.params.image_id then
        return Fm.serve400()
    end
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local image, errmsg1 = Model:getImageById(r.params.image_id)
    if not image then
        Log(kLogInfo, errmsg1)
        return Fm.serve404()
    end
    local artists, errmsg2 = Model:getArtistsForImage(r.params.image_id)
    if not artists then
        Log(kLogInfo, errmsg2)
    end
    local tags, errmsg3 = Model:getTagsForImage(r.params.image_id)
    if not tags then
        Log(kLogInfo, errmsg3)
    end
    local sources, errmsg4 = Model:getSourcesForImage(r.params.image_id)
    if not sources then
        Log(kLogInfo, errmsg4)
    end
    local groups, group_errmsg = Model:getGroupsForImage(r.params.image_id)
    if not groups then
        Log(kLogInfo, group_errmsg)
    end
    for _, ig in ipairs(groups) do
        local siblings, sibling_errmsg =
            Model:getPrevNextImagesInGroupForImage(ig.ig_id, r.params.image_id)
        if not siblings then
            Log(kLogInfo, sibling_errmsg)
        end
        ig.siblings = siblings
    end
    local template_name = "image"
    if r.path:endswith("/edit") then
        template_name = "image_edit"
    end
    return Fm.serveContent(template_name, {
        user = user_record,
        image = image,
        artists = artists,
        tags = tags,
        sources = sources,
        groups = groups,
    })
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

local render_queue = login_required(function(r)
    local per_page = 100
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local queue_count, count_errmsg = Model:getQueueEntryCount()
    if not queue_count then
        Log(kLogDebug, count_errmsg)
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local queue_records, queue_errmsg =
        Model:getPaginatedQueueEntries(cur_page, per_page)
    if not queue_records then
        Log(kLogInfo, queue_errmsg)
        return Fm.serve500()
    end
    local pages =
        pagination_data(cur_page, queue_count, per_page, #queue_records)
    local error = r.session.error
    r.session.error = nil
    return Fm.serveContent("queue", {
        user = user_record,
        error = error,
        queue_records = queue_records,
        pages = pages,
    })
end)

local accept_queue = login_required(function(r)
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
        local ok, err =
            Model:setQueueItemsStatus(r.params.qids, 1, "Manually forced error")
        if not ok then
            r.session.error = err
        end
    else
        return Fm.serve400()
    end
    return Fm.serveRedirect("/queue", 302)
end)

local function render_about(r)
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if errmsg then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    return Fm.serveContent("about", {
        user = user_record,
    })
end

local function render_tos(r)
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if errmsg then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    return Fm.serveContent("tos", {
        user = user_record,
    })
end

local render_queue_help = login_required(function(r)
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record or errmsg then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local queue_entry, queue_errmsg = Model:getQueueEntryById(r.params.qid)
    if not queue_entry then
        return Fm.serve404()
    end
    local dd_str = queue_entry.disambiguation_request
    if not dd_str then
        dd_str = "{}"
    end
    local dd, json_err = DecodeJson(dd_str)
    if json_err then
        Log(
            kLogWarn,
            "JSON decode error while decoding qid %d: %s"
                % { queue_entry.qid, json_err }
        )
        return Fm.serve500()
    end
    r.session.after_help_submit = r.headers["Referer"]
    return Fm.serveContent("queue_help", {
        user = user_record,
        queue_entry = queue_entry,
        disambiguation_data = dd,
    })
end)

local accept_queue_help = login_required(function(r)
    local qid = r.params.qid
    if not qid then
        return Fm.serve400()
    end
    -- TODO: modularize this part so that it can answer both kinds of disambiguation requests
    if
        r.params.save and r.params.discard
        or (not r.params.save and not r.params.discard)
    then
        return Fm.serve400()
    end
    local result = {}
    if r.params.save then
        result = { d = "save" }
    else
        result = { d = "discard" }
    end
    local ok, err = Model:setQueueItemDisambiguationResponse(qid, result)
    if not ok or err then
        Log(kLogInfo, "Database error: %s" % { err })
        return Fm.serve500()
    end
    local last_page = r.session.after_help_submit
    if not last_page then
        last_page = "/home"
    end
    return Fm.serveRedirect(last_page, 302)
end)

local render_images = login_required(function(r)
    local per_page = 100
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record or errmsg then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local image_count, count_errmsg = Model:getImageEntryCount()
    if not image_count then
        Log(kLogDebug, count_errmsg)
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
    return Fm.serveContent("images", {
        user = user_record,
        error = error,
        image_records = image_records,
        pages = pages,
    })
end)

local render_artists = login_required(function(r)
    local per_page = 100
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record or errmsg then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local artist_count, count_errmsg = Model:getArtistCount()
    if not artist_count then
        Log(kLogDebug, count_errmsg)
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local artist_records, artist_errmsg =
        Model:getPaginatedArtists(cur_page, per_page)
    if not artist_records then
        Log(kLogInfo, artist_errmsg)
        return Fm.serve500()
    end
    local pages =
        pagination_data(cur_page, artist_count, per_page, #artist_records)
    local error = r.session.error
    r.session.error = nil
    return Fm.serveContent("artists", {
        user = user_record,
        error = error,
        artist_records = artist_records,
        pages = pages,
    })
end)

local accept_artists = login_required(function(r)
    local redirect_path = r.makePath(r.path, r.params)
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteArtists(r.params.artist_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    elseif r.params.merge == "Merge" then
        local artist_ids = r.params.artist_ids
        if #artist_ids < 2 then
            r.session.error = "You must select at least two artists to merge!"
            return Fm.serveRedirect(redirect_path, 302)
        end
        local merge_into_id = artist_ids[#artist_ids]
        artist_ids[#artist_ids] = nil
        local ok, errmsg = Model:mergeArtists(merge_into_id, artist_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    end
    return Fm.serveRedirect(redirect_path, 302)
end)

local render_artist = login_required(function(r)
    local artist_id = r.params.artist_id
    if not artist_id then
        return Fm.serve400()
    end
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local artist, errmsg1 = Model:getArtistById(artist_id)
    if not artist then
        Log(kLogInfo, errmsg1)
        return Fm.serve404()
    end
    local handles, errmsg2 = Model:getHandlesForArtist(artist_id)
    if not handles then
        Log(kLogInfo, errmsg2)
    end
    local images, images_err = Model:getRecentImagesForArtist(artist_id, 20)
    if not images then
        Log(kLogInfo, errmsg2)
        return Fm.serve500()
    end
    return Fm.serveContent("artist", {
        user = user_record,
        artist = artist,
        handles = handles,
        images = images,
    })
end)

local render_add_artist = login_required(function(r)
    return Fm.serveContent("add_artist")
end)

local accept_add_artist = login_required(function(r)
    local usernames = r.params.usernames
    local profile_urls = r.params.profile_urls
    if not r.params.name then
        return Fm.serveError(400, "Artist name is required")
    end
    if not usernames then
        return Fm.serveError(400, "At least one username is required")
    end
    if not profile_urls then
        return Fm.serveError(400, "At least one profile URL is required")
    end
    if #usernames ~= #profile_urls then
        return Fm.serveError(
            400,
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
            username = usernames[i],
        }
    end
    local artist_id, err =
        Model:createArtistWithHandles(r.params.name, 1, handles)
    if not artist_id then
        Log(kLogInfo, err)
        return Fm.serve500(err)
    end
    return Fm.serveRedirect("/artist/" .. artist_id, 302)
end)

local render_image_groups = login_required(function(r)
    local per_page = 100
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record or errmsg then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local ig_count, count_errmsg = Model:getImageGroupCount()
    if not ig_count then
        Log(kLogDebug, tostring(count_errmsg))
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local ig_records, ig_errmsg =
        Model:getPaginatedImageGroups(cur_page, per_page)
    if not ig_records then
        Log(kLogInfo, ig_errmsg)
        return Fm.serve500()
    end
    local pages = pagination_data(cur_page, ig_count, per_page, #ig_records)
    local error = r.session.error
    r.session.error = nil
    return Fm.serveContent("image_groups", {
        user = user_record,
        error = error,
        ig_records = ig_records,
        pages = pages,
    })
end)

local render_image_group = login_required(function(r)
    if not r.params.ig_id then
        return Fm.serve400()
    end
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    local ig, ig_errmsg = Model:getImageGroupById(r.params.ig_id)
    if not ig then
        Log(kLogInfo, ig_errmsg)
        return Fm.serve404()
    end
    local images, image_errmsg = Model:getImagesForGroup(r.params.ig_id)
    if not images then
        Log(kLogInfo, image_errmsg)
    end
    return Fm.serveContent("image_group", {
        user = user_record,
        ig = ig,
        images = images,
    })
end)

local render_telegram_link = login_required(function(r)
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
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    return Fm.serveContent("link_telegram", {
        user = user_record,
        tg = tg,
    })
end)

local accept_telegram_link = login_required(function(r)
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
    local user_record, errmsg = Accounts:findUserBySessionId(r.session.token)
    if not user_record then
        Log(kLogDebug, errmsg)
        return Fm.serve500()
    end
    if r.params.link == "Link" then
        local link_ok, link_err =
            Accounts:setTelegramUserIDForUserAndDeleteLinkRequest(
                user_record.user_id,
                tg.tg_userid,
                r.params.request_id
            )
        if not link_ok then
            Log(kLogInfo, link_err)
            return Fm.serve500()
        end
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

local function setup()
    Fm.setTemplate { "/templates/", html = "fmt" }
    Fm.setRoute("/favicon.ico", Fm.serveAsset)
    Fm.setRoute("/style.css", Fm.serveAsset)
    Fm.setRoute("/", render_about)
    Fm.setRoute("/tos", render_tos)
    -- User-facing routes
    Fm.setRoute(Fm.GET { "/accept-invite/:invite_code" }, render_invite)
    Fm.setRoute(
        Fm.POST { "/accept-invite/:invite_code", _ = invite_validator },
        accept_invite
    )
    Fm.setRoute(Fm.GET { "/login" }, render_login)
    Fm.setRoute(Fm.POST { "/login", _ = login_validator }, accept_login)
    Fm.setRoute(Fm.GET { "/queue" }, render_queue)
    Fm.setRoute(Fm.POST { "/queue" }, accept_queue)
    Fm.setRoute(Fm.GET { "/queue/:qid/help" }, render_queue_help)
    Fm.setRoute(Fm.POST { "/queue/:qid/help" }, accept_queue_help)
    Fm.setRoute("/home", render_home)
    Fm.setRoute("/image-file/:filename", render_image_file)
    Fm.setRoute("/image", render_images)
    Fm.setRoute("/image/:image_id", render_image)
    Fm.setRoute(Fm.GET { "/image/:image_id/edit" }, render_image)
    Fm.setRoute(Fm.GET { "/enqueue" }, render_enqueue)
    Fm.setRoute(Fm.POST { "/enqueue" }, accept_enqueue)
    Fm.setRoute(Fm.GET { "/artist" }, render_artists)
    Fm.setRoute(Fm.POST { "/artist" }, accept_artists)
    Fm.setRoute(Fm.GET { "/artist/add" }, render_add_artist)
    Fm.setRoute(Fm.POST { "/artist/add" }, accept_add_artist)
    Fm.setRoute("/artist/:artist_id[%d]", render_artist)
    Fm.setRoute("/image-group", render_image_groups)
    Fm.setRoute("/image-group/:ig_id", render_image_group)
    Fm.setRoute(Fm.GET { "/link-telegram/:request_id" }, render_telegram_link)
    Fm.setRoute(Fm.POST { "/link-telegram/:request_id" }, accept_telegram_link)
    -- API routes
    Fm.setRoute(Fm.GET { "/api/queue-image/:id" }, render_queue_image)
    -- Fm.setRoute("/api/telegram-webhook")
    Fm.setRoute(Fm.POST { "/api/enqueue" }, accept_enqueue)
end

local function run()
    return Fm.run()
end

return {
    setup = setup,
    run = run,
}

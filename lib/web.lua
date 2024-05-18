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

local function get_client_ip(r)
    local ip = r.headers["X-Forwarded-For"]
    if not ip then
        local ip_raw = GetClientAddr()
        ip = FormatIp(ip_raw)
    end
    return ip
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
        local u_ok, u_err = Accounts:updateSessionLastSeenToNow(r.session.token)
        if not u_ok then
            Log(kLogInfo, u_err)
        end
        Model = DbUtil.Model:new(nil, session.user_id)
        local ip = get_client_ip(r)
        local user_record, user_err =
            Accounts:findUserBySessionId(r.session.token, ip)
        if not user_record then
            Log(kLogDebug, user_err)
            return Fm.serve500()
        end
        return handler(r, user_record)
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
    local result, verify_err =
        argon2.verify(user_record.password, r.params.password)
    if not result then
        r.session.error = "Invalid credentials"
        Log(
            kLogVerbose,
            "Denying attempted login for %s due to error from argon2: %s"
                % { r.params.username, verify_err }
        )
        return Fm.serveRedirect("/login", 302)
    end
    local ip = get_client_ip(r)
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
    r.session.token = session_id
    local redirect_url = "/home"
    if r.session.after_login_url then
        redirect_url = r.session.after_login_url
        -- r.session.after_login_url = nil
    end
    return Fm.serveRedirect(redirect_url, 302)
end

local render_home = login_required(function(r, user_record)
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

local render_queue_image = login_required(function(r, user_record)
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

local render_enqueue = login_required(function(r, user_record)
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

local image_functions = {
    category_str = function(category)
        if not category then
            return "None"
        end
        local cs = DbUtil.k.CategoryLoopable
        local result = {}
        for i = 1, #cs do
            local c = cs[i]
            if (category & c[1]) == c[1] then
                result[#result + 1] = c[2]
            end
        end
        if #result < 1 then
            return "None"
        end
        return table.concat(result, ", ")
    end,
    rating_str = function(rating)
        return DbUtil.k.RatingLoopable[rating]
    end,
    kind_str = function(kind)
        return DbUtil.k.ImageKindLoopable[kind]
    end,
}

local function not_emptystr(x)
    return x and #x > 0
end

local function render_image_internal(r, user_record)
    if not r.params.image_id then
        return Fm.serve400()
    end
    local image, image_err = Model:getImageById(r.params.image_id)
    if not image then
        Log(kLogInfo, image_err)
        return Fm.serve404()
    end
    local artists, artists_err = Model:getArtistsForImage(r.params.image_id)
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
    local tags, tags_err = Model:getTagsForImage(r.params.image_id)
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
    local sources, sources_err = Model:getSourcesForImage(r.params.image_id)
    if not sources then
        Log(kLogInfo, sources_err)
    end
    local delete_sources = r.params.delete_sources
    if delete_sources then
        sources = table.filter(sources, function(s)
            return table.find(delete_sources, s.source_id) ~= nil
        end)
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
    local pending_artists = r.params.pending_artists
    if pending_artists then
        pending_artists = table.filter(pending_artists, not_emptystr)
    end
    local pending_tags = r.params.pending_tags
    if pending_tags then
        pending_tags = table.filter(pending_tags, not_emptystr)
    end
    local pending_sources = r.params.pending_sources
    if pending_sources then
        pending_sources = table.filter(pending_sources, not_emptystr)
    end
    local template_name = "image"
    if r.path:endswith("/edit") then
        template_name = "image_edit"
    end
    return Fm.serveContent(template_name, {
        user = user_record,
        image = image,
        artists = artists,
        delete_artists = delete_artists,
        pending_artists = pending_artists,
        allartists = allartists,
        tags = tags,
        delete_tags = delete_tags,
        pending_tags = pending_tags,
        alltags = alltags,
        sources = sources,
        delete_sources = delete_sources,
        pending_sources = pending_sources,
        groups = groups,
        category = r.params.category or image.category,
        rating = r.params.rating or image.rating,
        fn = image_functions,
        DbUtilK = DbUtil.k,
    })
end

local render_image = login_required(render_image_internal)

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

local accept_edit_image = login_required(function(r, user_record)
    local redirect_url = "/image/" .. r.params.image_id
    if r.params.cancel == "Cancel" then
        Log(kLogDebug, "Cancelling edit")
        return Fm.serveRedirect(redirect_url, 302)
    end
    -- Validation & Cleanup
    Log(kLogDebug, "Beginning validation & cleanup")
    local rating = tonumber(r.params.rating)
    if r.params.rating and not rating then
        return Fm.serveError(400, "Bad rating")
    end
    r.params.rating = rating
    local categories = table.reduce(r.params.category or {}, function(acc, next)
        return (acc or 0) | (tonumber(next) or 0)
    end)
    if not categories and r.params.category then
        return Fm.serveError(400, "Bad categories")
    end
    r.params.category = categories
    local pending_artists = r.params.pending_artists
    if pending_artists then
        r.params.pending_artists = table.filter(pending_artists, not_emptystr)
    end
    local pending_tags = r.params.pending_tags
    if pending_tags then
        r.params.pending_tags = table.filter(pending_tags, not_emptystr)
    end
    local pending_sources = r.params.pending_sources
    if pending_sources then
        r.params.pending_sources = table.filter(pending_sources, not_emptystr)
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
        if not r.params.category or not r.params.rating then
            return Fm.serveError(400, "Missing category or rating")
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
                Log(kLogInfo, dartists_err)
                return Fm.serve500()
            end
        end
        if r.params.pending_artists then
            local aartists_ok, aartists_err = Model:addArtistsForImageByName(
                image_id,
                r.params.pending_artists
            )
            if not aartists_ok then
                Log(kLogInfo, aartists_err)
                return Fm.serve500()
            end
        end
        -- Tags
        if r.params.delete_tags then
            local dtags_ok, dtags_err =
                Model:deleteTagsForImageById(image_id, r.params.delete_tags)
            if not dtags_ok then
                Log(kLogInfo, dtags_err)
                return Fm.serve500()
            end
        end
        if r.params.pending_tags then
            local atags_ok, atags_err =
                Model:addTagsForImageByName(image_id, r.params.pending_tags)
            if not atags_ok then
                Log(kLogInfo, atags_err)
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
                Log(kLogInfo, dsources_err)
                return Fm.serve500()
            end
        end
        if r.params.pending_sources then
            local asources_ok, asources_err =
                Model:insertSourcesForImage(image_id, r.params.pending_sources)
            if not asources_ok then
                Log(kLogInfo, asources_err)
                return Fm.serve500()
            end
        end
        -- Done!
        return Fm.serveRedirect("/image/" .. r.params.image_id, 302)
    end
    return render_image_internal(r, user_record)
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

local render_queue = login_required(function(r, user_record)
    local per_page = 100
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

local function render_about(r, user_record)
    return Fm.serveContent("about", {
        user = user_record,
    })
end

local function render_tos(r, user_record)
    return Fm.serveContent("tos", {
        user = user_record,
    })
end

local render_queue_help = login_required(function(r, user_record)
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

local render_images = login_required(function(r, user_record)
    local per_page = 100
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

local render_artists = login_required(function(r, user_record)
    local per_page = 100
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
    r.session.after_action = r.makePath(r.path, r.params)
    return Fm.serveContent("artists", {
        user = user_record,
        error = error,
        artist_records = artist_records,
        pages = pages,
    })
end)

local accept_artists = login_required(function(r)
    local redirect_path = r.session.after_action or r.makePath(r.path, r.params)
    r.session.after_action = nil
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteArtists(r.params.artist_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    elseif r.params.merge == "Merge" then
        local artist_ids = r.params.artist_ids
        artist_ids = table.map(artist_ids, tonumber)
        table.sort(artist_ids)
        if #artist_ids < 2 then
            r.session.error = "You must select at least two artists to merge!"
            return Fm.serveRedirect(redirect_path, 302)
        end
        -- Yes, this is slower because it moves everything down, but it preserves
        -- earlier artist IDs, which makes me happier.
        local merge_into_id = table.remove(artist_ids, 1)
        local ok, errmsg = Model:mergeArtists(merge_into_id, artist_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    end
    return Fm.serveRedirect(redirect_path, 302)
end)

local render_artist = login_required(function(r, user_record)
    local artist_id = r.params.artist_id
    if not artist_id then
        return Fm.serve400()
    end
    local artist, errmsg1 = Model:getArtistById(artist_id)
    if not artist then
        Log(kLogInfo, errmsg1)
        return Fm.serve404()
    end
    local handles, errmsg2 = Model:getHandlesForArtist(artist_id)
    if not handles then
        Log(kLogInfo, errmsg2)
        return Fm.serve500()
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
    return Fm.serveContent("artist_add")
end)

local function render_edit_artist_internal(r)
    local artist_id = r.params.artist_id
    if not artist_id then
        return Fm.serve400()
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
    local delete_handles = r.params.delete_handles
    if delete_handles then
        handles = table.filter(handles, function(h)
            return table.find(delete_handles, h.handle_id) ~= nil
        end)
    end
    local pending_usernames = r.params.pending_usernames
    if pending_usernames then
        pending_usernames = table.filter(pending_usernames, not_emptystr)
    end
    local pending_profile_urls = r.params.pending_profile_urls
    if pending_profile_urls then
        pending_profile_urls = table.filter(pending_profile_urls, not_emptystr)
    end
    return Fm.serveContent("artist_edit", {
        artist = artist,
        handles = handles,
        pending_usernames = pending_usernames,
        pending_profile_urls = pending_profile_urls,
        name = r.params.name or artist.name,
        manually_confirmed = r.params.confirmed or artist.manually_confirmed,
    })
end

local render_edit_artist = login_required(render_edit_artist_internal)

local accept_edit_artist = login_required(function(r)
    local redirect_url = "/artist/" .. r.params.artist_id
    local pending_usernames = r.params.pending_usernames
    local pending_profile_urls = r.params.pending_profile_urls
    local pending_handles = {}
    if pending_usernames and pending_profile_urls then
        if #pending_usernames ~= #pending_profile_urls then
            return Fm.serveError(
                400,
                "Number of usernames and profile URLs must match!"
            )
        end
        for i = 1, #pending_usernames do
            local pending_username = pending_usernames[i]
            local pending_profile_url = pending_profile_urls[i]
            if (#pending_username > 0) ~= (#pending_profile_url > 0) then
                return Fm.serveError(
                    400,
                    "Both the username and profile URL are mandatory."
                )
            end
            if (#pending_username ~= 0) and (#pending_profile_url ~= 0) then
                local domain = ParseUrl(pending_profile_url).host
                if not domain then
                    return Fm.serveError(400, "Invalid profile URL.")
                end
                pending_handles[#pending_handles + 1] = {
                    pending_username,
                    domain,
                    pending_profile_url,
                }
            end
        end
        r.params.pending_usernames =
            table.filter(pending_usernames, not_emptystr)
        r.params.pending_profile_urls =
            table.filter(pending_profile_urls, not_emptystr)
    end
    if r.params.delete_handle then
        local to_delete = r.params.delete_handles or {}
        to_delete[#to_delete + 1] = r.params.delete_handle
        r.params.delete_handles = to_delete
        r.params.delete_handle = nil
        return render_edit_artist_internal(r)
    end
    if r.params.delete_pending_handle then
        local pending_usernames = r.params.pending_usernames
        local pending_profile_urls = r.params.pending_profile_urls
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
            return Fm.serveError(400, "Missing artist name")
        end
        local verified = r.params.confirmed ~= nil
        local artist_ok, artist_err =
            Model:updateArtist(artist_id, r.params.name, verified)
        if not artist_ok then
            Log(kLogInfo, tostring(artist_err))
            return Fm.serve500()
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
        return Fm.serveRedirect("/artist/" .. artist_id, 302)
    end
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

local render_image_groups = login_required(function(r, user_record)
    local per_page = 100
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
    r.session.after_action = r.makePath(r.path, r.params)
    return Fm.serveContent("image_groups", {
        user = user_record,
        error = error,
        ig_records = ig_records,
        pages = pages,
    })
end)

local accept_image_groups = login_required(function(r)
    local redirect_path = r.session.after_action or r.makePath(r.path, r.params)
    r.session.after_action = nil
    print("will redirect to " .. redirect_path)
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteImageGroups(r.params.ig_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    elseif r.params.merge == "Merge" then
        local ig_ids = r.params.ig_ids
        ig_ids = table.map(ig_ids, tonumber)
        table.sort(ig_ids)
        if #ig_ids < 2 then
            r.session.error =
                "You must select at least two image groups to merge!"
            return Fm.serveRedirect(redirect_path, 302)
        end
        local merge_into_id = table.remove(ig_ids, 1)
        local ok, errmsg = Model:mergeImageGroups(merge_into_id, ig_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    end
    return Fm.serveRedirect(redirect_path, 302)
end)

local render_image_group = login_required(function(r, user_record)
    if not r.params.ig_id then
        return Fm.serve400()
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

local render_edit_image_group = login_required(function(r, user_record)
    if not r.params.ig_id then
        return Fm.serve400()
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
    r.session.after_action = r.headers.Referer
    return Fm.serveContent("image_group_edit", {
        user = user_record,
        ig = ig,
        images = images,
    })
end)

local accept_edit_image_group = login_required(function(r)
    local redirect_url = r.params.after_action or r.makePath(r.path, r.params)
    r.params.after_action = nil
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
            "Must have the same number of image_ids as new_orders"
        )
    end
    local SP = "reorder_images_in_group"
    Model:create_savepoint(SP)
    local rename_ok, rename_err = Model:renameImageGroup(ig_id, new_name)
    if not rename_ok then
        Model:rollback(SP)
        Log(kLogInfo, rename_err)
        return Fm.serve500()
    end
    for i = 1, #image_ids do
        local reorder_ok, reorder_err =
            Model:setOrderForImageInGroup(ig_id, image_ids[i], new_orders[i])
        if not reorder_ok then
            Model:rollback(SP)
            Log(kLogInfo, reorder_err)
            return Fm.serve500()
        end
    end
    Model:release_savepoint(SP)
    return Fm.serveRedirect(redirect_url, 302)
end)

local render_telegram_link = login_required(function(r, user_record)
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
    return Fm.serveContent("link_telegram", {
        user = user_record,
        tg = tg,
    })
end)

local accept_telegram_link = login_required(function(r, user_record)
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

local render_tags = login_required(function(r, user_record)
    local per_page = 100
    local tag_count, tagcount_errmsg = Model:getTagCount()
    if not tag_count then
        Log(kLogDebug, tostring(tagcount_errmsg))
        return Fm.serve500()
    end
    local cur_page = tonumber(r.params.page or "1")
    if cur_page < 1 then
        return Fm.serve400()
    end
    local tag_records, tag_errmsg = Model:getPaginatedTags(cur_page, per_page)
    if not tag_records then
        Log(kLogInfo, tostring(tag_errmsg))
        return Fm.serve500()
    end
    local pages = pagination_data(cur_page, tag_count, per_page, #tag_records)
    local error = r.session.error
    r.session.error = nil
    r.session.after_action = r.makePath(r.path, r.params)
    return Fm.serveContent("tags", {
        user = user_record,
        error = error,
        tag_records = tag_records,
        pages = pages,
    })
end)

local accept_tags = login_required(function(r)
    local redirect_path = r.session.after_action or r.makePath(r.path, r.params)
    r.session.after_action = nil
    if r.params.delete == "Delete" then
        local ok, errmsg = Model:deleteTags(r.params.tag_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    elseif r.params.merge == "Merge" then
        local tag_ids = r.params.tag_ids
        tag_ids = table.map(tag_ids, tonumber)
        table.sort(tag_ids)
        if #tag_ids < 2 then
            r.session.error = "You must select at least two tags to merge!"
            return Fm.serveRedirect(redirect_path, 302)
        end
        -- Yes, this is slower because it moves everything down, but it preserves
        -- earlier tag IDs, which makes me happier.
        local merge_into_id = table.remove(tag_ids, 1)
        local ok, errmsg = Model:mergeTags(merge_into_id, tag_ids)
        if not ok then
            Log(kLogInfo, errmsg)
            return Fm.serve500()
        end
    end
    return Fm.serveRedirect(redirect_path, 302)
end)

local render_tag = login_required(function(r, user_record)
    local tag_id = r.params.tag_id
    if not tag_id then
        return Fm.serve400()
    end
    local tag_record, tr_err = Model:getTagById(tag_id)
    if not tag_record then
        Log(kLogInfo, tr_err)
        return Fm.serve404()
    end
    local images, images_err = Model:getRecentImagesForTag(tag_id, 20)
    if not images then
        Log(kLogInfo, images_err)
        return Fm.serve500()
    end
    return Fm.serveContent("tag", {
        user = user_record,
        tag = tag_record,
        images = images,
    })
end)

local render_edit_tag = login_required(function(r, user_record)
    if not r.params.tag_id then
        return Fm.serve400()
    end
    local tag, tag_errmsg = Model:getTagById(r.params.tag_id)
    if not tag then
        Log(kLogInfo, tag_errmsg)
        return Fm.serve404()
    end
    r.session.after_action = r.headers.Referer
    return Fm.serveContent("tag_edit", {
        user = user_record,
        tag = tag,
    })
end)

local accept_edit_tag = login_required(function(r)
    local redirect_url = r.params.after_action or r.makePath(r.path, r.params)
    r.params.after_action = nil
    local tag_id = r.params.tag_id
    local new_name = r.params.name
    local new_desc = r.params.description
    if not tag_id or not new_name or not new_desc then
        return Fm.serve400()
    end
    local update_ok, update_err = Model:updateTag(tag_id, new_name, new_desc)
    if not update_ok then
        Log(kLogInfo, update_err)
        return Fm.serve500()
    end
    return Fm.serveRedirect(redirect_url, 302)
end)

local render_add_tag = login_required(function(r)
    return Fm.serveContent("tag_add")
end)

local accept_add_tag = login_required(function(r)
    if not r.params.name then
        return Fm.serveError(400, "Tag name is required")
    end
    if not r.params.description then
        return Fm.serveError(400, "Tag description is required")
    end
    local tag_id, err = Model:createTag(r.params.name, r.params.description)
    if not tag_id then
        Log(kLogInfo, tostring(err))
        return Fm.serve500(err)
    end
    return Fm.serveRedirect("/tag/" .. tag_id, 302)
end)

local render_account = login_required(function(r, user_record)
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
    return Fm.serveContent("account", {
        user = user_record,
        image_stats = image_stats,
        artist_count = artist_count,
        tag_count = tag_count,
        data_size = data_size,
        telegram_accounts = telegram_accounts,
        sessions = sessions,
        invites = invites,
    })
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
    Fm.setRoute(Fm.GET { "/queue/:qid[%d]/help" }, render_queue_help)
    Fm.setRoute(Fm.POST { "/queue/:qid[%d]/help" }, accept_queue_help)
    Fm.setRoute("/home", render_home)
    Fm.setRoute("/image-file/:filename", render_image_file)
    Fm.setRoute("/image", render_images)
    Fm.setRoute("/image/:image_id", render_image)
    Fm.setRoute(Fm.GET { "/image/:image_id[%d]/edit" }, render_image)
    Fm.setRoute(Fm.POST { "/image/:image_id[%d]/edit" }, accept_edit_image)
    Fm.setRoute(Fm.GET { "/enqueue" }, render_enqueue)
    Fm.setRoute(Fm.POST { "/enqueue" }, accept_enqueue)
    Fm.setRoute(Fm.GET { "/artist" }, render_artists)
    Fm.setRoute(Fm.POST { "/artist" }, accept_artists)
    Fm.setRoute(Fm.GET { "/artist/add" }, render_add_artist)
    Fm.setRoute(Fm.POST { "/artist/add" }, accept_add_artist)
    Fm.setRoute("/artist/:artist_id[%d]", render_artist)
    Fm.setRoute(Fm.GET { "/artist/:artist_id[%d]/edit" }, render_edit_artist)
    Fm.setRoute(Fm.POST { "/artist/:artist_id[%d]/edit" }, accept_edit_artist)
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
    Fm.setRoute(Fm.GET { "/link-telegram/:request_id" }, render_telegram_link)
    Fm.setRoute(Fm.POST { "/link-telegram/:request_id" }, accept_telegram_link)
    Fm.setRoute(Fm.GET { "/tag" }, render_tags)
    Fm.setRoute(Fm.POST { "/tag" }, accept_tags)
    Fm.setRoute(Fm.GET { "/tag/add" }, render_add_tag)
    Fm.setRoute(Fm.POST { "/tag/add" }, accept_add_tag)
    Fm.setRoute(Fm.GET { "/tag/:tag_id[%d]" }, render_tag)
    Fm.setRoute(Fm.GET { "/tag/:tag_id[%d]/edit" }, render_edit_tag)
    Fm.setRoute(Fm.POST { "/tag/:tag_id[%d]/edit" }, accept_edit_tag)
    Fm.setRoute("/account", render_account)
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

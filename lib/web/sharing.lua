local kTelegram = "Telegram"
local kDiscord = "Discord"
local SHARE_SERVICES = { kTelegram, kDiscord }

--- Fetch data from the database.
local function fetch_data(r, user_record, images)
    local spl_id = tonumber(r.params.to)
    local tg_userid = tonumber(r.params.to_user)
    local spl, spl_err = nil, nil
    if spl_id then
        spl, spl_err = Model:getSharePingListById(spl_id)
        if not spl then
            Log(kLogInfo, tostring(spl_err))
            return nil, Fm.serve500()
        end
    elseif tg_userid then
        local tg_account, _ = Accounts:getTelegramAccountByUserIdAndTgUserId(
            user_record.user_id,
            tg_userid
        )
        if not tg_account then
            return nil,
                Fm.serveError(
                    500,
                    nil,
                    "That Telegram account isn't linked to your account"
                )
        end
    end
    for i = 1, #images do
        local image = images[i]
        local sources, sources_err = Model:getSourcesForImage(image.image_id)
        if not sources then
            Log(kLogInfo, sources_err)
            return Fm.serve500()
        end
        local attributions, attributions_err =
            Model:getAttributionForImage(image.image_id)
        if not attributions then
            Log(kLogInfo, attributions_err)
            return Fm.serve500()
        end
        image.sources = sources
        image.attributions = attributions
        image.sources_text = r.params["sources_text_record_" .. image.image_id]
        image.spoiler = r.params["spoiler_record_" .. image.image_id] ~= nil
        local _, file_path = FsTools.make_image_path_from_filename(image.file)
        image.file_path = file_path
    end
    return {
        spl_id = spl_id,
        tg_userid = tg_userid,
        spl = spl,
    }
end

--- Cancel the request.
local function do_cancel(share_id, redir_url)
    if not share_id then
        return Fm.serveError(400, nil, "Must include share_id in request")
    end
    local d_ok, d_err = Model:deleteShareRecords { share_id }
    if not d_ok then
        Log(kLogInfo, tostring(d_err))
        return Fm.serveError(500)
    end
    return Fm.serveRedirect(redir_url, 302)
end

--- Actually share the image(s).
local function do_share(share_id, spl, tg_userid, images, ping_text, redir_url)
    local token_ok, token_err =
        Model:updatePendingShareRecordWithDateNow(share_id)
    if not token_ok then
        Log(kLogInfo, tostring(token_err))
        return Fm.serveError(
            400,
            nil,
            "The share token you used is invalid. Did you double-click the share button?"
        )
    end
    local share_ok, share_err
    if not spl or spl.share_data.type == kTelegram then
        local chat_id = (spl and spl.share_data.chat_id) or tg_userid
        share_ok, share_err = Bot.share_media(chat_id, images, ping_text)
    elseif spl.share_data.type == kDiscord then
        share_ok, share_err =
            Discord.share_media(spl.share_data.webhook, images, ping_text)
    end
    if not share_ok then
        return Fm.serveError(400, nil, share_err)
    end
    return Fm.serveRedirect(redir_url, 302)
end

local function transform_source_for_discord(source)
    return "<" .. source .. ">"
end

local function identity_transform(source)
    return source
end

local transform_sources = {
    [kDiscord] = transform_source_for_discord,
    [kTelegram] = identity_transform,
}

--- Prepare the default data shown in the share form.
local function prep_form_data(r, user_record, group, images, data, getPings)
    local ping_data, pd_err = {}, nil
    local source_transformer
    if data.spl then
        ping_data, pd_err = getPings(data.spl.spl_id)
        if not ping_data then
            Log(kLogInfo, pd_err)
            return Fm.serve500()
        end
        source_transformer = transform_sources[data.spl.share_data.type]
    else
        source_transformer = transform_sources[kTelegram]
    end
    for i = 1, #images do
        local image = images[i]
        local attribution_text
        if #image.attributions == 1 then
            attribution_text = image.attributions[1].name
        else
            attribution_text = table.concat(
                table.map(image.attributions, function(a)
                    return a.name
                end),
                ", "
            )
        end
        local sources_text
        if #image.sources == 1 then
            sources_text = source_transformer(image.sources[1].link)
        else
            sources_text = table.concat(
                table.map(image.sources, function(s)
                    return string.format("• %s", source_transformer(s.link))
                end),
                "\n"
            )
        end
        local per_media_text = "By " .. attribution_text .. "\n" .. sources_text
        image.sources_text = image.sources_text or per_media_text
        image.sources_text_size = image.sources_text:linecount()
    end
    local ping_text = table.concat(
        table.map(ping_data, function(d)
            return string.format("%s: %s", d.handle, d.tag_names)
        end),
        "\n"
    )
    local attribution = "Shared by %s" % { user_record.username }
    if data.spl and data.spl.send_with_attribution then
        ping_text = ping_text .. "\n\n" .. attribution
    end
    local form_ping_text = r.params.ping_text or ping_text
    local params = {
        group = group,
        ig_id = r.params.ig_id,
        image_id = r.params.image_id,
        images = images,
        share_ping_list = data.spl,
        ping_text = form_ping_text,
        ping_text_size = form_ping_text:linecount(),
        share_id = r.params.t,
        to = data.spl_id,
        to_user = data.tg_userid,
        fn = WebUtility.image_functions,
        print = print,
        EncodeJson = EncodeJson,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    Fm.setTemplateVar("rv_hide_fullsize_msg", true)
    return Fm.serveContent("image_share", params)
end

--- All the parts of sharing that are the same between images and groups.
local function share_common(r, user_record, group, images, redir_url, getPings)
    local data, err = fetch_data(r, user_record, images)
    if not data then
        return err
    end
    if r.params.cancel then
        return do_cancel(r.params.share_id, redir_url)
    end
    if r.params.share then
        return do_share(
            r.params.share_id,
            data.spl,
            data.tg_userid,
            images,
            r.params.ping_text,
            redir_url
        )
    end
    return prep_form_data(r, user_record, group, images, data, getPings)
end

--- Render/accept image share requests.
local render_image_share = WebUtility.login_required(function(r, user_record)
    local image_id = tonumber(r.params.image_id)
    local image, image_err = Model:getImageById(image_id)
    if not image then
        Log(kLogInfo, tostring(image_err))
        return Fm.serve500()
    end
    local function getPings(spl_id)
        return Model:getPingsForImage(image_id, spl_id)
    end
    return share_common(
        r,
        user_record,
        false,
        { image },
        "/image/" .. tostring(image_id),
        getPings
    )
end)

--- Render/accept image group share requests.
local render_image_group_share = WebUtility.login_required(
    function(r, user_record)
        local ig_id = tonumber(r.params.ig_id)
        local images, images_err = Model:getImagesForGroup(ig_id)
        if not images then
            Log(kLogInfo, images_err)
            return Fm.serve500()
        end
        local function getPings(spl_id)
            return Model:getPingsForImageGroup(ig_id, spl_id)
        end
        return share_common(
            r,
            user_record,
            true,
            images,
            "/image-group/" .. tostring(ig_id),
            getPings
        )
    end
)

local function make_telegram_share_data(r)
    if
        not WebUtility.not_emptystr(r.params.chat_id)
        or not tonumber(r.params.chat_id)
    then
        return nil, Fm.serveError(400, nil, "Invalid chat ID")
    end
    local share_data = EncodeJson {
        type = kTelegram,
        chat_id = tonumber(r.params.chat_id),
    }
    return share_data
end

local function make_discord_share_data(r)
    local webhook = r.params.webhook
    if
        not WebUtility.not_emptystr(webhook)
        or not webhook:startswith("https://discord.com/api/")
    then
        return nil,
            Fm.serveError(400, "Bad Request", "Invalid Discord webhook URL")
    end
    local share_data = EncodeJson {
        type = kDiscord,
        webhook = webhook,
    }
    return share_data
end

local make_share_data = {
    [kTelegram] = make_telegram_share_data,
    [kDiscord] = make_discord_share_data,
}

local function reformat_telegram_username(name)
    if not name:startswith("@") then
        return "@" .. name
    end
    return name
end

local function reformat_discord_username(name)
    local uid = string.match(name, "(%d%d%d%d+)")
    if uid then
        return "<@" .. uid .. ">"
    end
    return name
end

local reformat_username = {
    [kTelegram] = reformat_telegram_username,
    [kDiscord] = reformat_discord_username,
}

-- Reorganize tags from several lists into a map.
local function reorganize_tags(kind, r)
    local positive_tags = {}
    local negative_tags = {}
    local params_ids_key = kind .. "_ids"
    local fmtstr = "%s_%s_tags_handle_%d"
    if r.params[params_ids_key] then
        for i = 1, #r.params[params_ids_key] do
            local id = tonumber(r.params[params_ids_key][i]) or 0
            local ptag_key = fmtstr:format(kind, "positive", id)
            local ntag_key = fmtstr:format(kind, "negative", id)
            positive_tags[id] =
                table.filter(r.params[ptag_key], WebUtility.not_emptystr)
            negative_tags[id] =
                table.filter(r.params[ntag_key], WebUtility.not_emptystr)
        end
    end
    return positive_tags, negative_tags
end

local function parse_delete_coords(coords)
    for h_idx_str, t_idx_str in coords:gmatch("(%d+),(%d+)") do
        return tonumber(h_idx_str), tonumber(t_idx_str)
    end
    return nil
end

local function rename_entries(
    entries,
    entry_ids,
    entry_handles,
    entry_nicknames
)
    for dbidx = 1, #entries do
        local entry = entries[dbidx]
        for reqidx = 1, #entry_ids do
            local eid = entry_ids[reqidx]
            --Log(kLogDebug, "Does %s match %s?" % {entry.spl_entry_id, eid})
            if tonumber(entry.spl_entry_id) == tonumber(eid) then
                --Log(kLogDebug, "Changing handle for %s to %s..." % {entry.handle, entry_handles[reqidx]})
                entry.handle = entry_handles[reqidx]
                entry.nickname = entry_nicknames[reqidx]
            end
        end
    end
    return entries
end

local function apply_enabled_entries(entries, enabled_ids)
    for dbidx = 1, #entries do
        local entry = entries[dbidx]
        local found = false
        for reqidx = 1, #enabled_ids do
            local eid = enabled_ids[reqidx]
            Log(kLogDebug, "Does %s equal %s?" % { entry.spl_entry_id, eid })
            if tonumber(entry.spl_entry_id) == tonumber(eid) then
                Log(kLogDebug, "Marking %s as enabled..." % { entry.handle })
                found = true
                entry.enabled = true
            end
        end
        if not found then
            entry.enabled = false
        end
    end
    return entries
end

local function accept_add_share_ping_list(
    r,
    _,
    pending_handles,
    pending_nicknames,
    pending_pos,
    pending_neg
)
    if not WebUtility.not_emptystr(r.params.name) then
        return Fm.serveError(400, nil, "Invalid share option name")
    end
    local service = r.params.selected_service
    local valid_service = table.find(SHARE_SERVICES, service)
    if not valid_service then
        return Fm.serveError(
            400,
            nil,
            "Invalid service (must be %s)"
                % { table.concat(SHARE_SERVICES, ", ") }
        )
    end
    local share_data, sd_err = make_share_data[service](r)
    if not share_data then
        return sd_err
    end
    local SP = "add_share_ping_list"
    Model:create_savepoint(SP)
    local spl_id, spl_err = Model:createSharePingList(
        r.params.name,
        share_data,
        r.params.attribution == "true"
    )
    if not spl_id then
        Log(kLogInfo, tostring(spl_err))
        Model:rollback(SP)
        return Fm.serve500()
    end
    for i = 1, #pending_handles do
        local reformatter = reformat_username[service]
        local h_ok, h_err = Model:createSPLEntryWithTags(
            spl_id,
            reformatter(pending_handles[i]),
            pending_nicknames[i],
            pending_pos[i],
            pending_neg[i]
        )
        if not h_ok then
            Log(kLogInfo, tostring(h_err))
            Model:rollback(SP)
            return Fm.serve500()
        end
    end
    Model:release_savepoint(SP)
    return Fm.serveRedirect("/share-ping-list/" .. spl_id)
end

local render_add_share_ping_list = WebUtility.login_required(
    function(r, user_record)
        local redirect = WebUtility.get_post_dialog_redirect(r, "/account")
        if r.params.cancel then
            return redirect
        end
        local alltags, alltags_err = Model:getAllTags()
        if not alltags then
            Log(kLogInfo, alltags_err)
            alltags = {}
        end
        local pending_pos, pending_neg = reorganize_tags("pending", r)
        local pending_handles =
            table.filter(r.params.pending_handles, WebUtility.not_emptystr)
        local pending_nicknames =
            table.filter(r.params.pending_nicknames, WebUtility.not_emptystr)
        if
            #pending_nicknames > 0
            and #pending_handles ~= #pending_nicknames
        then
            return Fm.serveError(
                400,
                "Bad Request",
                "You must provide both a nickname and a handle."
            )
        end
        if
            r.params.dummy_submit
            or r.params.service_reload
            or r.params.add_pending_handle
            or r.params.add_pending_positive_tag
            or r.params.add_pending_negative_tag
        then
        -- Do nothing, handling this happens automatically as part of answering the request.
        elseif r.params.delete_pending_positive_tag then
            local h_idx, t_idx =
                parse_delete_coords(r.params.delete_pending_positive_tag)
            table.remove(pending_pos[h_idx], t_idx)
        elseif r.params.delete_pending_negative_tag then
            local h_idx, t_idx =
                parse_delete_coords(r.params.delete_pending_negative_tag)
            table.remove(pending_neg[h_idx], t_idx)
        elseif r.params.delete_pending_handle then
            local h_idx = tonumber(r.params.delete_pending_handle)
            if not h_idx then
                return Fm.serveError(
                    400,
                    nil,
                    "Invalid number for delete_pending_handle"
                )
            end
            table.remove(pending_handles, h_idx)
            table.remove(pending_nicknames, h_idx)
            table.remove(pending_pos, h_idx)
            table.remove(pending_neg, h_idx)
        elseif r.params.add then
            return accept_add_share_ping_list(
                r,
                user_record,
                pending_handles,
                pending_nicknames,
                pending_pos,
                pending_neg
            )
        end
        local params = {
            alltags = alltags,
            share_services = SHARE_SERVICES,
            name = r.params.name,
            chat_id = r.params.chat_id,
            webhook = r.params.webhook,
            selected_service = r.params.selected_service,
            pending_handles = pending_handles,
            pending_nicknames = pending_nicknames,
            pending_positive_tags = pending_pos,
            pending_negative_tags = pending_neg,
        }
        WebUtility.add_htmx_param(r)
        WebUtility.add_form_path(r, params)
        return Fm.serveContent("share_ping_list_add", params)
    end
)

local function filter_deleted_tags(delete_coords_list, tags_by_entryid_map)
    local result = {}
    local delete_set = {}
    for i = 1, #delete_coords_list do
        local entry_id, tag_id = parse_delete_coords(delete_coords_list[i])
        if not entry_id then
            return Fm.serve400()
        end
        if not tag_id then
            return Fm.serve400()
        end
        if not delete_set[entry_id] then
            delete_set[entry_id] = {}
        end
        delete_set[entry_id][tag_id] = true
    end
    Log(kLogDebug, "delete_set: %s" % { EncodeLua(delete_set) })
    for entry_id, tags in pairs(tags_by_entryid_map) do
        result[entry_id] = table.filter(tags, function(t)
            Log(kLogDebug, "t: %s" % { EncodeJson(t) })
            return not (delete_set[entry_id] and delete_set[entry_id][t.tag_id])
        end)
    end
    return result
end

local function accept_edit_share_ping_list(
    r,
    delete_entry_ids,
    delete_entry_negative_tags,
    delete_entry_positive_tags,
    pending_pos,
    pending_neg,
    entries,
    entry_pos,
    entry_neg,
    pending_handles,
    pending_nicknames
)
    local spl_id = r.params.spl_id
    if not WebUtility.not_emptystr(spl_id) then
        return Fm.serveError(400, nil, "Invalid share option ID")
    end
    if not WebUtility.not_emptystr(r.params.name) then
        return Fm.serveError(400, nil, "Invalid share option name")
    end
    local service = r.params.selected_service
    local valid_service = table.find(SHARE_SERVICES, service)
    if not valid_service then
        return Fm.serveError(
            400,
            nil,
            "Invalid service (must be %s)"
                % { table.concat(SHARE_SERVICES, ", ") }
        )
    end
    local share_data, sd_err = make_share_data[service](r)
    if not share_data then
        return sd_err
    end
    local SP = "edit_share_ping_list"
    Model:create_savepoint(SP)
    local meta_ok, meta_err = Model:updateSharePingListMetadata(
        spl_id,
        r.params.name,
        share_data,
        r.params.attribution == "true"
    )
    if not meta_ok then
        Model:rollback(SP)
        Log(kLogInfo, meta_err)
        return Fm.serve500()
    end
    -- Delete entries first (to cascade-delete their pl_entry_x_tag rows)
    local de_ok, de_err = Model:deleteSPLEntriesById(delete_entry_ids)
    if not de_ok then
        Model:rollback(SP)
        Log(kLogInfo, tostring(de_err))
        return Fm.serve500()
    end
    -- Delete tags next.  If a user deletes a tag and then re-adds it, this order will avoid constraint errors.
    local function delete_map(pair_str)
        return table.pack(parse_delete_coords(pair_str))
    end
    local dptp = table.map(delete_entry_positive_tags, delete_map)
    local dntp = table.map(delete_entry_negative_tags, delete_map)
    local dpt_ok, dpt_err = Model:deletePLPositiveTagsByPair(dptp)
    if not dpt_ok then
        Model:rollback(SP)
        Log(kLogInfo, tostring(dpt_err))
        return Fm.serve500()
    end
    local dnt_ok, dnt_err = Model:deletePLNegativeTagsByPair(dntp)
    if not dnt_ok then
        Model:rollback(SP)
        Log(kLogInfo, tostring(dnt_err))
        return Fm.serve500()
    end
    -- Add pending tags for existing entries.
    local function do_link(model_method, tag_map)
        for spl_entry_id, tag_names in pairs(tag_map) do
            local link_ok, link_err =
                model_method(Model, spl_entry_id, tag_names)
            if not link_ok then
                Model:rollback(SP)
                Log(kLogInfo, tostring(link_err))
                return false
            end
        end
        return true
    end
    if not do_link(Model.linkPositiveTagsToSPLEntryByName, entry_pos) then
        return Fm.serve500()
    end
    if not do_link(Model.linkNegativeTagsToSPLEntryByName, entry_neg) then
        return Fm.serve500()
    end
    -- Add new entries.
    local reformatter = reformat_username[service]
    for i = 1, #pending_handles do
        local h_ok, h_err = Model:createSPLEntryWithTags(
            spl_id,
            reformatter(pending_handles[i]),
            pending_nicknames[i],
            pending_pos[i],
            pending_neg[i]
        )
        if not h_ok then
            Log(kLogInfo, tostring(h_err))
            Model:rollback(SP)
            return Fm.serve500()
        end
    end
    -- Update existing entries.
    for i = 1, #entries do
        local entry = entries[i]
        local u_ok, u_err = Model:updateSharePingListEntry(
            entry.spl_entry_id,
            reformatter(entry.handle),
            entry.nickname,
            entry.enabled
        )
        if not u_ok then
            Log(kLogInfo, tostring(u_err))
            Model:rollback(SP)
            return Fm.serve500()
        end
    end
    Model:release_savepoint(SP)
    return Fm.serveRedirect("/share-ping-list/" .. spl_id)
end

local render_edit_share_ping_list = WebUtility.login_required(function(r, _)
    local redirect = WebUtility.get_post_dialog_redirect(
        r,
        "/share-ping-list/" .. r.params.spl_id
    )
    if r.params.cancel then
        return redirect
    end
    local spl, spl_err = Model:getSharePingListById(r.params.spl_id)
    if not spl then
        Log(kLogInfo, tostring(spl_err))
        return Fm.serveError(400, nil, "Invalid share option ID")
    end
    local entries, positive_tags, negative_tags =
        Model:getEntriesForSPLById(r.params.spl_id)
    if not entries then
        return Fm.serve500()
    end
    local alltags, alltags_err = Model:getAllTags()
    if not alltags then
        Log(kLogInfo, alltags_err)
        alltags = {}
    end
    local delete_entry_ids = r.params.delete_entry_ids or {}
    local delete_entry_negative_tags = r.params.delete_entry_negative_tags or {}
    local delete_entry_positive_tags = r.params.delete_entry_positive_tags or {}
    local pending_pos, pending_neg = reorganize_tags("pending", r)
    Log(
        kLogDebug,
        "pending_pos; pending_neg: %s; %s"
            % { EncodeLua(pending_pos), EncodeLua(pending_neg) }
    )
    local entry_pos, entry_neg = reorganize_tags("entry", r)
    local entry_ids = table.filter(r.params.entry_ids, WebUtility.not_emptystr)
    local entry_handles =
        table.filter(r.params.entry_handles, WebUtility.not_emptystr)
    local entry_nicknames =
        table.filter(r.params.entry_nicknames, WebUtility.not_emptystr)
    local entry_enabled =
        table.filter(r.params.enable_entry_handles, WebUtility.not_emptystr)
    --Log(kLogDebug, "entry_handles: %s; entry_nicknames: %s" % {EncodeJson(entry_handles), EncodeJson(entry_nicknames)})
    local pending_handles =
        table.filter(r.params.pending_handles, WebUtility.not_emptystr)
    local pending_nicknames =
        table.filter(r.params.pending_nicknames, WebUtility.not_emptystr)
    entries = rename_entries(entries, entry_ids, entry_handles, entry_nicknames)
    if #entry_enabled > 0 then
        entries = apply_enabled_entries(entries, entry_enabled)
    end
    if
        r.params.dummy_submit
        or r.params.service_reload
        or r.params.add_pending_handle
        or r.params.add_pending_positive_tag
        or r.params.add_pending_negative_tag
        or r.params.add_entry_positive_tag
        or r.params.add_entry_negative_tag
    then
        -- Do nothing, handling this happens automatically as part of answering the request.
    elseif r.params.delete_pending_positive_tag then
        local h_idx, t_idx =
            parse_delete_coords(r.params.delete_pending_positive_tag)
        table.remove(pending_pos[h_idx], t_idx)
    elseif r.params.delete_pending_negative_tag then
        local h_idx, t_idx =
            parse_delete_coords(r.params.delete_pending_negative_tag)
        table.remove(pending_neg[h_idx], t_idx)
    elseif r.params.delete_entry_positive_tag then
        local h_idx, t_idx =
            parse_delete_coords(r.params.delete_entry_positive_tag)
        table.remove(entry_pos[h_idx], t_idx)
    elseif r.params.delete_entry_negative_tag then
        local h_idx, t_idx =
            parse_delete_coords(r.params.delete_entry_negative_tag)
        table.remove(entry_neg[h_idx], t_idx)
    elseif r.params.delete_pending_handle then
        local h_idx = tonumber(r.params.delete_pending_handle)
        if not h_idx then
            return Fm.serveError(
                400,
                nil,
                "Invalid number for delete_pending_handle"
            )
        end
        table.remove(pending_handles, h_idx)
        table.remove(pending_nicknames, h_idx)
        table.remove(pending_pos, h_idx)
        table.remove(pending_neg, h_idx)
    elseif r.params.delete_positive_tag then
        delete_entry_positive_tags[#delete_entry_positive_tags + 1] =
            r.params.delete_positive_tag
    elseif r.params.delete_negative_tag then
        delete_entry_negative_tags[#delete_entry_negative_tags + 1] =
            r.params.delete_negative_tag
    elseif r.params.delete_entry_handle then
        local entry_id = tonumber(r.params.delete_entry_handle)
        if not entry_id then
            return Fm.serveError(
                400,
                nil,
                "Invalid number for delete_entry_handle"
            )
        end
        delete_entry_ids[#delete_entry_ids + 1] = entry_id
        -- Deleting from the output lists is handled below.
    elseif r.params.add then
        return accept_edit_share_ping_list(
            r,
            delete_entry_ids,
            delete_entry_negative_tags,
            delete_entry_positive_tags,
            pending_pos,
            pending_neg,
            entries,
            entry_pos,
            entry_neg,
            pending_handles,
            pending_nicknames
        )
    end
    -- "Delete" (hide) database records for handles from next rendered page.
    local delete_entry_ids_set = {}
    for idx = 1, #delete_entry_ids do
        local entry_id = delete_entry_ids[idx]
        positive_tags[entry_id] = nil
        negative_tags[entry_id] = nil
        delete_entry_ids_set[entry_id] = true
    end
    entries = table.filter(entries, function(i)
        return not delete_entry_ids_set[i.spl_entry_id]
    end)
    Log(kLogDebug, "entries after filter: %s" % { EncodeJson(entries) })
    -- "Delete" (hide) database records for tags from next rendered page.
    positive_tags =
        filter_deleted_tags(delete_entry_positive_tags, positive_tags)
    negative_tags =
        filter_deleted_tags(delete_entry_negative_tags, negative_tags)
    local attribution = r.params.attribution or spl.send_with_attribution
    Log(kLogInfo, "attribution: " .. tostring(attribution))
    -- Render page.
    local params = {
        alltags = alltags,
        spl = spl,
        entries = entries,
        positive_tags = positive_tags,
        negative_tags = negative_tags,
        attribution = attribution,
        share_services = SHARE_SERVICES,
        name = r.params.name or spl.name,
        chat_id = r.params.chat_id or spl.share_data.chat_id,
        webhook = r.params.webhook or spl.share_data.webhook,
        selected_service = r.params.selected_service or spl.share_data.type,
        pending_handles = pending_handles,
        pending_nicknames = pending_nicknames,
        pending_positive_tags = pending_pos,
        pending_negative_tags = pending_neg,
        entry_positive_tags = entry_pos,
        entry_negative_tags = entry_neg,
        delete_entry_ids = delete_entry_ids,
        delete_entry_positive_tags = delete_entry_positive_tags,
        delete_entry_negative_tags = delete_entry_negative_tags,
    }
    WebUtility.add_htmx_param(r)
    WebUtility.add_form_path(r, params)
    return Fm.serveContent("share_ping_list_edit", params)
end)

local render_share_ping_list = WebUtility.login_required(function(r, _)
    local share_ping_list, spl_err = Model:getSharePingListById(r.params.spl_id)
    if not share_ping_list then
        return Fm.serve404()
    end
    Log(kLogInfo, "r.params.delete = " .. tostring(r.params.delete))
    if r.params.delete == "Delete" then
        local d_ok, d_err = Model:deleteSharePingList(r.params.spl_id)
        if not d_ok then
            Log(
                kLogInfo,
                "Error while trying to delete share option: " .. d_err
            )
            return Fm.serve500()
        else
            return Fm.serveRedirect(302, "/account")
        end
    end
    local entries, positive_tags, negative_tags =
        Model:getEntriesForSPLById(r.params.spl_id)
    if not entries then
        return Fm.serve500()
    end
    return Fm.serveContent("share_ping_list", {
        share_ping_list = share_ping_list,
        share_services = SHARE_SERVICES,
        entries = entries,
        positive_tags = positive_tags,
        negative_tags = negative_tags,
        form_action = r.path,
    })
end)

local function setup()
    Fm.setRoute("/image/:image_id[%d]/share", render_image_share)
    Fm.setRoute("/image-group/:ig_id[%d]/share", render_image_group_share)
    Fm.setRoute("/share-ping-list/add", render_add_share_ping_list)
    Fm.setRoute("/share-ping-list/:spl_id[%d]", render_share_ping_list)
    Fm.setRoute(
        "/share-ping-list/:spl_id[%d]/edit",
        render_edit_share_ping_list
    )
end

return {
    setup = setup,
    share_services = SHARE_SERVICES,
}

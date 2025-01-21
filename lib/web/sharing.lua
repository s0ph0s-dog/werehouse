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
    local chat_id = (spl and spl.share_data.chat_id) or tg_userid
    local share_ok, share_err = Bot.share_media(chat_id, images, ping_text)
    if not share_ok then
        return Fm.serveError(400, nil, share_err)
    end
    return Fm.serveRedirect(redir_url, 302)
end

--- Prepare the default data shown in the share form.
local function prep_form_data(r, user_record, group, images, data, getPings)
    local ping_data, pd_err = {}, nil
    if data.spl then
        ping_data, pd_err = getPings(data.spl.spl_id)
        if not ping_data then
            Log(kLogInfo, pd_err)
            return Fm.serve500()
        end
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
            sources_text = image.sources[1].link
        else
            sources_text = table.concat(
                table.map(image.sources, function(s)
                    return string.format("• %s", s.link)
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
    -- local form_sources_text = r.params.sources_text
    local form_ping_text = r.params.ping_text or ping_text
    local param_attribution = r.params.attribution
        or (data.spl and data.spl.send_with_attribution)
    local params = {
        group = group,
        ig_id = r.params.ig_id,
        image_id = r.params.image_id,
        images = images,
        share_ping_list = data.spl,
        attribution = param_attribution,
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

local function setup()
    Fm.setRoute("/image/:image_id[%d]/share", render_image_share)
    Fm.setRoute("/image-group/:ig_id[%d]/share", render_image_group_share)
end

return {
    setup = setup,
}

local function render_invite(r)
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        return 404
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
        return 404
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
        return 400
    end
    Log(kLogInfo, "Registration success!")
    return Fm.serveRedirect("/login", 302)
end

local function render_login(r)
    return Fm.serveContent("login", { error = r.session.error })
end

local function login_required(handler)
    return function(r)
        if not r.session.token then
            return Fm.serve401()
        end
        local session, errmsg = Accounts:findSessionById(r.session.token)
        if not session then
            Log(kLogDebug, errmsg)
            return Fm.serve401()
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
    return Fm.serveRedirect("/home", 302)
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
    elseif allowed_image_types[r.headers["Content-Type"]] then
        local result, errmsg =
            Model:enqueueImage(r.headers["Content-Type"], r.body)
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
    return Fm.serveContent("image", {
        user = user_record,
        image = image,
        artists = artists,
        tags = tags,
        sources = sources,
    })
end)

local function setup()
    Fm.setTemplate { "/templates/", html = "fmt" }
    Fm.setRoute("/favicon.ico", Fm.serveAsset)
    Fm.setRoute("/style.css", Fm.serveAsset)
    -- User-facing routes
    Fm.setRoute(Fm.GET { "/accept-invite/:invite_code" }, render_invite)
    Fm.setRoute(
        Fm.POST { "/accept-invite/:invite_code", _ = invite_validator },
        accept_invite
    )
    Fm.setRoute(Fm.GET { "/login" }, render_login)
    Fm.setRoute(Fm.POST { "/login", _ = login_validator }, accept_login)
    Fm.setRoute("/home", render_home)
    Fm.setRoute("/image-file/:filename", render_image_file)
    Fm.setRoute("/image/:image_id", render_image)
    Fm.setRoute(Fm.GET { "/enqueue" }, render_enqueue)
    Fm.setRoute(Fm.POST { "/enqueue" }, accept_enqueue)
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

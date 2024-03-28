
local function render_invite(r)
    if not r.params.invite_code then
        return 404
    end
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        return 404
    end
    return Fm.render("accept_invite", { invite_record = invite_record })
end

local invite_validator = Fm.makeValidator{
    {"username", minlen = 2, maxlen = 128, msg = "%s must be between 2 and 128 characters"},
    {"password", minlen = 16, maxlen = 128, msg = "%s must be between 16 and 128 characters"},
    {"password_confirm", minlen = 16, maxlen = 128, msg = "%s must be between 16 and 128 characters"},
    all = true,
}

local login_validator = Fm.makeValidator{
    {"username", minlen = 2, maxlen = 128, msg = "%s must be between 2 and 128 characters"},
    {"password", minlen = 16, maxlen = 128, msg = "%s must be between 16 and 128 characters"},
    all = true,
}

local function accept_invite(r)
    if not r.params.invite_code then
        Log(kLogInfo, "No invite code in URL")
        return 404
    end
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        Log(kLogInfo, "No invite records in database for %s" % {r.params.invite_code})
        return 404
    end
    if r.params.password ~= r.params.password_confirm then
        -- TODO: password mismatch
        Log(kLogInfo, "Passwords did not match")
        return 400
    end
    local pw_hash = argon2.hash_encoded(r.params.password, GetRandomBytes(32), {
        m_cost = 65536,
        parallelism = 4,
    })
    local result, errmsg = Accounts:acceptInvite(r.params.invite_code, r.params.username, pw_hash)
    print(result)
    if not result then
        Log(kLogInfo, "Invitation acceptance failed: %s" % {errmsg})
        return 400
    end
    Log(kLogInfo, "Registration success!")
    return Fm.serveRedirect("/login", 302)
end

local function render_login(r)
    return Fm.serveContent("login", { error = r.session.error })
end

local function accept_login(r)
    local user_record, errmsg = Accounts:findUser(r.params.username)
    if not user_record then
        -- Resist timing-based oracle attack for username discovery.
        argon2.verify("foobar", r.params.password)
        r.session.error = "Invalid credentials"
        return Fm.serveRedirect("/login", 302)
    end
    if not argon2.verify(user_record.password, r.params.password) then
        r.session.error = "Invalid credentials"
        return Fm.serveRedirect("/login", 302)
    end
    local session_id, errmsg = Accounts:createSessionForUser(user_record.user_id)
    if not session_id then
        r.session.error = errmsg
        return Fm.serveRedirect("/login", 302)
    end
    r.cookies.session = {
        session_id,
        samesite = "Strict",
        httponly = true,
    }
    return Fm.serveRedirect("/home", 302)
end

local function setup()
    Fm.setTemplate({"/templates/", html = "fmt"})
    Fm.setRoute("/favicon.ico", Fm.serveAsset)
    -- User-facing routes
    Fm.setRoute(Fm.GET{"/accept-invite/:invite_code"}, render_invite)
    Fm.setRoute(Fm.POST{"/accept-invite/:invite_code", _ = invite_validator}, accept_invite)
    Fm.setRoute(Fm.GET{"/login"}, Fm.serveContent("login"))
    Fm.setRoute(Fm.POST{"/login", _ = login_validator}, accept_login)
    Fm.setRoute("/home", function (r) return "todo: put something useful here" end)
    -- API routes
    -- Fm.setRoute("/api/telegram-webhook")
    -- Fm.setRoute("/api/enqueue")
end

local function run()
    return Fm.run()
end

return {
    setup = setup,
    run = run
}

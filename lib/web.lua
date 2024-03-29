
local function render_invite(r)
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        return 404
    end
    return Fm.render("accept_invite", { error = r.session.error, invite_record = invite_record })
end

local username_validator_rule =  {"username", minlen = 2, maxlen = 128, msg = "%s must be between 2 and 128 characters"}
local password_validator_rule = {"password", minlen = 16, maxlen = 128, msg = "%s must be between 16 and 128 characters"}
local invite_validator_rule = {"invite_code", minlen = 36, maxlen = 36}

local invite_validator = Fm.makeValidator{
    invite_validator_rule,
    username_validator_rule,
    password_validator_rule,
    {"password_confirm", minlen = 16, maxlen = 128, msg = "%s must be between 16 and 128 characters"},
    all = true,
}

local login_validator = Fm.makeValidator{
    username_validator_rule,
    password_validator_rule,
    all = true,
}

local function accept_invite(r)
    r.session.error = nil
    local invite_record = Accounts:findInvite(r.params.invite_code)
    if not invite_record then
        Log(kLogInfo, "No invite records in database for %s" % {r.params.invite_code})
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

local function login_required(handler)
    return function (r)
        if not r.session.token then
            return Fm.serve401()
        end
        local session, errmsg = Accounts:findSessionById(r.session.token)
        if not session then
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
    r.session.token = session_id
    return Fm.serveRedirect("/home", 302)
end

local function setup()
    Fm.setTemplate({"/templates/", html = "fmt"})
    Fm.setRoute("/favicon.ico", Fm.serveAsset)
    -- User-facing routes
    Fm.setRoute(Fm.GET{"/accept-invite/:invite_code"}, render_invite)
    Fm.setRoute(Fm.POST{"/accept-invite/:invite_code", _ = invite_validator}, accept_invite)
    Fm.setRoute(Fm.GET{"/login"}, render_login)
    Fm.setRoute(Fm.POST{"/login", _ = login_validator}, accept_login)
    Fm.setRoute("/home", login_required(function (r) return "todo: put something useful here" end))
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

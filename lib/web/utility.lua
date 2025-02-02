local COOKIE_HASH = "SHA256"
local COOKIE_FORMAT = "%s.%s.%s"
local COOKIE_PATTERN = "(.-)%.(.-)%.(.+)"
local COOKIE_NAME = "__Host-login"
local COOKIE_OPTIONS = {
    Path = "/",
    Secure = true,
    HttpOnly = true,
    SameSite = "Strict",
}
-- TODO: align this more closely with Fullmoon's session key when the env var is unset
local COOKIE_KEY = DecodeBase64(os.getenv("SESSION_KEY") or "")

local function get_client_ip(r)
    local ip = r.headers["X-Forwarded-For"]
    if not ip then
        local ip_raw = GetClientAddr()
        ip = FormatIp(ip_raw)
    end
    return ip
end

local function set_login_cookie(r, value)
    local signature =
        EncodeBase64(GetCryptoHash(COOKIE_HASH, value, COOKIE_KEY))
    local cookie_value = COOKIE_FORMAT:format(value, COOKIE_HASH, signature)
    if value then
        local max_age = unix.clock_gettime() + SESSION_MAX_DURATION_SECS
        r.cookies[COOKIE_NAME] = {
            cookie_value,
            maxage = max_age,
            path = COOKIE_OPTIONS.Path,
            secure = COOKIE_OPTIONS.Secure,
            httponly = COOKIE_OPTIONS.HttpOnly,
            samesite = COOKIE_OPTIONS.SameSite,
        }
        Log(kLogDebug, "set login cookie to %s" % { cookie_value })
    end
end

local function get_login_cookie(r)
    local cookie_value = r.cookies[COOKIE_NAME]
    if not cookie_value then
        Log(kLogDebug, "No login cookie")
        return nil
    end
    local value, hash_type, signature = cookie_value:match(COOKIE_PATTERN)
    if not value then
        return nil
    end
    if hash_type ~= COOKIE_HASH or not pcall(GetCryptoHash, hash_type, "") then
        Log(kLogWarn, "invalid login cookie hash type")
        return nil
    end
    if
        DecodeBase64(signature) ~= GetCryptoHash(COOKIE_HASH, value, COOKIE_KEY)
    then
        Log(kLogWarn, "invalid login cookie signature")
        return nil
    end
    return value
end

local function login_optional(handler)
    return function(r)
        local token = get_login_cookie(r)
        local user_record, user_err = nil, nil
        Log(kLogInfo, "session token: %s" % { EncodeJson(token) })
        if token then
            local session, errmsg = Accounts:findSessionById(token)
            if session then
                local ip = get_client_ip(r)
                local u_ok, u_err =
                    Accounts:updateSessionLastSeenToNow(token, ip)
                if not u_ok then
                    Log(kLogInfo, u_err)
                end
                Model = DbUtil.Model:new(nil, session.user_id)
                user_record, user_err = Accounts:findUserBySessionId(token)
                if not user_record then
                    Log(kLogDebug, user_err)
                    return Fm.serve500()
                end
                Fm.setTemplateVar("toast", r.session.toast)
                Fm.setTemplateVar("user", user_record)
                r.session.toast = nil
            else
                Log(kLogInfo, tostring(errmsg))
            end
        end
        return handler(r, user_record)
    end
end

local function login_required(handler)
    return function(r)
        local token = get_login_cookie(r)
        Log(kLogInfo, "session token: %s" % { EncodeJson(token) })
        if not token then
            r.session.after_login_url = r.path
            return Fm.serveRedirect("/login", 302)
        end
        local session, errmsg = Accounts:findSessionById(token)
        if not session then
            Log(kLogDebug, errmsg)
            r.session.after_login_url = r.url
            return Fm.serveRedirect("/login", 302)
        end
        local ip = get_client_ip(r)
        local u_ok, u_err = Accounts:updateSessionLastSeenToNow(token, ip)
        if not u_ok then
            Log(kLogInfo, u_err)
        end
        Model = DbUtil.Model:new(nil, session.user_id)
        local user_record, user_err = Accounts:findUserBySessionId(token)
        if not user_record then
            Log(kLogDebug, user_err)
            return Fm.serve500()
        end
        Fm.setTemplateVar("toast", r.session.toast)
        Fm.setTemplateVar("user", user_record)
        r.session.toast = nil
        return handler(r, user_record)
    end
end

local function add_form_path(r, params)
    params.form_path = r.path
end

local function add_htmx_param(r)
    local hx_header = r.headers["HX-Request"]
    if hx_header and hx_header == "true" then
        Fm.setTemplateVar("hx", true)
    end
end

local function not_emptystr(x)
    return x and #x > 0
end

local function get_post_dialog_redirect(r, default)
    local redirect_url = r.headers["Referer"]
        or r.headers["HX-Current-URL"]
        or r.session.after_dialog_action
        or default
    redirect_url = redirect_url:gsub("/edit$", "")
    Log(kLogDebug, "Redirecting to %s after this dialog" % { redirect_url })
    return Fm.serveRedirect(redirect_url, 302)
end

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
    kind = DbUtil.k.ImageKind,
}

return {
    login_required = login_required,
    login_optional = login_optional,
    add_form_path = add_form_path,
    add_htmx_param = add_htmx_param,
    image_functions = image_functions,
    not_emptystr = not_emptystr,
    get_post_dialog_redirect = get_post_dialog_redirect,
}

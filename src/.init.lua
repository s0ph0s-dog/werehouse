Sqlite3 = require("lsqlite3")
NanoID = require("nanoid")
Fm = require("third_party.fullmoon")
DbUtil = require("db")
Nu = require("network_utils")
HtmlParser = require("third_party.htmlparser")
Multipart = require("third_party.multipart")
FsTools = require("fstools")
local about = require("about")
local web = require("web")
local _ = require("functools")
ScraperPipeline = require("scraper_pipeline")
Bot = require("tg_bot")
GifTools = require("giftools")

local session_key = os.getenv("SESSION_KEY")
if session_key then
    Fm.sessionOptions.secret = Fm.decodeBase64()
end

ServerVersion = string.format(
    "%s/%s; redbean/%s",
    about.NAME,
    about.VERSION,
    about.REDBEAN_VERSION
)

IdPrefixes = {
    user = "u_",
    session = "s_",
    csrf = "csrf_",
    invite = "i_",
    telegram_link_request = "tglr_",
}

ProgramContentType("webmanifest", "application/manifest+json")

Accounts = DbUtil.Accounts:new()
Accounts:bootstrapInvites()

local function sessionMaintenance()
    return Accounts:sessionMaintenance()
end

function OnWorkerStart()
    Accounts = DbUtil.Accounts:new()

    unix.setrlimit(unix.RLIMIT_AS, 100 * 1024 * 1024)
    unix.setrlimit(unix.RLIMIT_CPU, 2)

    assert(unix.unveil(".", "rwc"))
    assert(unix.unveil("/etc", "r"))
    assert(unix.unveil(nil, nil))
end
function OnWorkerStop()
    if Accounts then
        Accounts.conn:close()
    end
    if Model then
        Model.conn:close()
    end
end
-- 10MB, a reasonable limit for images.
ProgramMaxPayloadSize(10 * 1024 * 1024)

Fm.setSchedule("* * * * *", ScraperPipeline.process_all_queues)
Fm.setSchedule("50 * * * *", sessionMaintenance)

Bot.setup(os.getenv("TG_BOT_TOKEN"), true, ScraperPipeline.can_process_uri)
Bot.run()

web.setup()
web.run()

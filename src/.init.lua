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
Ris = require("reverse_image_search")
ScraperPipeline = require("scraper_pipeline")
Bot = require("tg_bot")
GifTools = require("giftools")

local session_key = os.getenv("SESSION_KEY")
Fm.sessionOptions.name = "__Host-session"
if session_key then
    Fm.sessionOptions.secret = Fm.decodeBase64()
end
Fm.cookieOptions.httponly = true
Fm.cookieOptions.secure = true
Fm.cookieOptions.samesite = "Strict"
Fm.cookieOptions.path = "/"

SESSION_MAX_DURATION_SECS = 30 * 24 * 60 * 60

ServerVersion = string.format(
    "%s/%s; redbean/%s",
    about.NAME,
    about.VERSION,
    about.REDBEAN_VERSION
)

ProgramBrand(ServerVersion)

ProgramContentType("webmanifest", "application/manifest+json")
ProgramCache(60 * 60 * 24 * 365, "private")

Accounts = DbUtil.Accounts:new()
Accounts:bootstrapInvites()

local function sessionMaintenance()
    return Accounts:sessionMaintenance()
end

local function deletedFileCleanup()
    return DbUtil.remove_deleted_files()
end

function OnWorkerStart()
    Accounts = DbUtil.Accounts:new()

    unix.setrlimit(unix.RLIMIT_AS, 200 * 1024 * 1024)
    unix.setrlimit(unix.RLIMIT_CPU, 4)

    assert(unix.unveil(".", "rwc"))
    assert(unix.unveil("/tmp", "rwc"))
    assert(unix.unveil("/var/tmp", "rwc"))
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
Fm.setSchedule("25 * * * *", deletedFileCleanup)

Bot.setup(os.getenv("TG_BOT_TOKEN"), false, ScraperPipeline.can_process_uri)
Bot.run()

web.setup()
web.run()

Sqlite3 = require("lsqlite3")
Uuid = require("third_party.uuid")
Fm = require("third_party.fullmoon")
DbUtil = require("db")
Nu = require("network_utils")
HtmlParser = require("third_party.htmlparser")
Multipart = require("third_party.multipart")
local about = require("about")
local web = require("web")
local _ = require("functools")
local scraper_pipeline = require("scraper_pipeline")
local bot = require("tg_bot")

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
local function reseedUuid()
    local seed_str = GetRandomBytes(4)
    -- Lua has no bit shift operators, so multiplication by powers of two will do.
    local seed_int = (string.byte(seed_str, 1) * (2 ^ 24))
        + (string.byte(seed_str, 2) * (2 ^ 16))
        + (string.byte(seed_str, 3) * (2 ^ 8))
        + string.byte(seed_str, 4)
    Uuid.randomseed(seed_int)
end

reseedUuid()

Accounts = DbUtil.Accounts:new()
Accounts:bootstrapInvites()

function OnWorkerStart()
    Accounts = DbUtil.Accounts:new()

    unix.setrlimit(unix.RLIMIT_AS, 20 * 1024 * 1024)
    unix.setrlimit(unix.RLIMIT_CPU, 2)

    assert(unix.unveil(".", "rw"))
    assert(unix.unveil(nil, nil))
    reseedUuid()
end
-- 10MB, a reasonable limit for images.
ProgramMaxPayloadSize(10 * 1024 * 1024)

Fm.setSchedule("* * * * *", scraper_pipeline.process_all_queues)

bot.setup(os.getenv("TG_BOT_TOKEN"), true)
bot.run()

web.setup()
web.run()

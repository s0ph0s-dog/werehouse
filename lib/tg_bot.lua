local api = require("telegram_lib")

function handle_start(message)
    local user_record, user_err =
        Accounts:findUserByTelegramUserID(message.from.id)
    if user_err then
        Log(kLogInfo, user_err)
        return
    end
    if user_record and user_record.username then
        api.send_message(
            message,
            "You've connected this Telegram account to the user "
                .. user_record.username
        )
        return
    end
    local request_id = Uuid()
    local display_name = "%s %s"
        % { message.from.first_name, message.from.last_name }
    local insert_ok, insert_err = Accounts:addTelegramLinkRequest(
        request_id,
        display_name,
        message.from.username,
        message.from.id
    )
    if not insert_ok then
        Log(kLogInfo, insert_err)
        api.send_message(
            message,
            "I encountered a database error while trying to do that. Please try again later."
        )
        return
    end
    local response = [[Hello! To get started with this bot, please connect your account: http://127.0.0.1:8082/link-telegram/%s. This link expires after 30 minutes.

If you don't have an account already, this bot only works with an invite-only service. You'll have to be invited by someone else who has an account.]] % {
        request_id,
    }
    api.send_message(message, response)
end

function api.on_message(message)
    if message.text then
        if message.chat.type == "private" and message.text == "/start" then
            handle_start(message)
        end
    end
end

local bot = {}

function bot.setup(token, debug)
    bot.api = api.configure(token, debug)
end

function bot.run()
    local pid = unix.fork()
    if pid == 0 then
        api.run(10)
    else
        return pid
    end
end

return bot

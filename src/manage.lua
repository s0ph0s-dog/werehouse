Sqlite3 = require("lsqlite3")
NanoID = require("nanoid")
Fm = require("third_party.fullmoon")
FsTools = require("fstools")
local DbUtil = require("db")

local function help()
    print("usage: ./hyperphantasia.com -i /zip/manage.lua <COMMAND> [options]")
    print("<COMMAND> can be:")
    print(
        "- db_migrate (-d): migrate all database files to the lastest schemas."
    )
    print(
        "              -d   dry-run mode (do not actually change the database)"
    )
    print(
        "- update_image_sizes (-d): check every user's database against the image"
    )
    print(
        "                           files saved on disk. Update rows with no size,"
    )
    print("                           or with an incorrect size.")
    print(
        "                      -d   dry-run mode (don't write changes, just report changes"
    )
end

local function db_migrate(other_args)
    local migrate_opts = {
        delete = true,
        dryrun = other_args[1] == "-d",
        integritycheck = true,
    }
    print("Running with options: %s" % { EncodeJson(migrate_opts) })
    local accounts = DbUtil.Accounts:new()
    print("Migrating accounts database… ")
    local a_changes, a_err = accounts:migrate(migrate_opts)
    if not a_changes then
        print("Failed :(")
        print(a_err)
        return 1
    end
    print(EncodeJson(a_changes))
    print("Done!")
    local users, users_err = accounts:getAllUserIds()
    accounts.conn:close()
    if not users then
        print(users_err)
        return 1
    end
    for i = 1, #users do
        local user = users[i]
        print(
            "Migrating user database for %s (%d of %d)…"
                % { user.user_id, i, #users }
        )
        local model = DbUtil.Model:new(nil, user.user_id)
        local m_ok, m_err = model:migrate(migrate_opts)
        model.conn:close()
        if not m_ok then
            print("Failed :(")
            print(m_err)
            return 1
        end
        print("Done!")
    end
    print("All migrations completed.")
    return 0
end

local function update_image_sizes(other_args)
    local dry_run = other_args[1] == "-d"
    local accounts = DbUtil.Accounts:new()
    local users, users_err = accounts:getAllUserIds()
    accounts.conn:close()
    if not users then
        print(users_err)
        return 1
    end
    for i = 1, #users do
        local user = users[i]
        print(
            "Checking images for user %s (%d of %d)…"
                % { user.user_id, i, #users }
        )
        local model = DbUtil.Model:new(nil, user.user_id)
        local images, images_err = model:getAllImagesForSizeCheck()
        if not images then
            print("Failed :(")
            print(images_err)
            return 1
        end
        local update_count = 0
        for j = 1, #images do
            local image = images[j]
            if j % 50 == 1 then
                print("Checking image %d of %d…" % { j, #images })
            end
            local _, image_path =
                FsTools.make_image_path_from_filename(image.file)
            local image_stat = unix.stat(image_path)
            if not image_stat then
                Log(
                    kLogWarn,
                    "Image %s referenced in database for user %s does not exist on disk at %s"
                        % { image.file, user.user_id, image_path }
                )
            else
                -- Using file length, not blocks-on-disk size.
                local size = image_stat:size()
                if size ~= image.file_size then
                    -- print("DB says %s, file is %d" % {tostring(image.file_size), size})
                    update_count = update_count + 1
                    if not dry_run then
                        local update, update_err =
                            model:updateImageSize(image.image_id, size)
                        if not update then
                            print(
                                "Failed on image_id %d :(" % { image.image_id }
                            )
                            print(update_err)
                            return 1
                        end
                    end
                end
            end
        end
        print("Updated %d images for user %s" % { update_count, user.user_id })
        if dry_run then
            print("(but not really because this is a dry run)")
        end
        model.conn:close()
    end
end

local commands = {
    db_migrate = db_migrate,
    update_image_sizes = update_image_sizes,
}

local remaining_args = arg

local COMMAND_VERB = remaining_args[1]
table.remove(remaining_args, 1)
if COMMAND_VERB == "--" then
    COMMAND_VERB = remaining_args[1]
    table.remove(remaining_args, 1)
end

if not COMMAND_VERB then
    help()
    os.exit(1)
end

os.exit(commands[COMMAND_VERB](remaining_args))

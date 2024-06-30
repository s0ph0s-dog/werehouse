Sqlite3 = require("lsqlite3")
NanoID = require("nanoid")
Fm = require("third_party.fullmoon")
FsTools = require("fstools")
local DbUtil = require("db")
local _ = require("functools")

local function help()
    print("usage: ./werehouse.com -i /zip/manage.lua <COMMAND> [options]")
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
    print(
        "- import_tags <db_filename>: read one tag per line from stdin and insert into the database file listed."
    )
    print(
        "- make_invite <username>: Generate a new invite link with the specified user marked as the inviter."
    )
    print(
        "- hash: After migrating the database to include the hash tables, use this to fill them in."
    )
    print(
        "- thumbnail: Create properly-sized WebP thumbnails for every image that doesn't have one."
    )
end

local function for_each_user(fn)
    local accounts = DbUtil.Accounts:new()
    local users, users_err = accounts:getAllUserIds()
    accounts.conn:close()
    if not users then
        error(users_err)
        return nil
    end
    for i = 1, #users do
        local user = users[i]
        print(
            "Checking records for user %s (%d of %d)…"
                % { user.user_id, i, #users }
        )
        local model = DbUtil.Model:new(nil, user.user_id)
        local rc = fn(i, user, model)
        model.conn:close()
        if rc ~= 0 then
            return rc
        end
    end
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
    for_each_user(function(i, user, model)
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
                print("Checking record %d of %d…" % { j, #images })
            end
            local _, image_path =
                FsTools.make_image_path_from_filename(image.file)
            local image_stat = unix.stat(image_path)
            if not image_stat then
                Log(
                    kLogWarn,
                    "Record %s referenced in database for user %s does not exist on disk at %s"
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
    end)
end

local function import_tags(other_args)
    local db = Sqlite3.open(other_args[1])

    local insert =
        [[INSERT INTO "tags" ("name", "description") VALUES (?, '');]]
    local insert_stmt = db:prepare(insert)

    db:exec([[PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout = 5000;
        PRAGMA synchronous=NORMAL;
        PRAGMA foreign_keys=ON;
        BEGIN;]])

    local line = io.stdin:read("l*")
    while line do
        local line_clean = line:strip()
        insert_stmt:reset()
        insert_stmt:bind_values(line_clean)
        local step_result = insert_stmt:step()
        if step_result ~= Sqlite3.DONE then
            db:exec([[ROLLBACK;]])
            print(step_result, db:errmsg())
        end
        line = io.stdin:read("l*")
    end

    db:exec([[COMMIT;]])
    insert_stmt:finalize()
    db:close_vm()
    db:close()
end

local function make_invite(other_args)
    local username = other_args[1]
    if not username then
        help()
        return 1
    end
    local accounts = DbUtil.Accounts:new()
    local user, u_err = accounts:findUser(username)
    if not user then
        print("Unable to find user: " .. u_err)
        return 1
    end
    local invite_ok, invite_err = accounts:makeInviteForUser(user.user_id)
    if not invite_ok then
        print("Unable to create invite: " .. invite_err)
        return 1
    end
    print("Invite created! Tell the user to check their /account page.")
    accounts.conn:close()
    return 0
end

local function hash(other_args)
    local dry_run = other_args[1] == "-d"
    if not img then
        print(
            "This Redbean wasn't compiled with the img library. Please check the installation documentation."
        )
        return 1
    end
    for_each_user(function(i, user, model)
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
                print("Checking record %d of %d…" % { j, #images })
            end
            local _, image_path =
                FsTools.make_image_path_from_filename(image.file)
            local imageu8, load_err = img.loadfile(image_path)
            if not imageu8 then
                print("failed on image_id %d" % { image.image_id })
                print(load_err)
            else
                local hash = imageu8:gradienthash()
                update_count = update_count + 1
                if not dry_run then
                    local update, update_err =
                        model:insertImageHash(image.image_id, hash)
                    if not update then
                        print("failed on image_id %d" % { image.image_id })
                        print(update_err)
                    end
                end
            end
        end
        local queue_entries, qe_err = model:getAllActiveQueueEntries()
        if not queue_entries then
            print("Failed :(")
            print(qe_err)
            return 1
        end
        for j = 1, #queue_entries do
            local qe = queue_entries[j]
            if j % 50 == 1 then
                print(
                    "Checking queue entry %d of %d…" % { j, #queue_entries }
                )
            end
            if qe.image then
                local imageu8 = img.loadbuffer(qe.image)
                local hash = imageu8:gradienthash()
                update_count = update_count + 1
                if not dry_run then
                    local update, update_err =
                        model:insertQueueHash(qe.qid, hash)
                    if not update then
                        print("failed on qid %d" % { qe.qid })
                        print(update_err)
                    end
                end
            end
        end
        print(
            "Updated %d images/queue entries for user %s"
                % { update_count, user.user_id }
        )
        if dry_run then
            print("(but not really because this is a dry run)")
        end
        return 0
    end)
    return 0
end

local function thumbnail(other_args)
    local dry_run = other_args[1] == "-d"
    if not img then
        print(
            "This Redbean wasn't compiled with the img library. Please check the installation documentation."
        )
        return 1
    end
    for_each_user(function(i, user, model)
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
                print("Checking record %d of %d…" % { j, #images })
            end
            local _, image_path =
                FsTools.make_image_path_from_filename(image.file)
            local imageu8, load_err = img.loadfile(image_path)
            if not imageu8 then
                print("failed on image_id %d" % { image.image_id })
                print(load_err)
            else
                local thumbnail = imageu8:resize(192)
                local thumbnail_webp = thumbnail:savebufferwebp(75.0)
                update_count = update_count + 1
                if not dry_run then
                    local update, update_err = model:insertThumbnailForImage(
                        image.image_id,
                        thumbnail_webp,
                        thumbnail:width(),
                        thumbnail:height(),
                        1,
                        "image/webp"
                    )
                    if not update then
                        print("failed on image_id %d" % { image.image_id })
                        print(update_err)
                    end
                end
            end
        end
        print(
            "Updated %d images with thumbnails for user %s"
                % { update_count, user.user_id }
        )
        if dry_run then
            print("(but not really because this is a dry run)")
        end
        return 0
    end)
    return 0
end

local commands = {
    db_migrate = db_migrate,
    update_image_sizes = update_image_sizes,
    import_tags = import_tags,
    make_invite = make_invite,
    hash = hash,
    thumbnail = thumbnail,
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

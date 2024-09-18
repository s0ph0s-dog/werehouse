Sqlite3 = require("lsqlite3")
NanoID = require("nanoid")
Fm = require("third_party.fullmoon")
DbUtil = require("db")
FsTools = require("fstools")
local _ = require("functools")
ScraperPipeline = require("scraper_pipeline")

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
    print(
        "- redo_bad_disambig_req: Redo all queries that require disambiguation, to fix a bad disambiguation request."
    )
    print(
        "- fix_0wh (-d): Fix database entries for images that have unrealistically small width or height."
    )
    print(
        "- calc_queue_wh (-d): Calculate width and height for images in the queue."
    )
    print(
        "- clean_sources (-d): Loop through every source in each user's database and clean up duplicates caused by slightly different URLs (trailing slashes, etc.)"
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
    for_each_user(function(_, user, model)
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
        return 0
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
    for_each_user(function(_, user, model)
        local images, images_err = model.conn:fetchAll(
            "SELECT image_id, file FROM images WHERE image_id NOT IN (SELECT image_id FROM image_gradienthashes);"
        )
        if not images then
            print("Failed :(")
            print(images_err)
            return 1
        end
        local update_count = 0
        for j = 1, #images do
            local image = images[j]
            if j % 50 == 1 then
                print(
                    "Checking record %d of %d (id %d)…"
                        % { j, #images, image.image_id }
                )
            end
            local _, image_path =
                FsTools.make_image_path_from_filename(image.file)
            local imageu8, load_err = img.loadfile(image_path)
            if not imageu8 then
                print("failed on image_id %d" % { image.image_id })
                print(load_err)
            else
                local hash_ok, img_hash = pcall(imageu8.gradienthash, imageu8)
                if not hash_ok then
                    print("failed on image_id %d" % { image.image_id })
                end
                if not img_hash then
                    print(
                        "failed to hash image_id %d (nil hash)"
                            % { image.image_id }
                    )
                end
                update_count = update_count + 1
                if not dry_run then
                    local update, update_err =
                        model:insertImageHash(image.image_id, img_hash)
                    if not update then
                        print("failed on image_id %d" % { image.image_id })
                        print(update_err)
                    end
                end
            end
        end
        -- This is in the schema, but I'm not using it yet, so don't waste time computing them.
        --[[
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
                local imageu8, load_err = img.loadbuffer(qe.image)
                if not imageu8 then
                    print("failed on qid %d" % { qe.qid })
                    print(load_err)
                else
                    local q_hash = imageu8:gradienthash()
                    update_count = update_count + 1
                    if not dry_run then
                        local update, update_err =
                            model:insertQueueHash(qe.qid, q_hash)
                        if not update then
                            print("failed on qid %d" % { qe.qid })
                            print(update_err)
                        end
                    end
                end
            end
        end
        ]]
        print(
            "Updated %d images entries for user %s"
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
    for_each_user(function(_, user, model)
        local images, images_err = model.conn:fetchAll(
            "SELECT image_id, file FROM images WHERE image_id NOT IN (SELECT DISTINCT image_id FROM thumbnails);"
        )
        if not images then
            print("Failed :(")
            print(images_err)
            return 1
        end
        local update_count = 0
        for j = 1, #images do
            local image = images[j]
            if j % 50 == 1 then
                print(
                    "Checking record %d of %d (id %d)…"
                        % { j, #images, image.image_id }
                )
            end
            local _, image_path =
                FsTools.make_image_path_from_filename(image.file)
            local imageu8, load_err = img.loadfile(image_path)
            if not imageu8 then
                print("failed on image_id %d" % { image.image_id })
                print(load_err)
            else
                local thumbu8 = imageu8:resize(192)
                local thumbnail_webp = thumbu8:savebufferwebp(75.0)
                update_count = update_count + 1
                if not dry_run then
                    local update, update_err = model:insertThumbnailForImage(
                        image.image_id,
                        thumbnail_webp,
                        thumbu8:width(),
                        thumbu8:height(),
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

local function redo_bad_disambig_req(_)
    for_each_user(function(_, _, model)
        local query =
            "select qid from queue where substr(disambiguation_request, 1, 1) = '[' OR disambiguation_request = '';"
        local results, err = model.conn:fetchAll(query)
        if not results then
            print(err)
        end
        for j = 1, #results do
            local result = results[j]
            local rst_query =
                "update queue set disambiguation_request = NULL where qid = ?;"
            local rst_ok, rst_err = model.conn:execute(rst_query, result.qid)
            if not rst_ok then
                print(rst_err)
            else
                print("cleared qid %d" % { result.qid })
            end
        end
        return 0
    end)
end

-- Redbean's Benchmark() throws an exception about the system being too busy even on a machine with a load average of 0.1 and 24 cores.
local function my_benchmark(fun, count)
    local cumulative_time = 0
    for _ = 1, (count + 1) do
        local start_s, start_ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
        fun()
        local end_s, end_ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
        local duration_s = end_s - start_s
        local duration_ns = end_ns - start_ns
        if duration_ns < 0 then
            duration_ns = 1E9 + duration_ns
        end
        cumulative_time = cumulative_time + (duration_s * 1E9) + duration_ns
    end
    return cumulative_time / count
end

local function find_hash_params(_)
    local function hash_benchmark(time, mem, parallelism)
        local params = {
            m_cost = mem,
            t_cost = time,
            parallelism = parallelism,
        }
        return function()
            return argon2.hash_encoded("password", "somesalt", params)
        end
    end

    local time = 4
    local mem = 2 ^ 16
    local parallelism = 4
    repeat
        print("Trying time = %d…" % { time })
        local nanos, _, _, _ =
            my_benchmark(hash_benchmark(time, mem, parallelism), 64)
        time = time * 2
        print("Took %f ms" % { nanos / 1E6 })
    until nanos > 1E9

    print(
        "Password hash parameters that make hashing take 1s: m_cost = %d, t_cost = %d, parallelism = %d"
            % { time, mem, parallelism }
    )
end

local function clean_orphan_files(other_args)
    local dry_run = other_args[1] == "-d"
    local image_files = FsTools.list_all_image_files()
    print("Total number of files saved:", #image_files)
    local image_set = {}
    for i = 1, #image_files do
        local file_name = image_files[i]
        image_set[file_name] = true
    end
    for_each_user(function(_, _, model)
        local query = "SELECT file FROM images;"
        local all_files_for_user, err = model.conn:fetchAll(query)
        if not all_files_for_user then
            Log(kLogError, err)
            return 0
        end
        for j = 1, #all_files_for_user do
            local user_file = all_files_for_user[j].file
            -- Remove files from the set which are referenced by this user's database.
            if image_set[user_file] then
                image_set[user_file] = nil
            else
                Log(
                    kLogWarn,
                    "File %s is referenced in the database, but doesn't exist on disk!"
                        % { user_file }
                )
            end
        end
        return 0
    end)
    print("Orphan files:")
    for file, _ in pairs(image_set) do
        print(file)
        if not dry_run then
            local _, path = FsTools.make_image_path_from_filename(file)
            unix.unlink(path)
        end
    end
end

local function fix_0wh(other_args)
    local dry_run = other_args[1] == "-d"
    if not img then
        Log(
            kLogError,
            "No img library, unable to fix records with bad width/height"
        )
        return
    end
    for_each_user(function(_, _, model)
        local SP_DIMFIX = "fix_dimensions_for_images"
        local query =
            "SELECT image_id, file FROM images WHERE width < 10 OR height < 10;"
        local wquery =
            "UPDATE images SET width = ?, height = ? WHERE image_id = ?;"
        model:create_savepoint(SP_DIMFIX)
        local wrongdim_files, wdf_err = model.conn:fetchAll(query)
        if not wrongdim_files then
            Log(kLogError, wdf_err)
            model:rollback(SP_DIMFIX)
            return 0
        end
        for j = 1, #wrongdim_files do
            local user_file = wrongdim_files[j]
            local _, fullpath =
                FsTools.make_image_path_from_filename(user_file.file)
            local imageu8, i_err = img.loadfile(fullpath)
            if imageu8 and not dry_run then
                local wok, werr = model.conn:execute(
                    wquery,
                    imageu8:width(),
                    imageu8:height(),
                    user_file.image_id
                )
                if not wok then
                    model:rollback(SP_DIMFIX)
                    Log(kLogError, werr)
                    return 1
                end
            elseif dry_run then
                Log(
                    kLogInfo,
                    "Would've updated dimensions for %d (%s)"
                        % { user_file.image_id, user_file.file }
                )
            else
                Log(kLogError, i_err)
            end
        end
        model:release_savepoint(SP_DIMFIX)
        return 0
    end)
end

local function calc_queue_wh(other_args)
    local dry_run = other_args[1] == "-d"
    if not img then
        Log(
            kLogError,
            "No img library, unable to fix queue entries with missing width/height"
        )
        return
    end
    for_each_user(function(_, _, model)
        local query = "SELECT qid, image FROM queue WHERE image IS NOT NULL;"
        local update =
            "UPDATE queue SET image_width = ?, image_height = ? WHERE qid = ?;"
        local qimgs, qi_err = model.conn:fetchAll(query)
        if not qimgs then
            Log(kLogError, qi_err)
            return 0
        end
        for j = 1, #qimgs do
            local qimg = qimgs[j]
            local imageu8, i_err = img.loadbuffer(qimg.image)
            if imageu8 and not dry_run then
                local width, height = imageu8:width(), imageu8:height()
                local wok, werr =
                    model.conn:execute(update, width, height, qimg.qid)
            else
                Log(kLogInfo, "Would've updated dimensions for %d" % {
                    qimg.qid,
                })
            end
        end
        return 0
    end)
end

local function queue2_migrate(other_args)
    local dry_run = other_args[1] == "-d"
    for_each_user(function(_, _, model)
        local SP = "migrate_queue_to_queue2"
        model:create_savepoint(SP)
        local queue2_query =
            "INSERT INTO queue2 (qid, link, added_on, status, description, retry_count, tg_chat_id, tg_message_id)SELECT qid, link, added_on, tombstone, status, retry_count, tg_chat_id, tg_message_id FROM queue;"
        local queue_image_fetch =
            "SELECT qid, image, image_mime_type, image_width, image_height FROM queue WHERE image IS NOT NULL;"
        local queue_image_insert =
            "INSERT INTO queue_images (qid, image, image_mime_type, image_width, image_height) VALUES (?, ?, ?, ?, ?);"
        local SP_Q2 = "migrate_queue_to_queue2_table_copy"
        model:create_savepoint(SP_Q2)
        local q2_ok, q2_err = model.conn:execute(queue2_query)
        if dry_run then
            model:rollback(SP_Q2)
        else
            model:release_savepoint(SP_Q2)
        end
        if not q2_ok then
            Log(kLogError, q2_err)
            model:rollback(SP)
            return 0
        end
        Log(kLogInfo, "Migrated %d records to the queue2 table" % { q2_ok })
        local queue_images, qimg_err = model.conn:fetchAll(queue_image_fetch)
        if not queue_images then
            Log(kLogError, qimg_err)
            model:rollback(SP)
            return 0
        end
        for j = 1, #queue_images do
            local qimg = queue_images[j]
            Log(
                kLogVerbose,
                "Saving image for queue record " .. tostring(qimg.qid)
            )
            if not dry_run then
                local filename = FsTools.save_queue(
                    qimg.image,
                    qimg.image_mime_type,
                    model.user_id
                )
                Log(kLogDebug, "Output filename: " .. filename)
                local insert_ok, insert_err = model.conn:execute(
                    queue_image_insert,
                    qimg.qid,
                    filename,
                    qimg.image_mime_type,
                    qimg.image_width,
                    qimg.image_height
                )
                if not insert_ok then
                    Log(kLogError, insert_err)
                    model:rollback(SP)
                end
            else
                Log(
                    kLogInfo,
                    "Would have saved image to disk for qid "
                        .. tostring(qimg.qid)
                )
            end
        end
        model:release_savepoint(SP)
        return 0
    end)
end

local function clean_sources(other_args)
    local dry_run = other_args[1] == "-d"
    for_each_user(function(_, _, model)
        local SP = "clean_sources"
        model:create_savepoint(SP)
        local all_sources_q = [[select source_id, link from sources;]]
        local update_source_q =
            [[update or replace sources set link = ? where source_id = ?;]]
        local all_sources, source_err = model.conn:fetchAll(all_sources_q)
        if not all_sources then
            Log(kLogInfo, source_err)
            model:rollback(SP)
            return 0
        end
        local update_count = 0
        for i = 1, #all_sources do
            local source = all_sources[i]
            local cleaned = ScraperPipeline.normalize_uri(source.link)
            if cleaned ~= source.link then
                Log(kLogVerbose, "%s -> %s" % { source.link, cleaned })
                if not dry_run then
                    local ok, up_err = model.conn:execute(
                        update_source_q,
                        cleaned,
                        source.source_id
                    )
                    if not ok then
                        Log(kLogInfo, up_err)
                        model:rollback(SP)
                        return 0
                    end
                    update_count = update_count + 1
                end
            end
        end
        model:release_savepoint(SP)
        Log(kLogInfo, "Updated %d records%s" % {
            update_count,
            dry_run and " (because dry-run)" or "",
        })
        return 0
    end)
end

local function reapply_tags_from_rules(_)
    for_each_user(function(_, _, model)
        local SP = "reapply_tags_from_rules"
        model:create_savepoint(SP)
        local delete_q =
            [[DELETE FROM image_tags WHERE (image_id, tag_id) IN (SELECT image_id, tag_id FROM incoming_tags_now_matched_by_tag_rules WHERE applied = 0);]]
        Log(kLogInfo, "Deleting all tags which were added by a tag rule…")
        local d_ok, d_err = model.conn:execute(delete_q)
        if not d_ok then
            Log(kLogWarn, tostring(d_err))
            model:rollback(SP)
            return 1
        else
            Log(kLogInfo, "Tags deleted: " .. tostring(d_ok))
        end
        Log(kLogInfo, "Reapplying all tag rules…")
        local a_ok, a_err = model:applyIncomingTagsNowMatchedByTagRules()
        if not a_ok then
            Log(kLogWarn, tostring(a_err))
            model:rollback(SP)
            return 1
        else
            Log(kLogInfo, "Tags added: " .. tostring(#a_ok))
        end
        model:release_savepoint(SP)
        return 0
    end)
end

local commands = {
    db_migrate = db_migrate,
    update_image_sizes = update_image_sizes,
    import_tags = import_tags,
    make_invite = make_invite,
    hash = hash,
    thumbnail = thumbnail,
    redo_bad_disambig_req = redo_bad_disambig_req,
    find_hash_params = find_hash_params,
    clean_orphan_files = clean_orphan_files,
    fix_0wh = fix_0wh,
    calc_queue_wh = calc_queue_wh,
    queue2_migrate = queue2_migrate,
    clean_sources = clean_sources,
    reapply_tags_from_rules = reapply_tags_from_rules,
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

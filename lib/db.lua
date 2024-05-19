local ACCOUNTS_DB_FILE = "db/werehouse-accounts.sqlite3"
local USER_DB_FILE_TEMPLATE = "db/werehouse-%s.sqlite3"

local accounts_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "users" (
        "user_id" TEXT NOT NULL UNIQUE,
        "username" TEXT NOT NULL UNIQUE,
        "password" TEXT NOT NULL,
        "invites_available" INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY("user_id")
    );

    CREATE TABLE IF NOT EXISTS "telegram_accounts" (
        "user_id" TEXT NOT NULL,
        "tg_userid" INTEGER NOT NULL UNIQUE,
        PRIMARY KEY("tg_userid", "user_id")
    );

    CREATE TABLE IF NOT EXISTS "sessions" (
        "session_id" TEXT NOT NULL UNIQUE,
        "created" TEXT NOT NULL,
        "user_id" TEXT NOT NULL,
        "last_seen" INTEGER NOT NULL,
        "user_agent" TEXT NOT NULL,
        "ip" TEXT NOT NULL,
        "csrf_token" TEXT NOT NULL,
        PRIMARY KEY("session_id"),
        FOREIGN KEY ("user_id") REFERENCES "users"("user_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "invites" (
        "invite_id" TEXT NOT NULL UNIQUE,
        "inviter" TEXT,
        "invitee" TEXT,
        "created_at" TEXT NOT NULL,
        PRIMARY KEY("invite_id"),
        FOREIGN KEY ("inviter") REFERENCES "users"("user_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("invitee") REFERENCES "users"("user_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "telegram_link_requests" (
        "request_id" TEXT NOT NULL UNIQUE,
        "display_name" TEXT,
        "username" TEXT,
        "tg_userid" INTEGER NOT NULL,
        "created_at" INTEGER NOT NULL,
        PRIMARY KEY("request_id")
    );

    CREATE TRIGGER IF NOT EXISTS invitee_write_once
        BEFORE UPDATE OF "invitee" ON "invites"
        FOR EACH ROW WHEN old.invitee NOT NULL
        BEGIN SELECT RAISE(ROLLBACK, 'Invite already used'); END;
]]

local user_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "images" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "file" TEXT NOT NULL UNIQUE,
        "mime_type" TEXT NOT NULL,
        "category" INTEGER,
        "saved_at" TEXT NOT NULL,
        "rating" INTEGER,
        "kind" INTEGER,
        "height" INTEGER NOT NULL,
        "width" INTEGER NOT NULL,
        "file_size" INTEGER NOT NULL,
        PRIMARY KEY("image_id")
    );

    CREATE TABLE IF NOT EXISTS "tags" (
        "tag_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT NOT NULL UNIQUE,
        "description" TEXT NOT NULL,
        PRIMARY KEY("tag_id")
    );

    CREATE TABLE IF NOT EXISTS "image_tags" (
        "image_id" INTEGER NOT NULL,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("image_id", "tag_id"),
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE VIEW IF NOT EXISTS "tag_counts" (tag_id, count) AS
    SELECT image_tags.tag_id, COUNT(*) AS count
        FROM image_tags
        GROUP BY image_tags.tag_id;

    CREATE TABLE IF NOT EXISTS "tag_rules" (
        "tag_rule_id" INTEGER NOT NULL UNIQUE,
        "incoming_name" TEXT NOT NULL,
        "incoming_domain" TEXT NOT NULL,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("tag_rule_id"),
        FOREIGN KEY("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "sources" (
        "source_id" INTEGER NOT NULL UNIQUE,
        "image_id" INTEGER NOT NULL,
        "link" TEXT NOT NULL,
        PRIMARY KEY("source_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "artists" (
        "artist_id" INTEGER NOT NULL UNIQUE,
        "manually_confirmed" INTEGER NOT NULL DEFAULT 0,
        "name" TEXT NOT NULL UNIQUE,
        PRIMARY KEY("artist_id")
    );

    CREATE TABLE IF NOT EXISTS "artist_handles" (
        "handle_id" INTEGER NOT NULL,
        "artist_id" INTEGER NOT NULL,
        "handle" TEXT NOT NULL,
        "domain" TEXT NOT NULL,
        "profile_url" TEXT NOT NULL,
        PRIMARY KEY("handle_id"),
        FOREIGN KEY ("artist_id") REFERENCES "artists"("artist_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "image_artists" (
        "image_id" INTEGER NOT NULL,
        "artist_id" INTEGER NOT NULL,
        PRIMARY KEY("image_id", "artist_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("artist_id") REFERENCES "artists"("artist_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "share_ping_list" (
        "spl_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT NOT NULL,
        -- JSON blob that contains settings necessary for sharing to whatever service.
        "share_data" TEXT NOT NULL,
        PRIMARY KEY("spl_id")
    );

    CREATE TABLE IF NOT EXISTS "share_ping_list_entry" (
        "spl_entry_id" INTEGER NOT NULL UNIQUE,
        "handle" TEXT NOT NULL,
        "spl_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id"),
        FOREIGN KEY ("spl_id") REFERENCES "share_ping_list"("spl_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "pl_entry_positive_tags" (
        "spl_entry_id" INTEGER NOT NULL UNIQUE,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id", "tag_id"),
        FOREIGN KEY ("spl_entry_id") REFERENCES "share_ping_list_entry"("spl_entry_id")
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "pl_entry_negative_tags" (
        "spl_entry_id" INTEGER NOT NULL UNIQUE,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id", "tag_id"),
        FOREIGN KEY ("spl_entry_id") REFERENCES "share_ping_list_entry"("spl_entry_id")
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "image_group" (
        "ig_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT,
        PRIMARY KEY("ig_id")
    );

    CREATE TABLE IF NOT EXISTS "images_in_group" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "ig_id" INTEGER NOT NULL,
        "order" INTEGER,
        PRIMARY KEY("image_id", "ig_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        FOREIGN KEY ("ig_id") REFERENCES "image_group"("ig_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "thumbnails" (
        "thumbnail_id" INTEGER NOT NULL UNIQUE,
        "image_id" INTEGER NOT NULL,
        "thumbnail" BLOB NOT NULL,
        "width" INTEGER NOT NULL,
        "height" INTEGER NOT NULL,
        "scale" INTEGER NOT NULL,
        PRIMARY KEY("thumbnail_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "queue" (
        "qid" INTEGER NOT NULL UNIQUE,
        "link" TEXT UNIQUE,
        "image" BLOB,
        "image_mime_type" TEXT,
        "tombstone" INTEGER NOT NULL,
        "added_on" TEXT NOT NULL,
        "status" TEXT NOT NULL,
        "disambiguation_request" TEXT,
        "disambiguation_data" TEXT,
        PRIMARY KEY("qid")
    );

]]

local queries = {
    accounts = {
        count_users = [[SELECT COUNT(*) AS count FROM "users";]],
        count_invites = [[SELECT COUNT(*) FROM "invites";]],
        bootstrap_invite = [[INSERT INTO "invites" ("invite_id", "created_at")
            VALUES (?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));]],
        find_invite = [[SELECT "inviter", "invitee", "created_at"
            FROM "invites"
            WHERE "invite_id" = ?;]],
        insert_user = [[INSERT INTO "users" ("user_id", "username", "password")
            VALUES (?, ?, ?);]],
        assign_invite = [[UPDATE "invites" SET "invitee" = ?
            WHERE invite_id = ? AND "invitee" = NULL;]],
        find_user_by_name = [[SELECT "user_id", "username", "password"
            FROM "users"
            WHERE "username" = ?;]],
        insert_session = [[INSERT INTO "sessions" ("session_id", "user_id", "created", "last_seen", "user_agent", "ip", "csrf_token")
            VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?, ?, ?, ?);]],
        get_session_by_id_and_ip = [[SELECT "created", "user_id" from "sessions"
            WHERE "session_id" = ? AND "ip" = ?;]],
        get_all_sessions_for_user = [[SELECT session_id, created, last_seen, user_agent, ip
            FROM sessions WHERE user_id = ?;]],
        get_all_invite_links_created_by_user = [[SELECT
                invite_id, (invitee IS NOT NULL) AS used
            FROM invites WHERE inviter = ?;]],
        get_sessions_older_than_stamp = [[SELECT session_id FROM sessions WHERE last_seen < ?;]],
        get_user_by_session = [[SELECT u.user_id, u.username, u.invites_available FROM "users" AS u
            INNER JOIN "sessions" on u.user_id = sessions.user_id
            WHERE sessions.session_id = ?;]],
        get_user_by_tg_id = [[SELECT users.user_id, users.username
            FROM users
            JOIN telegram_accounts ON users.user_id = telegram_accounts.user_id
            WHERE telegram_accounts.tg_userid = ?;]],
        get_all_user_ids = [[SELECT user_id FROM "users";]],
        get_telegram_link_request_by_id = [[SELECT request_id, display_name, username, tg_userid, created_at
            FROM telegram_link_requests
            WHERE request_id = ?;]],
        get_telegram_accounts_by_user_id = [[SELECT tg_userid
            FROM telegram_accounts WHERE user_id = ?;]],
        insert_telegram_link_request = [[INSERT INTO "telegram_link_requests"
            ("request_id", "display_name", "username", "tg_userid", "created_at")
            VALUES (?, ?, ?, ?, ?);]],
        insert_telegram_account_id = [[INSERT INTO "telegram_accounts"
            ("user_id", "tg_userid")
            VALUES (?, ?);]],
        update_session_last_seen = [[UPDATE "sessions"
            SET last_seen = ?
            WHERE session_id = ?;]],
        update_csrf_token_for_session = [[UPDATE "sessions" SET csrf_token = ? WHERE session_id = ?;]],
        delete_telegram_link_request = [[DELETE FROM telegram_link_requests WHERE request_id = ?;]],
        delete_sessions_older_than_stamp = [[DELETE FROM "sessions" WHERE last_seen < ?;]],
        delete_sessions_for_user = [[DELETE FROM "sessions" WHERE user_id = ?;]],
    },
    model = {
        get_recent_queue_entries = [[SELECT qid, link, tombstone, added_on, status, disambiguation_request, disambiguation_data
            FROM queue
            ORDER BY added_on DESC
            LIMIT 20;]],
        get_all_queue_entries = [[SELECT qid, link, image, image_mime_type, tombstone, added_on, status, disambiguation_request, disambiguation_data
            FROM queue
            ORDER BY added_on DESC;]],
        get_all_active_queue_entries = [[SELECT qid, link, image, image_mime_type, tombstone, added_on, status, disambiguation_request, disambiguation_data
            FROM queue
            WHERE tombstone = 0
            ORDER BY added_on DESC;]],
        get_queue_entry_count = [[SELECT COUNT(*) AS count FROM "queue";]],
        get_queue_entries_paginated = [[SELECT qid, link, tombstone, added_on, status, disambiguation_request, disambiguation_data
            FROM queue
            ORDER BY added_on DESC
            LIMIT ?
            OFFSET ?;]],
        get_queue_entry_by_id = [[SELECT qid, link, image, image_mime_type, tombstone, added_on, status, disambiguation_request, disambiguation_data
            FROM queue
            WHERE qid = ?;]],
        get_queue_image_by_id = [[SELECT image, image_mime_type FROM queue
            WHERE qid = ?;]],
        get_image_entry_count = [[SELECT COUNT(*) as count FROM images;]],
        get_recent_image_entries = [[SELECT image_id, file
            FROM images
            ORDER BY saved_at DESC
            LIMIT 20;]],
        get_image_entries_newest_first_paginated = [[SELECT image_id, file
            FROM images
            ORDER BY saved_at DESC
            LIMIT ?
            OFFSET ?;]],
        get_image_by_id = [[SELECT image_id, file, saved_at, category, rating, kind
            FROM images
            WHERE image_id = ?;]],
        get_artists_for_image = [[SELECT artists.artist_id, artists.name
            FROM artists INNER JOIN image_artists
            ON image_artists.artist_id = artists.artist_id
            WHERE image_artists.image_id = ?;]],
        get_tag_id_by_name = [[SELECT tag_id FROM tags WHERE name = ?;]],
        get_tags_for_image = [[SELECT tags.tag_id, tags.name, tag_counts.count
            FROM tags INNER JOIN image_tags
            ON image_tags.tag_id = tags.tag_id
            JOIN tag_counts ON tag_counts.tag_id = image_tags.tag_id
            WHERE image_tags.image_id = ?;]],
        get_all_tags = [[SELECT tag_id, name FROM tags;]],
        get_sources_for_image = [[SELECT source_id, link
            FROM sources
            WHERE image_id = ?;]],
        get_source_by_link = [[SELECT DISTINCT image_id FROM sources
            WHERE link = ?;]],
        get_artist_id_by_domain_and_handle = [[SELECT artist_id FROM artist_handles
            WHERE domain = ? AND handle = ?;]],
        get_last_order_for_image_group = [[SELECT MAX("order") AS max_order
            FROM images_in_group
            WHERE ig_id = ?;]],
        get_all_artists = [[SELECT artist_id, name FROM artists;]],
        get_artist_entry_count = [[SELECT COUNT(*) AS count FROM artists;]],
        get_artist_entries_paginated = [[SELECT
                artists.artist_id,
                artists.name,
                artists.manually_confirmed,
                COUNT(artist_handles.domain) AS handle_count,
                ifnull(image_count, 0) AS image_count
            FROM artists
            LEFT JOIN artist_handles ON artists.artist_id = artist_handles.artist_id
            LEFT JOIN (
                SELECT artist_id AS artist_id_for_count, COUNT(*) as image_count
                FROM image_artists
                GROUP BY artist_id
            ) ON artists.artist_id = artist_id_for_count
            GROUP BY artist_handles.artist_id
            ORDER BY artists.name COLLATE NOCASE
            LIMIT ?
            OFFSET ?;]],
        get_tag_entries_paginated = [[SELECT
                tags.tag_id,
                tags.name,
                tags.description,
                COUNT(image_tags.image_id) AS image_count
            FROM tags
            LEFT JOIN image_tags ON image_tags.tag_id = tags.tag_id
            GROUP BY tags.tag_id
            ORDER BY tags.name COLLATE NOCASE
            LIMIT ?
            OFFSET ?;]],
        get_artist_by_id = [[SELECT artist_id, name, manually_confirmed
            FROM artists
            WHERE artist_id = ?;]],
        get_tag_by_id = [[SELECT tag_id, name, description
            FROM tags WHERE tag_id = ?;]],
        get_artist_id_by_name = [[SELECT artist_id FROM artists WHERE name = ?;]],
        get_handles_for_artist = [[SELECT handle_id, handle, domain, profile_url
            FROM artist_handles
            WHERE artist_id = ?;]],
        get_recent_images_for_artist = [[SELECT images.image_id, images.file
            FROM images
            JOIN image_artists ON images.image_id = image_artists.image_id
            WHERE image_artists.artist_id = ?
            ORDER BY images.saved_at DESC
            LIMIT ?;]],
        get_recent_images_for_tag = [[SELECT images.image_id, images.file
            FROM images
            JOIN image_tags ON images.image_id = image_tags.image_id
            WHERE image_tags.tag_id = ?
            ORDER BY images.saved_at DESC
            LIMIT ?;]],
        get_all_images_for_size_check = [[SELECT image_id, file, file_size FROM images;]],
        get_image_group_count = [[SELECT COUNT(*) AS count FROM image_group;]],
        get_image_groups_paginated = [[SELECT
                image_group.ig_id,
                image_group.name,
                COUNT(images_in_group.image_id) AS image_count
            FROM image_group
            inner JOIN images_in_group ON image_group.ig_id = images_in_group.ig_id
            GROUP BY image_group.ig_id
            ORDER BY image_group.ig_id
            LIMIT ?
            OFFSET ?;]],
        get_tag_rules_paginated = [[SELECT
                tag_rules.tag_rule_id,
                tag_rules.incoming_name,
                tag_rules.incoming_domain,
                tag_rules.tag_id,
                tags.name AS tag_name
            FROM tag_rules
            INNER JOIN tags ON tag_rules.tag_id = tags.tag_id
            ORDER BY tag_rules.incoming_domain, tag_rules.incoming_name
            LIMIT ?
            OFFSET ?;]],
        get_tag_rule_by_id = [[SELECT
                tag_rules.tag_rule_id,
                tag_rules.incoming_name,
                tag_rules.incoming_domain,
                tag_rules.tag_id,
                tags.name AS tag_name
            FROM tag_rules
            INNER JOIN tags ON tag_rules.tag_id = tags.tag_id
            WHERE tag_rules.tag_rule_id = ?;]],
        insert_or_ignore_tag_by_name = [[INSERT OR IGNORE INTO
            "tags"("name", "description")
            VALUES (?, '');]],
        get_image_group_by_id = [[SELECT ig_id, name
            FROM image_group
            WHERE ig_id = ?;]],
        get_images_for_group = [[SELECT images_in_group.image_id, images_in_group."order", images.file, images.width, images.height
            FROM images_in_group
            inner JOIN images ON images_in_group.image_id = images.image_id
            WHERE ig_id = ?
            ORDER BY images_in_group."order";]],
        get_image_groups_by_image_id = [[SELECT image_group.ig_id, image_group.name
            FROM image_group
            JOIN images_in_group ON image_group.ig_id = images_in_group.ig_id
            WHERE images_in_group.image_id = ?;]],
        get_prev_next_images_in_group = [[SELECT
                images_in_group."order" AS my_order,
                siblings.image_id,
                siblings."order" AS sibling_order
            FROM images_in_group
            JOIN images_in_group AS siblings ON images_in_group.ig_id = siblings.ig_id
            WHERE
                images_in_group.ig_id = ?
                AND images_in_group.image_id = ?
                AND (siblings."order" = (images_in_group."order" + 1)
                    OR siblings."order" = (images_in_group."order" - 1));]],
        get_tag_entry_count = [[SELECT COUNT(*) AS tag_count FROM tags;]],
        get_tag_rule_count = [[SELECT COUNT(*) AS count FROM tag_rules;]],
        get_image_stats = [[SELECT kind, COUNT(kind) AS record_count FROM images
            GROUP BY kind
            ORDER BY kind;]],
        get_disk_space_usage = [[SELECT SUM(file_size) AS size_sum FROM images;]],
        insert_link_into_queue = [[INSERT INTO
            "queue" ("link", "image", "image_mime_type", "tombstone", "added_on", "status")
            VALUES (?, NULL, NULL, 0, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), '');]],
        insert_image_into_queue = [[INSERT INTO
            "queue" ("link", "image", "image_mime_type", "tombstone", "added_on", "status")
            VALUES (NULL, ?, ?, 0, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), '');]],
        insert_image_into_images = [[INSERT INTO
            "images" ("file", "mime_type", "width", "height", "kind", "rating", "file_size", "saved_at")
            VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            RETURNING image_id;]],
        insert_tag = [[INSERT INTO "tags" ("name", "description")
            VALUES (?, ?)
            RETURNING tag_id;]],
        insert_image_tag = [[INSERT INTO "image_tags" ("image_id", "tag_id")
            VALUES (?, ?);]],
        insert_source_for_image = [[INSERT INTO "sources" ("image_id", "link")
            VALUES (?, ?);]],
        insert_artist = [[INSERT INTO "artists" ("name", "manually_confirmed")
            VALUES (?, ?)
            RETURNING artist_id;]],
        insert_image_artist = [[INSERT INTO "image_artists" ("image_id", "artist_id")
            VALUES (?, ?);]],
        insert_artist_handle = [[INSERT INTO "artist_handles" ("artist_id", "handle", "domain", "profile_url")
            VALUES (?, ?, ?, ?);]],
        insert_image_group = [[INSERT INTO "image_group" ("name")
            VALUES (?)
            RETURNING ig_id;]],
        insert_image_in_group = [[INSERT INTO images_in_group (image_id, ig_id, "order")
            VALUES (?, ?, ?);]],
        insert_tag_rule = [[INSERT INTO "tag_rules" (
                "incoming_name",
                "incoming_domain",
                "tag_id"
            ) VALUES (?, ?, ?)
            RETURNING tag_rule_id;]],
        delete_item_from_queue = [[DELETE FROM "queue" WHERE qid = ?;]],
        delete_artist_by_id = [[DELETE FROM "artists" WHERE artist_id = ?;]],
        delete_tag_by_id = [[DELETE FROM "tags" WHERE tag_id = ?;]],
        delete_image_group_by_id = [[DELETE FROM "image_group" WHERE ig_id = ?;]],
        delete_image_artist_by_id = [[DELETE FROM image_artists
            WHERE image_id = ? AND artist_id = ?;]],
        delete_image_tags_by_id = [[DELETE FROM "image_tags"
            WHERE image_id = ? AND tag_id = ?;]],
        delete_source_by_id = [[DELETE FROM "sources" WHERE source_id = ? AND image_id = ?;]],
        delete_tag_rule_by_id = [[DELETE FROM "tag_rules" WHERE tag_rule_id = ?;]],
        delete_handle_for_artist_by_id = [[DELETE FROM "artist_handles"
            WHERE artist_id = ? AND handle_id = ?;]],
        update_queue_item_status = [[UPDATE "queue"
            SET "status" = ?, "tombstone" = ?
            WHERE qid = ?;]],
        update_queue_item_status_to_zero = [[UPDATE "queue"
            SET "tombstone" = 0
            WHERE qid = ?;]],
        update_queue_item_disambiguation_req = [[UPDATE "queue"
            SET "disambiguation_request" = ?
            WHERE qid = ?;]],
        update_queue_item_disambiguation_data = [[UPDATE "queue"
            SET "disambiguation_data" = ?
            WHERE qid = ?;]],
        update_handles_to_other_artist = [[UPDATE "artist_handles"
            SET "artist_id" = ?
            WHERE "artist_id" = ?]],
        update_image_artists_to_other_artist = [[UPDATE OR IGNORE "image_artists"
            SET "artist_id" = ?
            WHERE "artist_id" = ?;]],
        update_image_tags_to_other_tag = [[UPDATE OR IGNORE "image_tags"
            SET "tag_id" = ?
            WHERE "image_id" = ?;]],
        update_images_to_other_group_preserving_order = [[UPDATE images_in_group
            SET
                ig_id = ?,
                "order" = (
                    (SELECT MAX("order") FROM images_in_group WHERE ig_id = ?)
                    + "order"
                )
            WHERE ig_id = ?;]],
        update_name_for_image_group_by_id = [[UPDATE image_group
            SET name = ?
            WHERE ig_id = ?;]],
        update_order_for_image_in_image_group = [[UPDATE images_in_group
            SET "order" = ?
            WHERE ig_id = ? AND image_id = ?;]],
        update_category_rating_for_image_by_id = [[UPDATE images SET category = ?, rating = ?
            WHERE image_id = ?;]],
        update_image_size_by_id = [[UPDATE images SET file_size = ?
            WHERE image_id = ?;]],
        update_tag_by_id = [[UPDATE tags
            SET name = ?, description = ?
            WHERE tag_id = ?;]],
        update_artist_by_id = [[UPDATE "artists"
            SET name = ?, manually_confirmed = ?
            WHERE artist_id = ?;]],
        update_tag_rule_by_id = [[UPDATE "tag_rules"
            SET incoming_name = ?, incoming_domain = ?, tag_id = ?
            WHERE tag_rule_id = ?;]],
    },
}

local function fetchOneExactly(conn, query, ...)
    local result, err = conn:fetchOne(query, ...)
    if not result then
        return nil, err
    elseif result == conn.NONE then
        return nil, "No records returned"
    end
    return result
end

---@class Model
---@field conn table
---@field user_id string
local Model = {}

function Model:new(o, user_id)
    o = o or {}
    local filename = USER_DB_FILE_TEMPLATE % { user_id }
    o.conn = Fm.makeStorage(filename, user_setup)
    o.user_id = user_id
    setmetatable(o, self)
    self.__index = self
    return o
end

function Model:migrate(opts)
    return self.conn:upgrade(opts)
end

function Model:getImageStats()
    return self.conn:fetchAll(queries.model.get_image_stats)
end

function Model:_get_count(query)
    local result, errmsg = self.conn:fetchOne(query)
    if not result then
        return nil, errmsg
    end
    return result.count
end

function Model:_get_paginated(query, page_num, per_page)
    return self.conn:fetchAll(query, per_page, (page_num - 1) * per_page)
end

---@alias RecentQueueEntry {qid: string, link: string, tombstone: integer, added_on: string, status: string}
---@return RecentQueueEntry[]
function Model:getRecentQueueEntries()
    return self.conn:fetchAll(queries.model.get_recent_queue_entries)
end

---@alias ActiveQueueEntry {qid: string, link: string, image: string, image_mime_type: string, tombstone: integer, added_on: string, status: string, disambiguation_request: string, disambiguation_data: string}
---@return ActiveQueueEntry[]
function Model:getAllActiveQueueEntries()
    return self.conn:fetchAll(queries.model.get_all_active_queue_entries)
end

function Model:getQueueEntryCount()
    return self:_get_count(queries.model.get_queue_entry_count)
end

function Model:getPaginatedQueueEntries(page_num, per_page)
    return self.conn:fetchAll(
        queries.model.get_queue_entries_paginated,
        per_page,
        (page_num - 1) * per_page
    )
end

function Model:getImageEntryCount()
    local result, errmsg =
        self.conn:fetchOne(queries.model.get_image_entry_count)
    if not result then
        return nil, errmsg
    end
    return result.count
end

function Model:getRecentImageEntries()
    return self.conn:fetchAll(queries.model.get_recent_image_entries)
end

function Model:getPaginatedImageEntries(page_num, per_page)
    return self.conn:fetchAll(
        queries.model.get_image_entries_newest_first_paginated,
        per_page,
        (page_num - 1) * per_page
    )
end

function Model:getQueueEntryById(qid)
    return fetchOneExactly(self.conn, queries.model.get_queue_entry_by_id, qid)
end

function Model:getQueueImageById(qid)
    return fetchOneExactly(self.conn, queries.model.get_queue_image_by_id, qid)
end

function Model:getImageById(image_id)
    return fetchOneExactly(self.conn, queries.model.get_image_by_id, image_id)
end

function Model:getAllImagesForSizeCheck()
    return self.conn:fetchAll(queries.model.get_all_images_for_size_check)
end

function Model:updateImageSize(image_id, size)
    return self.conn:execute(
        queries.model.update_image_size_by_id,
        size,
        image_id
    )
end

function Model:getArtistsForImage(image_id)
    return self.conn:fetchAll(queries.model.get_artists_for_image, image_id)
end

function Model:getTagsForImage(image_id)
    return self.conn:fetchAll(queries.model.get_tags_for_image, image_id)
end

function Model:deleteTagsForImageById(image_id, tag_ids)
    local SP = "delete_image_tags"
    self:create_savepoint(SP)
    for i = 1, #tag_ids do
        local ok, err = self.conn:execute(
            queries.model.delete_image_tags_by_id,
            image_id,
            tag_ids[i]
        )
        if not ok then
            self:rollback(SP)
            return nil, err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:createTag(tag_name, description)
    local tag, errmsg =
        self.conn:fetchOne(queries.model.insert_tag, tag_name, description)
    if not tag or tag == self.conn.NONE then
        return nil, errmsg
    end
    return tag.tag_id
end

function Model:getAllTags()
    return self.conn:fetchAll(queries.model.get_all_tags)
end

function Model:getSourcesForImage(image_id)
    return self.conn:fetchAll(queries.model.get_sources_for_image, image_id)
end

function Model:updateImageMetadata(image_id, category, rating)
    return self.conn:execute(
        queries.model.update_category_rating_for_image_by_id,
        category,
        rating,
        image_id
    )
end

function Model:enqueueLink(link)
    local ok, result, errmsg = pcall(
        self.conn.execute,
        self.conn,
        queries.model.insert_link_into_queue,
        link
    )
    if not ok then
        return nil, "Link already in queue"
    end
    return result, errmsg
end

function Model:enqueueImage(mime_type, image_data)
    return self.conn:execute(
        queries.model.insert_image_into_queue,
        image_data,
        mime_type
    )
end

function Model:resetQueueItemStatus(queue_ids)
    local SP_QRESET = "reset_queue_status"
    self:create_savepoint(SP_QRESET)
    for _, qid in ipairs(queue_ids) do
        local ok, err = self.conn:execute(
            queries.model.update_queue_item_status_to_zero,
            qid
        )
        if not ok then
            self:rollback(SP_QRESET)
            return nil, err
        end
    end
    self:release_savepoint(SP_QRESET)
    return #queue_ids
end

function Model:setQueueItemStatus(queue_id, tombstone, new_status)
    return self:setQueueItemsStatus({ queue_id }, tombstone, new_status)
end

function Model:setQueueItemsStatus(queue_ids, tombstone, new_status)
    local SP_QSTATUS = "set_queue_status"
    self:create_savepoint(SP_QSTATUS)
    for _, qid in ipairs(queue_ids) do
        local ok, err = self.conn:execute(
            queries.model.update_queue_item_status,
            new_status,
            tombstone,
            qid
        )
        if not ok then
            self:rollback(SP_QSTATUS)
            return nil, err
        end
    end
    self:release_savepoint(SP_QSTATUS)
    return #queue_ids
end

function Model:setQueueItemDisambiguationRequest(queue_id, disambiguation_data)
    return self.conn:execute(
        queries.model.update_queue_item_disambiguation_req,
        disambiguation_data,
        queue_id
    )
end

function Model:setQueueItemDisambiguationResponse(queue_id, disambiguation_data)
    if type(disambiguation_data) ~= "string" then
        disambiguation_data = EncodeJson(disambiguation_data)
    end
    return self.conn:fetchOne(
        queries.model.update_queue_item_disambiguation_data,
        disambiguation_data,
        queue_id
    )
end

function Model:insertImage(
    image_file,
    mime_type,
    width,
    height,
    kind,
    rating,
    file_size
)
    if not rating then
        rating = DbUtil.k.Rating.General
    end
    return self.conn:fetchOne(
        queries.model.insert_image_into_images,
        image_file,
        mime_type,
        width,
        height,
        kind,
        rating,
        file_size
    )
end

function Model:checkDuplicateSources(links)
    local dupes = {}
    for _, link in ipairs(links) do
        Log(kLogDebug, "checking for duplicates of: %s" % { EncodeJson(link) })
        local sources, errmsg =
            self.conn:fetchAll(queries.model.get_source_by_link, link)
        if not sources then
            return nil, errmsg
        end
        for _, image in ipairs(sources) do
            dupes[link] = image.image_id
        end
    end
    return dupes
end

function Model:insertSourcesForImage(image_id, sources)
    local SP = "insert_sources"
    -- TODO: figure out how to use prepared statements for this.
    self:create_savepoint(SP)
    for _, source in ipairs(sources) do
        local result, errmsg = self.conn:execute(
            queries.model.insert_source_for_image,
            image_id,
            source
        )
        if not result then
            self:rollback(SP)
            return nil, errmsg
        end
    end
    self:release_savepoint(SP)
    return true
end

-- Just the source ID should be enough to identify it, but I'm adding in the image_id as a hedge against my own stupidity.
function Model:deleteSourcesForImageById(image_id, source_ids)
    local SP = "delete_sources"
    self:create_savepoint(SP)
    for i = 1, #source_ids do
        local ok, err = self.conn:execute(
            queries.model.delete_source_by_id,
            source_ids[i],
            image_id
        )
        if not ok then
            self:rollback(SP)
            return nil, err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:getDiskSpaceUsage()
    local result, errmsg =
        self.conn:fetchOne(queries.model.get_disk_space_usage)
    if not result then
        return nil, errmsg
    end
    return result.size_sum
end

function Model:getTagCount()
    local result, errmsg = self.conn:fetchOne(queries.model.get_tag_entry_count)
    if not result then
        return nil, errmsg
    end
    return result.tag_count
end

function Model:getArtistCount()
    local result, errmsg =
        self.conn:fetchOne(queries.model.get_artist_entry_count)
    if not result then
        return nil, errmsg
    end
    return result.count
end

function Model:getAllArtists()
    return self.conn:fetchAll(queries.model.get_all_artists)
end

function Model:getPaginatedArtists(page_num, per_page)
    return self.conn:fetchAll(
        queries.model.get_artist_entries_paginated,
        per_page,
        (page_num - 1) * per_page
    )
end

function Model:getPaginatedTags(page_num, per_page)
    return self.conn:fetchAll(
        queries.model.get_tag_entries_paginated,
        per_page,
        (page_num - 1) * per_page
    )
end

function Model:getArtistById(artist_id)
    return fetchOneExactly(self.conn, queries.model.get_artist_by_id, artist_id)
end

function Model:getTagById(tag_id)
    return fetchOneExactly(self.conn, queries.model.get_tag_by_id, tag_id)
end

function Model:updateTag(tag_id, name, desc)
    return self.conn:execute(queries.model.update_tag_by_id, name, desc, tag_id)
end

function Model:getHandlesForArtist(artist_id)
    return self.conn:fetchAll(queries.model.get_handles_for_artist, artist_id)
end

function Model:getRecentImagesForArtist(artist_id, limit)
    return self.conn:fetchAll(
        queries.model.get_recent_images_for_artist,
        artist_id,
        limit
    )
end

function Model:getRecentImagesForTag(tag_id, limit)
    return self.conn:fetchAll(
        queries.model.get_recent_images_for_tag,
        tag_id,
        limit
    )
end

function Model:createHandleForArtist(artist_id, handle, domain, profile_url)
    return self.conn:execute(
        queries.model.insert_artist_handle,
        artist_id,
        handle,
        domain,
        profile_url
    )
end

function Model:updateArtist(artist_id, name, manually_verified)
    return self.conn:execute(
        queries.model.update_artist_by_id,
        name,
        manually_verified,
        artist_id
    )
end

function Model:createArtist(name, manually_verified)
    local artist, errmsg =
        self.conn:fetchOne(queries.model.insert_artist, name, manually_verified)
    if not artist or artist == self.conn.NONE then
        return nil, errmsg
    end
    return artist.artist_id
end

function Model:createArtistWithHandles(name, manually_verified, handles)
    local SP = "create_artist_with_several_handles"
    self:create_savepoint(SP)
    local artist_id, errmsg = self:createArtist(name, manually_verified)
    if not artist_id then
        self:rollback(SP)
        Log(kLogInfo, errmsg)
        return nil, errmsg
    end
    for i = 1, #handles do
        local handle = handles[i]
        local handle_ok, handle_err = self:createHandleForArtist(
            artist_id,
            handle.handle,
            handle.domain,
            handle.profile_url
        )
        if not handle_ok then
            self:rollback(SP)
            Log(kLogInfo, handle_err)
            return nil, handle_err
        end
    end
    self:release_savepoint(SP)
    return artist_id
end

function Model:associateTagWithImage(image_id, tag_id)
    return self.conn:execute(queries.model.insert_image_tag, image_id, tag_id)
end

---@param author_info ScrapedAuthor
---@param domain string
function Model:createArtistAndFirstHandle(author_info, domain)
    local name = author_info.display_name
    local handles = {
        {
            handle = author_info.handle,
            domain = domain,
            profile_url = author_info.profile_url,
        },
    }
    return self:createArtistWithHandles(name, 0, handles)
end

---@param image_id integer
---@param artist_id integer
function Model:associateArtistWithImage(image_id, artist_id)
    return self.conn:execute(
        queries.model.insert_image_artist,
        image_id,
        artist_id
    )
end

---@param image_id integer
---@param domain string The domain name of the website that author_info is from.
---@param author_info ScrapedAuthor
function Model:createOrAssociateArtistWithImage(image_id, domain, author_info)
    local SP = "create_or_associate_artist"
    self:create_savepoint(SP)
    local artist, errmsg = self.conn:fetchOne(
        queries.model.get_artist_id_by_domain_and_handle,
        domain,
        author_info.handle
    )
    if not artist then
        return nil, errmsg
    end
    local artist_id = artist.artist_id
    if not artist_id or artist == self.conn.NONE then
        local result3, errmsg3 =
            self:createArtistAndFirstHandle(author_info, domain)
        if not result3 then
            self:rollback(SP)
            return nil, errmsg3
        end
        artist_id = result3
    end
    local result2, errmsg2 = self:associateArtistWithImage(image_id, artist_id)
    if not result2 then
        self:rollback(SP)
        return nil, errmsg2
    end
    self:release_savepoint(SP)
    return true
end

function Model:addArtistsForImageByName(image_id, artist_names)
    local SP = "add_artists_for_image_by_name"
    self:create_savepoint(SP)
    for i = 1, #artist_names do
        local artist, errmsg = self.conn:fetchOne(
            queries.model.get_artist_id_by_name,
            artist_names[i]
        )
        if not artist then
            self:rollback(SP)
            return nil, errmsg
        end
        local artist_id = artist.artist_id
        if artist == self.conn.NONE then
            artist_id, errmsg = self:createArtist(artist_names[i], 1)
            if not artist_id then
                self:rollback(SP)
                return nil, errmsg
            end
        end
        local link_ok, link_err =
            self:associateArtistWithImage(image_id, artist_id)
        if not link_ok then
            self:rollback(SP)
            return nil, link_err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:findTagIdByName(tag_name)
    return self.conn:fetchOne(queries.model.get_tag_id_by_name, tag_name)
end

function Model:addTagsForImageByName(image_id, tag_names)
    local SP = "add_tags_for_image_by_name"
    self:create_savepoint(SP)
    for i = 1, #tag_names do
        local tag_name = tag_names[i]
        local tag, errmsg = self:findTagIdByName(tag_name)
        if not tag then
            self:rollback(SP)
            Log(kLogDebug, errmsg)
            return nil, errmsg
        end
        local tag_id = tag.tag_id
        if tag == self.conn.NONE then
            tag_id, errmsg = self:createTag(tag_name, "")
            if not tag_id then
                self:rollback(SP)
                Log(kLogDebug, tostring(errmsg))
                return nil, errmsg
            end
        end
        print("ids: ", image_id, tag_id)
        local link_ok, link_err = self:associateTagWithImage(image_id, tag_id)
        if not link_ok then
            self:rollback(SP)
            Log(kLogDebug, link_err)
            return nil, link_err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:_delete_by_id(query, ids)
    for i = 1, #ids do
        local ok, errmsg = self.conn:execute(query, ids[i])
        if not ok then
            return nil, errmsg
        end
    end
    return true
end

function Model:deleteArtists(artist_ids)
    return self:_delete_by_id(queries.model.delete_artist_by_id, artist_ids)
end

function Model:deleteTags(tag_ids)
    return self:_delete_by_id(queries.model.delete_tag_by_id, tag_ids)
end

function Model:mergeArtists(merge_into_id, merge_from_ids)
    local SP_MERGE = "merge_artists"
    self:create_savepoint(SP_MERGE)
    for i = 1, #merge_from_ids do
        local merge_from_id = merge_from_ids[i]
        local handle_ok, handle_err = self.conn:execute(
            queries.model.update_handles_to_other_artist,
            merge_into_id,
            merge_from_id
        )
        if not handle_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, handle_err)
            return nil, handle_err
        end
        local image_ok, image_err = self.conn:execute(
            queries.model.update_image_artists_to_other_artist,
            merge_into_id,
            merge_from_id
        )
        if not image_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, image_err)
            return nil, image_err
        end
    end
    local delete_ok, delete_err = self:deleteArtists(merge_from_ids)
    if not delete_ok then
        self:rollback(SP_MERGE)
        Log(kLogInfo, tostring(delete_err))
        return nil, delete_err
    end
    self:release_savepoint(SP_MERGE)
    return delete_ok
end

function Model:mergeTags(merge_into_id, merge_from_ids)
    local SP_MERGE = "merge_tags"
    self:create_savepoint(SP_MERGE)
    for i = 1, #merge_from_ids do
        local merge_from_id = merge_from_ids[i]
        local image_ok, image_err = self.conn:execute(
            queries.model.update_image_tags_to_other_tag,
            merge_into_id,
            merge_from_id
        )
        if not image_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, image_err)
            return nil, image_err
        end
    end
    local delete_ok, delete_err = self:deleteTags(merge_from_ids)
    if not delete_ok then
        self:rollback(SP_MERGE)
        Log(kLogInfo, tostring(delete_err))
        return nil, delete_err
    end
    self:release_savepoint(SP_MERGE)
    return delete_ok
end

function Model:deleteArtistsForImageById(image_id, artist_ids)
    local SP = "delete_image_artists"
    self:create_savepoint(SP)
    for i = 1, #artist_ids do
        local ok, err = self.conn:execute(
            queries.model.delete_image_artist_by_id,
            image_id,
            artist_ids[i]
        )
        if not ok then
            self:rollback(SP)
            return nil, err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:deleteHandlesForArtistById(artist_id, handle_ids)
    local SP = "delete_artist_handles"
    self:create_savepoint(SP)
    for i = 1, #handle_ids do
        local ok, err = self.conn:execute(
            queries.model.delete_artist_handle_by_id,
            artist_id,
            handle_ids[i]
        )
        if not ok then
            self:rollback(SP)
            return nil, err
        end
    end
    self:release_savepoint(SP)
    return true
end
function Model:getImageGroupCount()
    local result, errmsg =
        self.conn:fetchOne(queries.model.get_image_group_count)
    if not result then
        return nil, errmsg
    end
    return result.count
end

function Model:getPaginatedImageGroups(page_num, per_page)
    return self.conn:fetchAll(
        queries.model.get_image_groups_paginated,
        per_page,
        (page_num - 1) * per_page
    )
end

function Model:renameImageGroup(ig_id, new_name)
    return self.conn:execute(
        queries.model.update_name_for_image_group_by_id,
        new_name,
        ig_id
    )
end

function Model:getGroupsForImage(image_id)
    return self.conn:fetchAll(
        queries.model.get_image_groups_by_image_id,
        image_id
    )
end

function Model:getPrevNextImagesInGroupForImage(ig_id, image_id)
    local siblings = {}
    local results, errmsg = self.conn:fetchAll(
        queries.model.get_prev_next_images_in_group,
        ig_id,
        image_id
    )
    if not results then
        return nil, errmsg
    end
    for _, result in ipairs(results) do
        if result.my_order > result.sibling_order then
            siblings.prev = result.image_id
        elseif result.my_order < result.sibling_order then
            siblings.next = result.image_id
        end
    end
    return siblings
end

function Model:createImageGroup(name)
    return self.conn:fetchOne(queries.model.insert_image_group, name)
end

function Model:addImageToGroupAtEnd(image_id, group_id)
    local last_order, errmsg = self.conn:fetchOne(
        queries.model.get_last_order_for_image_group,
        group_id
    )
    if not last_order then
        return nil, errmsg
    end
    return self.conn:execute(
        queries.model.insert_image_in_group,
        image_id,
        group_id,
        (last_order.max_order or 0) + 1
    )
end

function Model:getImageGroupById(ig_id)
    local group, err =
        self.conn:fetchOne(queries.model.get_image_group_by_id, ig_id)
    if not group then
        return nil, err
    elseif group == self.conn.NONE then
        return nil, "No such group"
    end
    return group
end

function Model:getImagesForGroup(ig_id)
    return self.conn:fetchAll(queries.model.get_images_for_group, ig_id)
end

function Model:setOrderForImageInGroup(ig_id, image_id, new_order)
    return self.conn:execute(
        queries.model.update_order_for_image_in_image_group,
        new_order,
        ig_id,
        image_id
    )
end

function Model:deleteImageGroups(ig_ids)
    for i = 1, #ig_ids do
        local ok, errmsg =
            self.conn:execute(queries.model.delete_image_group_by_id, ig_ids[i])
        if not ok then
            return nil, errmsg
        end
    end
    return true
end

function Model:moveAllImagesToOtherGroup(to_ig_id, from_ig_id)
    return self.conn:execute(
        queries.model.update_images_to_other_group_preserving_order,
        to_ig_id,
        to_ig_id,
        from_ig_id
    )
end

function Model:mergeImageGroups(merge_into_id, merge_from_ids)
    local SP_MERGE = "merge_image_groups"
    self:create_savepoint(SP_MERGE)
    for i = 1, #merge_from_ids do
        local merge_from_id = merge_from_ids[i]
        local group_ok, group_err = self.conn:execute(
            queries.model.update_images_to_other_group_preserving_order,
            merge_into_id,
            merge_into_id,
            merge_from_id
        )
        if not group_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, group_err)
            return nil, group_err
        end
    end
    local delete_ok, delete_err = self:deleteImageGroups(merge_from_ids)
    if not delete_ok then
        self:rollback(SP_MERGE)
        Log(kLogInfo, delete_err)
        return nil, delete_err
    end
    self:release_savepoint(SP_MERGE)
    return delete_ok
end

function Model:deleteFromQueue(queue_ids)
    local SP_QDEL = "delete_from_queue"
    self:create_savepoint(SP_QDEL)
    for _, qid in ipairs(queue_ids) do
        local ok, errmsg =
            self.conn:execute(queries.model.delete_item_from_queue, qid)
        if not ok or errmsg then
            self:rollback(SP_QDEL)
            return nil, errmsg
        end
    end
    self:release_savepoint(SP_QDEL)
    return true
end

function Model:getTagRuleCount()
    return self:_get_count(queries.model.get_tag_rule_count)
end

function Model:getPaginatedTagRules(cur_page, per_page)
    return self:_get_paginated(
        queries.model.get_tag_rules_paginated,
        cur_page,
        per_page
    )
end

function Model:deleteTagRules(tag_rule_ids)
    return self:_delete_by_id(queries.model.delete_tag_rule_by_id, tag_rule_ids)
end

function Model:getTagRuleById(tag_rule_id)
    return self.conn:fetchOne(queries.model.get_tag_rule_by_id, tag_rule_id)
end

function Model:updateTagRule(
    tag_rule_id,
    incoming_name,
    incoming_domain,
    tag_name
)
    local SP = "update_tag_rule"
    self:create_savepoint(SP)
    self.conn:execute(queries.model.insert_or_ignore_tag_by_name, tag_name)
    local tag_id, tag_err = self:findTagIdByName(tag_name)
    if not tag_id then
        self:rollback(SP)
        return nil, tag_err
    end
    local update_ok, update_err = self.conn:execute(
        queries.model.update_tag_rule_by_id,
        incoming_name,
        incoming_domain,
        tag_id,
        tag_rule_id
    )
    if not update_ok then
        self:rollback(SP)
        return nil, update_err
    end
    self:release_savepoint(SP)
    return true
end

function Model:createTagRule(incoming_name, incoming_domain, tag_name)
    local SP = "create_tag_rule"
    self:create_savepoint(SP)
    self.conn:execute(queries.model.insert_or_ignore_tag_by_name, tag_name)
    local tag_id, tag_err = self:findTagIdByName(tag_name)
    if not tag_id then
        self:rollback(SP)
        return nil, tag_err
    end
    print(EncodeJson(tag_id))
    local insert_ok, insert_err = self.conn:fetchOne(
        queries.model.insert_tag_rule,
        incoming_name,
        incoming_domain,
        tag_id.tag_id
    )
    if not insert_ok then
        self:rollback(SP)
        return nil, insert_err
    end
    self:release_savepoint(SP)
    return insert_ok.tag_rule_id
end

function Model:create_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("SAVEPOINT " .. name .. ";")
end

function Model:release_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("RELEASE SAVEPOINT " .. name .. ";")
end

function Model:rollback(to_savepoint)
    if to_savepoint and type(to_savepoint) == "string" then
        return self.conn:execute(
            "ROLLBACK TO %s; RELEASE SAVEPOINT %s;"
                % { to_savepoint, to_savepoint }
        )
    else
        return self.conn:execute("ROLLBACK;")
    end
end

local Accounts = {}

function Accounts:new(o)
    o = o or {}
    o.conn = Fm.makeStorage(ACCOUNTS_DB_FILE, accounts_setup)
    setmetatable(o, self)
    self.__index = self
    return o
end

function Accounts:migrate(opts)
    return self.conn:upgrade(opts)
end

function Accounts:bootstrapInvites()
    local users = self.conn:fetchOne(queries.accounts.count_users)
    if not users or users.count < 1 then
        -- TODO: see if there is an unused invite, and retrieve that instead of
        -- making a new one.
        local invite_id = NanoID.simple_with_prefix(IdPrefixes.invite)
        self.conn:execute(queries.accounts.bootstrap_invite, invite_id)
        Log(
            kLogWarn,
            "There are no accounts in the database. Register one using this link: http://127.0.0.1:8082/accept-invite/%s"
                % { invite_id }
        )
    end
end

function Accounts:findInvite(invite_id)
    local invite = self.conn:fetchOne(queries.accounts.find_invite, invite_id)
    return invite
end

function Accounts:getAllInvitesCreatedByUser(user_id)
    return self.conn:fetchAll(
        queries.accounts.get_all_invite_links_created_by_user,
        user_id
    )
end

function Accounts:acceptInvite(invite_id, username, password_hash)
    local user_id = NanoID.simple_with_prefix(IdPrefixes.user)
    local result, errmsg = self.conn:execute {
        { queries.accounts.insert_user, user_id, username, password_hash },
        { queries.accounts.assign_invite, user_id, invite_id },
    }
    Model:new(nil, user_id)
    return result, errmsg
end

function Accounts:findUser(username)
    return fetchOneExactly(
        self.conn,
        queries.accounts.find_user_by_name,
        username
    )
end

function Accounts:createSessionForUser(user_id, user_agent, ip)
    local session_id = NanoID.simple_with_prefix(IdPrefixes.session)
    local csrf_token = NanoID.simple_with_prefix(IdPrefixes.csrf)
    local now = unix.clock_gettime()
    local result, errmsg = self.conn:execute(
        queries.accounts.insert_session,
        session_id,
        user_id,
        now,
        user_agent,
        ip,
        csrf_token
    )
    if not result then
        return result, errmsg
    end
    return session_id
end

function Accounts:findSessionByIdAndIP(session_id, ip)
    return fetchOneExactly(
        self.conn,
        queries.accounts.get_session_by_id_and_ip,
        session_id,
        ip
    )
end

function Accounts:updateSessionLastSeenToNow(session_id)
    local now = unix.clock_gettime()
    return self.conn:execute(
        queries.accounts.update_session_last_seen,
        now,
        session_id
    )
end

function Accounts:getAllSessionsForUser(user_id)
    return self.conn:fetchAll(
        queries.accounts.get_all_sessions_for_user,
        user_id
    )
end

function Accounts:sessionMaintenance()
    local now = unix.clock_gettime()
    -- Expire all sessions that have not been used in 7 days.
    local expiry_point = now - (7 * 24 * 60 * 60)
    local delete_count, err
    self.conn:execute(
        queries.accounts.delete_sessions_older_than_stamp,
        expiry_point
    )
    if not delete_count then
        Log(kLogWarn, "Error while deleting untouched sessions: %s" % { err })
    end
    Log(kLogInfo, "Deleted %d expired sessions." % { delete_count })
    -- Regenerate CSRF protection tokens for sessions that have not been used in
    -- 4 hours. (Avoid doing this too much or you'll break browser sessions.)
    local token_regen_point = now - (4 * 60 * 60)
    local sessions, s_err = self.conn:fetchAll(
        queries.accounts.get_sessions_older_than_stamp,
        token_regen_point
    )
    if not sessions then
        Log(
            kLogWarn,
            "Error while fetching sessions in need of CSRF token updates: %s"
                % { s_err }
        )
        return delete_count
    end
    local updated_count = 0
    for i = 1, #sessions do
        local new_token = NanoID.simple_with_prefix(IdPrefixes.csrf)
        -- TODO: this refreshes the token every hour once it's hit 4 hours old. Is that a problem?
        local t_ok, t_err = self.conn:execute(
            queries.accounts.update_csrf_token_for_session,
            new_token,
            sessions[i].session_id
        )
        if not t_ok then
            Log(
                kLogWarn,
                "Error while updating session %s: %s"
                    % { sessions[i].session_id, t_err }
            )
        else
            updated_count = updated_count + 1
        end
    end
    Log(
        kLogInfo,
        "Updated CSRF protection tokens for %d sessions." % { updated_count }
    )
    return delete_count + updated_count
end

function Accounts:findUserBySessionId(session_id)
    return fetchOneExactly(
        self.conn,
        queries.accounts.get_user_by_session,
        session_id
    )
end

function Accounts:findUserByTelegramUserID(tg_userid)
    return self.conn:fetchOne(queries.accounts.get_user_by_tg_id, tg_userid)
end

function Accounts:getAllTelegramAccountsForUser(user_id)
    return self.conn:fetchAll(
        queries.accounts.get_telegram_accounts_by_user_id,
        user_id
    )
end

function Accounts:getAllUserIds()
    return self.conn:fetchAll(queries.accounts.get_all_user_ids)
end

function Accounts:addTelegramLinkRequest(
    request_id,
    display_name,
    username,
    tg_userid
)
    local now, clock_err = unix.clock_gettime()
    if not now then
        return nil, clock_err
    end
    return self.conn:execute(
        queries.accounts.insert_telegram_link_request,
        request_id,
        display_name,
        username,
        tg_userid,
        now
    )
end

function Accounts:setTelegramUserIDForUserAndDeleteLinkRequest(
    user_id,
    tg_userid,
    request_id
)
    local SP_TGLINK = "link_telegram_to_user"
    self:create_savepoint(SP_TGLINK)
    local insert_ok, insert_err = self.conn:execute(
        queries.accounts.insert_telegram_account_id,
        user_id,
        tg_userid
    )
    if not insert_ok then
        self:rollback(SP_TGLINK)
        return nil, insert_err
    end
    local delete_ok, delete_err = self.conn:execute(
        queries.accounts.delete_telegram_link_request,
        request_id
    )
    if not delete_ok then
        self:rollback(SP_TGLINK)
        return nil, delete_err
    end
    self:release_savepoint(SP_TGLINK)
    return true
end

function Accounts:getTelegramLinkRequestById(request_id)
    return fetchOneExactly(
        self.conn,
        queries.accounts.get_telegram_link_request_by_id,
        request_id
    )
end

function Accounts:deleteTelegramLinkRequest(request_id)
    return self.conn:execute(
        queries.accounts.delete_telegram_link_request,
        request_id
    )
end

function Accounts:create_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("SAVEPOINT " .. name .. ";")
end

function Accounts:release_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("RELEASE SAVEPOINT " .. name .. ";")
end

function Accounts:rollback(to_savepoint)
    if to_savepoint and type(to_savepoint) == "string" then
        return self.conn:execute(
            "ROLLBACK TO %s; RELEASE SAVEPOINT %s;"
                % { to_savepoint, to_savepoint }
        )
    else
        return self.conn:execute("ROLLBACK;")
    end
end

local ImageKind = {
    Image = 1,
    Video = 2,
    Audio = 3,
    Flash = 4,
}
local Rating = {
    General = 1,
    Adult = 2,
    Explicit = 3,
    HardKink = 4,
}
local Category = {
    Stash = 1,
    Reference = 2,
    Moodboard = 4,
    Sharing = 8,
    OwnArt = 16,
}
local ImageKindLoopable = {}
local RatingLoopable = {}
local CategoryLoopable = {}

for k, v in pairs(ImageKind) do
    ImageKindLoopable[v] = k
end
for k, v in pairs(Rating) do
    RatingLoopable[v] = k
end
for k, v in pairs(Category) do
    CategoryLoopable[#CategoryLoopable + 1] = { v, k }
end
table.sort(CategoryLoopable, function(a, b)
    return a[1] < b[1]
end)

return {
    Accounts = Accounts,
    Model = Model,
    -- k is for konstant! I passed spelling :)
    k = {
        ImageKind = ImageKind,
        Rating = Rating,
        Category = Category,
        ImageKindLoopable = ImageKindLoopable,
        RatingLoopable = RatingLoopable,
        CategoryLoopable = CategoryLoopable,
    },
}

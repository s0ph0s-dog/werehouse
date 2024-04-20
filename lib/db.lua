
local ACCOUNTS_DB_FILE = "hyperphantasia-accounts.sqlite3"
local USER_DB_FILE_TEMPLATE = "hyperphantasia-%s.sqlite3"

local accounts_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "users" (
        "user_id" TEXT NOT NULL UNIQUE,
        "username" TEXT NOT NULL UNIQUE,
        "password" TEXT NOT NULL,
        PRIMARY KEY("user_id")
    );

    CREATE TABLE IF NOT EXISTS "sessions" (
        "session_id" TEXT NOT NULL UNIQUE,
        "created" TEXT NOT NULL,
        "user_id" TEXT NOT NULL,
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
        "file" TEXT NOT NULL,
        "mime_type" TEXT NOT NULL,
        "category" INTEGER,
        "saved_at" TEXT NOT NULL,
        "rating" INTEGER,
        "kind" INTEGER,
        PRIMARY KEY("image_id")
    );

    CREATE TABLE IF NOT EXISTS "tags" (
        "tag_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT NOT NULL,
        "description" TEXT NOT NULL,
        PRIMARY KEY("tag_id")
    );

    CREATE TABLE IF NOT EXISTS "image_tags" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("image_id", "tag_id"),
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
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
        "name" TEXT NOT NULL,
        "gallery_uri" TEXT NOT NULL,
        PRIMARY KEY("artist_id")
    );

    CREATE TABLE IF NOT EXISTS "artist_handles" (
        "artist_id" INTEGER NOT NULL UNIQUE,
        "handle" TEXT NOT NULL,
        "domain" TEXT NOT NULL,
        PRIMARY KEY("artist_id", "handle", "domain"),
        FOREIGN KEY ("artist_id") REFERENCES "artists"("artist_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "image_artists" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "artist_id" INTEGER NOT NULL,
        PRIMARY KEY("image_id", "artist_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
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
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "pl_entry_negative_tags" (
        "spl_entry_id" INTEGER NOT NULL UNIQUE,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id", "tag_id"),
        FOREIGN KEY ("spl_entry_id") REFERENCES "share_ping_list_entry"("spl_entry_id")
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
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS "thumbnails" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "thumbnail" BLOB NOT NULL,
        PRIMARY KEY("image_id"),
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
        insert_user =  [[INSERT INTO "users" ("user_id", "username", "password")
            VALUES (?, ?, ?);]],
        assign_invite = [[UPDATE "invites" SET "invitee" = ?
            WHERE invite_id = ? AND "invitee" = NULL;]],
        find_user_by_name = [[SELECT "user_id", "username", "password"
            FROM "users"
            WHERE "username" = ?;]],
        insert_session = [[INSERT INTO "sessions" ("session_id", "user_id", "created")
            VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));]],
        get_session = [[SELECT "created", "user_id" from "sessions"
            WHERE "session_id" = ?;]],
        get_user_by_session = [[SELECT u.user_id, u.username FROM "users" AS u
            INNER JOIN "sessions" on u.user_id = sessions.user_id
            WHERE sessions.session_id = ?;]],
        get_all_user_ids = [[SELECT user_id FROM "users";]],
    },
    model = {
        get_recent_queue_entries = [[SELECT qid, link, tombstone, added_on, status
            FROM queue
            ORDER BY added_on DESC
            LIMIT 20;]],
        get_all_queue_entries = [[SELECT qid, link, image, image_mime_type, tombstone, added_on, status, disambiguation_request, disambiguation_data
            FROM queue
            ORDER BY added_on DESC;]],
        get_all_active_queue_entries = [[SELECT qid, link, image, image_mime_type, tombstone, added_on, status
            FROM queue
            WHERE tombstone = 0
            ORDER BY added_on DESC;]],
        get_queue_image_by_id = [[SELECT image, image_mime_type FROM queue
            WHERE qid = ?;]],
        get_recent_image_entries = [[SELECT image_id, file
            FROM images
            ORDER BY saved_at DESC
            LIMIT 20;]],
        get_image_by_id = [[SELECT image_id, file, saved_at, category, rating, kind
            FROM images
            WHERE image_id = ?;]],
        get_artists_for_image = [[SELECT artists.artist_id, artists.name
            FROM artists INNER JOIN image_artists
            ON image_artists.artist_id = artists.artist_id
            WHERE image_artists.image_id = ?;]],
        get_tags_for_image = [[SELECT tags.tag_id, tags.name
            FROM tags INNER JOIN image_tags
            ON image_tags.tag_id = tags.tag_id
            WHERE image_tags.image_id = ?;]],
        get_sources_for_image = [[SELECT link
            FROM sources
            WHERE image_id = ?;]],
        insert_link_into_queue = [[INSERT INTO
            "queue" ("link", "image", "image_mime_type", "tombstone", "added_on", "status")
            VALUES (?, NULL, NULL, 0, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), '');]],
        insert_image_into_queue = [[INSERT INTO
            "queue" ("link", "image", "image_mime_type", "tombstone", "added_on", "status")
            VALUES (NULL, ?, ?, 0, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), '');]],
        insert_image_into_images = [[INSERT INTO
            "images" ("file", "mime_type", "saved_at")
            VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));]],
        delete_item_from_queue = [[DELETE FROM "queue" WHERE qid = ?;]],
        update_queue_item_status = [[UPDATE "queue"
            SET "status" = ?, "tombstone" = ?
            WHERE qid = ?;]],
        update_queue_item_disambiguation = [[UPDATE "queue"
            SET "disambiguation_request" = ?
            WHERE qid = ?;]],
    }
}

---@class Model
---@field conn table
---@field user_id string
local Model = {}

function Model:new(o, user_id)
    o = o or {}
    local filename = USER_DB_FILE_TEMPLATE % {user_id}
    o.conn = Fm.makeStorage(filename, user_setup)
    o.user_id = user_id
    setmetatable(o, self)
    self.__index = self
    return o
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

function Model:getRecentImageEntries()
    return self.conn:fetchAll(queries.model.get_recent_image_entries)
end

function Model:getQueueImageById(qid)
    return self.conn:fetchOne(queries.model.get_queue_image_by_id, qid)
end

function Model:getImageById(image_id)
    return self.conn:fetchOne(queries.model.get_image_by_id, image_id)
end

function Model:getArtistsForImage(image_id)
    return self.conn:fetchAll(queries.model.get_artists_for_image, image_id)
end

function Model:getTagsForImage(image_id)
    return self.conn:fetchAll(queries.model.get_tags_for_image, image_id)
end

function Model:getSourcesForImage(image_id)
    return self.conn:fetchAll(queries.model.get_sources_for_image, image_id)
end

function Model:enqueueLink(link)
    return self.conn:execute(queries.model.insert_link_into_queue, link)
end

function Model:enqueueImage(mime_type, image_data)
    return self.conn:execute(queries.model.insert_image_into_queue, image_data, mime_type)
end

function Model:setQueueItemStatus(queue_id, tombstone, new_status)
    return self.conn:execute(queries.model.update_queue_item_status, new_status, tombstone, queue_id)
end

function Model:setQueueItemDisambiguationRequest(queue_id, disambiguation_data)
    return self.conn:execute(
        queries.model.update_queue_item_disambiguation,
        disambiguation_data,
        queue_id
    )
end

function Model:insertImage(image_file, mime_type)
    return self.conn:execute(
        queries.model.insert_image_into_images, image_file, mime_type
    )
end

function Model:deleteFromQueue(queue_id)
    return self.conn:execute(queries.model.delete_item_from_queue, queue_id)
end

function Model:create_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute(
        "SAVEPOINT " .. name .. ";"
    )
end

function Model:release_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute(
        "RELEASE SAVEPOINT " .. name .. ";"
    )
end

function Model:rollback(to_savepoint)
    if to_savepoint and type(to_savepoint) == "string" then
        return self.conn:execute("ROLLBACK TO " .. to_savepoint .. ";")
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

function Accounts:bootstrapInvites()
    local users = self.conn:fetchOne(queries.accounts.count_users)
    if not users or users.count < 1 then
        -- TODO: see if there is an unused invite, and retrieve that instead of
        -- making a new one.
        local invite_id = Uuid()
        self.conn:execute(queries.accounts.bootstrap_invite, invite_id)
        Log(kLogWarn, "There are no accounts in the database. Register one using this link: http://127.0.0.1:8082/accept-invite/%s" % {invite_id})
    end
end

function Accounts:findInvite(invite_id)
    local invite = self.conn:fetchOne(queries.accounts.find_invite, invite_id)
    return invite
end

function Accounts:acceptInvite(invite_id, username, password_hash)
    local user_id = Uuid()
    local result, errmsg = self.conn:execute{
        {queries.accounts.insert_user, user_id, username, password_hash},
        {queries.accounts.assign_invite, user_id, invite_id},
    }
    Model:new(nil, user_id)
    return result, errmsg
end

function Accounts:findUser(username)
    return self.conn:fetchOne(queries.accounts.find_user_by_name, username)
end

function Accounts:createSessionForUser(user_id)
    local session_id = Uuid()
    local result, errmsg = self.conn:execute(queries.accounts.insert_session, session_id, user_id)
    if not result then
        return result, errmsg
    else
        return session_id
    end
end

function Accounts:findSessionById(session_id)
    return self.conn:fetchOne(queries.accounts.get_session, session_id)
end

function Accounts:findUserBySessionId(session_id)
    return self.conn:fetchOne(queries.accounts.get_user_by_session, session_id)
end

function Accounts:getAllUserIds()
    return self.conn:fetchAll(queries.accounts.get_all_user_ids)
end

return {
    Accounts = Accounts,
    Model = Model,
}

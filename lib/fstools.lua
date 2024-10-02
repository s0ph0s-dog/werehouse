local MIME_TO_EXT = {
    ["image/jpeg"] = ".jpg",
    ["image/png"] = ".png",
    ["image/webp"] = ".webp",
    ["text/plain"] = ".txt",
    ["video/webm"] = ".webm",
    ["video/mp4"] = ".mp4",
}

local MIME_TO_KIND = {
    ["image/jpeg"] = DbUtil.k.ImageKind.Image,
    ["image/png"] = DbUtil.k.ImageKind.Image,
    ["image/webp"] = DbUtil.k.ImageKind.Image,
    ["image/gif"] = DbUtil.k.ImageKind.Image,
    ["video/webm"] = DbUtil.k.ImageKind.Video,
    ["video/mp4"] = DbUtil.k.ImageKind.Video,
}

local function make_image_path_from_filename(filename)
    local parent_dir = "./images/%s/%s/"
        % {
            filename:sub(1, 1),
            filename:sub(2, 2),
        }
    local path = parent_dir .. filename
    return parent_dir, path
end

local function make_queue_path_from_filename(filename, user_id)
    local parent_dir = "./queue/%s/%s/"
        % {
            user_id,
            filename:sub(1, 1),
        }
    local path = parent_dir .. filename
    return parent_dir, path
end

local function hash_to_filesystem_safe(hash)
    local b64 = EncodeBase64(hash)
    local safe = b64:gsub("[+/]", { ["+"] = "-", ["/"] = "_" })
    return safe
end

local function save_image_generic(path_func, image_data, image_mime_type, bonus)
    assert(image_data ~= nil, "can't save nil image data")
    local hash_raw = GetCryptoHash("SHA256", image_data)
    local hash = hash_to_filesystem_safe(hash_raw)
    local ext = MIME_TO_EXT[image_mime_type] or ""
    local filename = hash .. ext
    local parent_dir, path = path_func(filename, bonus)
    Log(kLogInfo, "parent_dir: %s" % { parent_dir })
    unix.makedirs(parent_dir, 0755)
    local w_ok, w_err =
        Barf(path, image_data, 0644, unix.O_WRONLY | unix.O_CREAT | unix.O_EXCL)
    if not w_ok then
        unix.unlink(path)
        return nil, "Error writing file: %s" % { w_err }
    end
    return filename
end

local function save_image(image_data, image_mime_type)
    return save_image_generic(
        make_image_path_from_filename,
        image_data,
        image_mime_type
    )
end

local function save_queue(image_data, image_mime_type, user_id)
    return save_image_generic(
        make_queue_path_from_filename,
        image_data,
        image_mime_type,
        user_id
    )
end

local function load_image_generic(path_func, image_filename, bonus)
    local _, path = path_func(image_filename, bonus)
    return Slurp(path)
end

local function load_image(image_filename)
    return load_image_generic(make_image_path_from_filename, image_filename)
end

local function load_queue(image_filename, user_id)
    return load_image_generic(
        make_queue_path_from_filename,
        image_filename,
        user_id
    )
end

local function list_all_image_files()
    local image_files = {}
    for d1_name, d1_kind in assert(unix.opendir("./images")) do
        if d1_name ~= "." and d1_name ~= ".." and d1_kind == unix.DT_DIR then
            for d2_name, d2_kind in assert(unix.opendir("./images/" .. d1_name)) do
                if
                    d2_name ~= "."
                    and d2_name ~= ".."
                    and d2_kind == unix.DT_DIR
                then
                    for file_name, file_kind in
                        assert(
                            unix.opendir(
                                "./images/" .. d1_name .. "/" .. d2_name
                            )
                        )
                    do
                        if file_kind == unix.DT_REG then
                            image_files[#image_files + 1] = file_name
                        end
                    end
                end
            end
        end
    end
    return image_files
end

local function for_each_image_file(fn)
    local d1 = assert(unix.opendir("./images"))
    for d1_name, d1_kind in d1 do
        if d1_name ~= "." and d1_name ~= ".." and d1_kind == unix.DT_DIR then
            local d2 = assert(unix.opendir("./images/" .. d1_name))
            for d2_name, d2_kind in d2 do
                if
                    d2_name ~= "."
                    and d2_name ~= ".."
                    and d2_kind == unix.DT_DIR
                then
                    local parent_path = "./images/%s/%s" % { d1_name, d2_name }
                    local parent_dir = assert(unix.opendir(parent_path))
                    for file_name, file_kind in parent_dir do
                        if file_kind == unix.DT_REG then
                            fn(file_name, "%s/%s" % { parent_path, file_name })
                        end
                    end
                    parent_dir:close()
                end
            end
            d2:close()
        end
    end
    d1:close()
end

local function for_each_queue_file(user, fn)
    local qdir = unix.opendir("./queue/" .. user)
    if not qdir then
        return
    end
    for d1_name, d1_kind in qdir do
        if d1_name ~= "." and d1_name ~= ".." and d1_kind == unix.DT_DIR then
            local parent_path = "./queue/%s/%s" % { user, d1_name }
            local parent_dir = assert(unix.opendir(parent_path))
            for file_name, file_kind in parent_dir do
                if file_kind == unix.DT_REG then
                    fn(file_name, "%s/%s" % { parent_path, file_name })
                end
            end
            parent_dir:close()
        end
    end
    qdir:close()
end

return {
    save_image = save_image,
    save_queue = save_queue,
    load_image = load_image,
    load_queue = load_queue,
    make_image_path_from_filename = make_image_path_from_filename,
    make_queue_path_from_filename = make_queue_path_from_filename,
    list_all_image_files = list_all_image_files,
    for_each_image_file = for_each_image_file,
    for_each_queue_file = for_each_queue_file,
    MIME_TO_EXT = MIME_TO_EXT,
    MIME_TO_KIND = MIME_TO_KIND,
}

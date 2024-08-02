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

local function hash_to_filesystem_safe(hash)
    local b64 = EncodeBase64(hash)
    local safe = b64:gsub("[+/]", { ["+"] = "-", ["/"] = "_" })
    return safe
end

local function save_image(image_data, image_mime_type)
    assert(image_data ~= nil)
    local hash_raw = GetCryptoHash("SHA256", image_data)
    local hash = hash_to_filesystem_safe(hash_raw)
    local ext = MIME_TO_EXT[image_mime_type] or ""
    local filename = hash .. ext
    local parent_dir, path = make_image_path_from_filename(filename)
    Log(kLogInfo, "parent_dir: %s" % { parent_dir })
    unix.makedirs(parent_dir, 0755)
    Barf(path, image_data, 0644, unix.O_WRONLY | unix.O_CREAT | unix.O_EXCL)
    return filename
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

return {
    save_image = save_image,
    make_image_path_from_filename = make_image_path_from_filename,
    list_all_image_files = list_all_image_files,
    MIME_TO_EXT = MIME_TO_EXT,
    MIME_TO_KIND = MIME_TO_KIND,
}

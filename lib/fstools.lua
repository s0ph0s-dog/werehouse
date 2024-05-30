local MIME_TO_EXT = {
    ["image/jpeg"] = ".jpg",
    ["image/png"] = ".png",
    ["image/webp"] = ".webp",
    ["text/plain"] = ".txt",
    ["video/webm"] = ".webm",
    ["video/mp4"] = ".mp4",
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

return {
    save_image = save_image,
    make_image_path_from_filename = make_image_path_from_filename,
    MIME_TO_EXT = MIME_TO_EXT,
}

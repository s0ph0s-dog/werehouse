local IMAGE_DESCRIPTOR_LENGTH = 10

local function calculate_color_table_size(byte)
    if (byte & 0x80) == 0x80 then
        local entry_count = byte & 0x07
        local size = 2 ^ (entry_count + 1) * 3
        Log(kLogDebug, "size=%d" % { size })
        return size
    else
        return 0
    end
end

local function calculate_cumulative_subblock_length(bitstream, start_idx)
    local total_sub_block_length = 0
    local sub_block_count = 0
    local current_index = start_idx
    local sub_block_size
    repeat
        current_index = start_idx + total_sub_block_length
        sub_block_size = bitstream:byte(current_index)
        Log(kLogDebug, "current_index, sub_block_size = (%x, %d)" % {
            current_index,
            sub_block_size,
        })
        -- +1 for the sub-block size byte
        total_sub_block_length = total_sub_block_length + sub_block_size + 1
        sub_block_count = sub_block_count + 1
        Log(kLogDebug, "sub_block_count=%d" % { sub_block_count })
    until sub_block_size == 0
    return total_sub_block_length
end

---@param bitstream string The binary data of the file
---@return boolean # True if the file is a GIF file, false otherwise.
---@return boolean # True if the GIF file is animated, false otherwise.
local function is_gif(bitstream)
    -- Does the file have a GIF header?
    local maybe_gif_header = bitstream:sub(1, 3)
    Log(kLogDebug, maybe_gif_header)
    if maybe_gif_header ~= "GIF" then
        return false, false
    end
    -- GIF89a supports the animation extensions, GIF87a does not.
    local maybe_version_code = bitstream:sub(4, 6)
    Log(kLogDebug, maybe_version_code)
    if maybe_version_code ~= "89a" then
        return true, false
    end
    local block_start_idx = 14 + calculate_color_table_size(bitstream:byte(11))
    local current_block_idx = block_start_idx
    local image_descriptor_count = 0
    local max_delay_ms = 0
    while current_block_idx <= #bitstream do
        Log(kLogDebug, "current_block_idx=%d" % { current_block_idx })
        local kind = bitstream:byte(current_block_idx)
        local current_block_size = 0
        if kind == 0x21 then
            Log(kLogInfo, "Extension Introducer")
            local ext_kind = bitstream:byte(current_block_idx + 1)
            if ext_kind == 0xF9 then
                Log(kLogInfo, "Graphics Control Extension")
                local delay_ms_low_order = bitstream:byte(current_block_idx + 4)
                local delay_ms_high_order =
                    bitstream:byte(current_block_idx + 5)
                local delay_ms = (delay_ms_high_order << 8) | delay_ms_low_order
                if delay_ms > max_delay_ms then
                    max_delay_ms = delay_ms
                end
            elseif ext_kind == 0x01 then
                Log(kLogInfo, "Plain Text Extension")
            elseif ext_kind == 0xFF then
                Log(kLogInfo, "Application Extension")
            elseif ext_kind == 0xFE then
                Log(kLogInfo, "Comment Extension")
            end
            current_block_size = bitstream:byte(current_block_idx + 2)
            Log(kLogDebug, "current_block_size=%d" % { current_block_size })
            -- +3 for application extension introducer and kind
            local subblock_length = calculate_cumulative_subblock_length(
                bitstream,
                current_block_idx + current_block_size + 3
            )
            -- +3 because there are 3 bytes before the subblock
            current_block_size = current_block_size + subblock_length + 3
        elseif kind == 0x2C then
            Log(kLogInfo, "Image Separator")
            image_descriptor_count = image_descriptor_count + 1
            local data_start_idx = current_block_idx
                + IMAGE_DESCRIPTOR_LENGTH
                + calculate_color_table_size(
                    bitstream:byte(current_block_idx + IMAGE_DESCRIPTOR_LENGTH)
                )
            local image_data_length = calculate_cumulative_subblock_length(
                bitstream,
                current_block_idx + IMAGE_DESCRIPTOR_LENGTH + 1
            )
            current_block_size = IMAGE_DESCRIPTOR_LENGTH + 1 + image_data_length
        elseif kind == 0x3B then
            Log(kLogInfo, "Trailer")
            current_block_size = 1
        else
            Log(
                kLogWarn,
                "Something went wrong, unknown byte at %d: %d"
                    % { current_block_idx, kind }
            )
        end
        current_block_idx = current_block_idx + current_block_size
        if current_block_size == 0 then
            Log(
                kLogError,
                "block size was 0, this is probably a bug, bailing and assuming animated"
            )
            return true, true
        end
    end
    return true, (image_descriptor_count > 1 and max_delay_ms > 0)
end

return {
    is_gif = is_gif,
}

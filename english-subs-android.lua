local mp = require "mp"
local utils = require "mp.utils"

-- ============================================================
-- User settings
-- ============================================================

local o = {
    landscape_panel_ratio = 0.60,
    portrait_panel_ratio = 0.60,

    prev_count = 2,
    next_count = 2,

    font_size = 52,
    current_font_size = 52,

    line_gap = 14,
    block_gap = 22,

    margin_x = 28,
    margin_y = 28,

    current_marker = "",

    -- Wrapping width correction.
    -- 1.00 = conservative/default estimate
    -- 1.15-1.25 = use more of the panel width
    wrap_width_scale = 1.20,
}

local overlay = mp.create_osd_overlay("ass-events")
local cues = {}
local enabled = true
local active_index = nil
local last_render_key = ""
local last_orientation = nil

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ass_escape(s)
    if not s then return "" end
    local ok, escaped = pcall(mp.command_native, {"escape-ass", s})
    if ok and escaped then return escaped end
    return s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
end

local function basename_no_ext(path)
    if not path then return nil end
    local name = path:gsub("\\", "/"):match("([^/]+)$") or path
    return name:gsub("%.[^%.]+$", "")
end

local function dirname(path)
    if not path then return nil end
    local d = path:gsub("\\", "/"):match("^(.*)/[^/]*$")
    return (d and d ~= "") and d or "."
end

local function parse_time(t)
    local h,m,s,ms = t:match("(%d+):(%d+):(%d+)[,.](%d+)")
    if not h then
        h,m,s = t:match("(%d+):(%d+):(%d+)")
        ms = "0"
    end
    if not h then return nil end
    return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) + tonumber(ms)/(10^#ms)
end

local function line_kind(s)
    local i = 1

    while i <= #s do
        local b = s:byte(i)

        if b and b >= 0x80 then
            return "cjk"
        end

        i = i + 1
    end

    return "latin"
end

local function clean_text(s)
    s = s:gsub("<br%s*/?>", "\n")
         :gsub("<[^>]->", "")
         :gsub("{\\[^}]-}", "")
         :gsub("\r", "")

    local source_lines = {}

    for line in (s .. "\n"):gmatch("(.-)\n") do
        line = trim(line)

        if line ~= "" then
            table.insert(
                source_lines,
                {
                    text = line,
                    kind = line_kind(line)
                }
            )
        end
    end

    if #source_lines == 0 then
        return ""
    end

    local groups = {}
    local current_kind = nil
    local current_text = ""

    for _, item in ipairs(source_lines) do
        if current_kind == nil then
            current_kind = item.kind
            current_text = item.text

        elseif item.kind == current_kind then
            if current_kind == "latin" then
                current_text = current_text .. " " .. item.text
            else
                current_text = current_text .. item.text
            end

        else
            table.insert(groups, trim(current_text))
            current_kind = item.kind
            current_text = item.text
        end
    end

    if current_text ~= "" then
        table.insert(groups, trim(current_text))
    end

    -- English and Japanese groups stay on separate logical lines.
    return table.concat(groups, "\n")
end

local function parse_srt(path)
    local f = io.open(path, "rb")
    if not f then
        mp.msg.error("Could not open SRT: " .. tostring(path))
        return {}
    end
    local data = f:read("*all")
    f:close()

    data = data:gsub("^\239\187\191",""):gsub("\r\n","\n"):gsub("\r","\n") .. "\n\n"

    local result = {}
    for block in data:gmatch("(.-)\n\n+") do
        local lines = {}
        for line in block:gmatch("[^\n]+") do
            table.insert(lines, line)
        end

        local ti = nil
        for i,line in ipairs(lines) do
            if line:find("%-%->") then ti = i break end
        end

        if ti then
            local left,right = lines[ti]:match("^%s*(.-)%s+%-%->%s+(.-)%s*$")
            if left and right then
                right = right:match("^([^%s]+)") or right
                local st,et = parse_time(left),parse_time(right)
                if st and et then
                    local parts = {}
                    for i=ti+1,#lines do table.insert(parts,lines[i]) end
                    local text = clean_text(table.concat(parts,"\n"))
                    if text ~= "" then
                        table.insert(result,{start=st,finish=et,text=text})
                    end
                end
            end
        end
    end

    table.sort(result,function(a,b) return a.start < b.start end)
    return result
end

local function choose_external_srt()
    local tracks = mp.get_property_native("track-list") or {}
    local selected,fallback = nil,nil

    for _,track in ipairs(tracks) do
        if track.type == "sub" and track.external and track["external-filename"] then
            local path = track["external-filename"]
            if path:lower():match("%.srt$") then
                if track.selected then selected = path end
                fallback = fallback or path
            end
        end
    end
    return selected or fallback
end

local function choose_matching_srt()
    local media_path = mp.get_property("path")
    if not media_path or media_path:match("^%a+://") then return nil end

    local media_base = basename_no_ext(media_path)
    local dir = dirname(media_path)
    if not media_base or not dir then return nil end

    local base_lower = media_base:lower()
    local candidates = {}

    for _,name in ipairs(utils.readdir(dir,"files") or {}) do
        if name:lower():match("%.srt$") then
            local stem = name:gsub("%.[^%.]+$","")
            local stem_lower = stem:lower()
            if stem_lower == base_lower or stem_lower:sub(1,#base_lower) == base_lower then
                table.insert(candidates,name)
            end
        end
    end

    table.sort(candidates,function(a,b)
        if #a == #b then return a:lower() < b:lower() end
        return #a < #b
    end)

    if #candidates == 0 then return nil end
    return dir .. "/" .. candidates[1]
end

local function find_active_index(t)
    if #cues == 0 then return nil end
    for i,cue in ipairs(cues) do
        if t >= cue.start and t <= cue.finish then return i end
        if cue.start > t then return i end
    end
    return #cues
end

local function get_orientation(width,height)
    return (height > width) and "portrait" or "landscape"
end

local function apply_video_layout(width,height)
    local orientation = get_orientation(width,height)

    if orientation == "portrait" then
        mp.set_property_number("video-margin-ratio-right",0)
        mp.set_property_number("video-margin-ratio-bottom",o.portrait_panel_ratio)
        mp.set_property_number("video-align-x",0)
        mp.set_property_number("video-align-y",-1)
    else
        mp.set_property_number("video-margin-ratio-bottom",0)
        mp.set_property_number("video-margin-ratio-right",o.landscape_panel_ratio)
        mp.set_property_number("video-align-x",-1)
        mp.set_property_number("video-align-y",0)
    end

    if orientation ~= last_orientation then
        last_orientation = orientation
        last_render_key = ""
    end
    return orientation
end


local function utf8_next(s, i)
    local b = s:byte(i)

    if not b then
        return nil, i
    end

    local len

    if b < 0x80 then
        len = 1
    elseif b < 0xE0 then
        len = 2
    elseif b < 0xF0 then
        len = 3
    else
        len = 4
    end

    return s:sub(i, i + len - 1), i + len
end

local function char_width_px(ch, font_size)
    local b = ch:byte(1)

    if not b then
        return 0
    end

    if b >= 0x80 then
        -- Japanese / CJK / full-width characters.
        return font_size * 0.82
    end

    if ch == " " then
        return font_size * 0.28
    end

    if ch:match("[ilI%.,'`:;!|]") then
        return font_size * 0.24
    end

    if ch:match("[MW@%%&QO]") then
        return font_size * 0.66
    end

    if ch:match("[mw]") then
        return font_size * 0.60
    end

    if ch:match("[A-Z]") then
        return font_size * 0.48
    end

    if ch:match("[0-9]") then
        return font_size * 0.48
    end

    return font_size * 0.46
end

local function text_width_px(s, font_size)
    local width = 0
    local i = 1

    while i <= #s do
        local ch
        ch, i = utf8_next(s, i)

        if ch then
            width = width + char_width_px(ch, font_size)
        end
    end

    return width
end

local function tokenize_mixed_line(s)
    local tokens = {}
    local ascii_word = ""
    local i = 1

    local function flush_ascii()
        if ascii_word ~= "" then
            table.insert(tokens, ascii_word)
            ascii_word = ""
        end
    end

    while i <= #s do
        local ch
        ch, i = utf8_next(s, i)

        if not ch then
            break
        end

        local b = ch:byte(1)

        if b and b >= 0x80 then
            flush_ascii()
            table.insert(tokens, ch)

        elseif ch == " " then
            flush_ascii()
            table.insert(tokens, " ")

        else
            ascii_word = ascii_word .. ch
        end
    end

    flush_ascii()

    return tokens
end

local function split_long_ascii_token(token, font_size, max_width)
    local out = {}
    local current = ""
    local width = 0
    local i = 1

    while i <= #token do
        local ch
        ch, i = utf8_next(token, i)

        local cw = char_width_px(ch, font_size)

        if current ~= "" and width + cw > max_width then
            table.insert(out, current)
            current = ch
            width = cw
        else
            current = current .. ch
            width = width + cw
        end
    end

    if current ~= "" then
        table.insert(out, current)
    end

    return out
end

local function wrap_logical_line(line, font_size, max_width)
    line = trim(line)

    if line == "" then
        return {""}
    end

    local tokens = tokenize_mixed_line(line)
    local result = {}
    local current = ""
    local current_width = 0

    local function flush()
        local out = trim(current)

        if out ~= "" then
            table.insert(result, out)
        end

        current = ""
        current_width = 0
    end

    for _, token in ipairs(tokens) do
        local token_width = text_width_px(token, font_size)

        if token == " " then
            if current ~= "" then
                current = current .. " "
                current_width =
                    current_width
                    + token_width
            end

        elseif token_width > max_width then
            flush()

            local pieces =
                split_long_ascii_token(
                    token,
                    font_size,
                    max_width
                )

            for p = 1, #pieces - 1 do
                table.insert(
                    result,
                    pieces[p]
                )
            end

            current =
                pieces[#pieces]
                or ""

            current_width =
                text_width_px(
                    current,
                    font_size
                )

        elseif current ~= ""
            and current_width + token_width > max_width
        then
            flush()
            current = token
            current_width = token_width

        else
            current = current .. token
            current_width =
                current_width
                + token_width
        end
    end

    flush()

    if #result == 0 then
        return {""}
    end

    return result
end

local function wrap_text(text, font_size, max_width)
    local result = {}

    for logical_line in
        (text .. "\n"):gmatch("(.-)\n")
    do
        local wrapped =
            wrap_logical_line(
                logical_line,
                font_size,
                max_width
            )

        for _, line in ipairs(wrapped) do
            table.insert(result, line)
        end
    end

    return result
end

local function render()
    if not enabled or #cues == 0 then
        overlay.data = ""
        overlay:update()
        return
    end

    local width, height = mp.get_osd_size()

    if not width
        or not height
        or width <= 0
        or height <= 0
    then
        return
    end

    local orientation =
        apply_video_layout(
            width,
            height
        )

    local index =
        find_active_index(
            mp.get_property_number(
                "time-pos",
                0
            )
        )

    if not index then
        return
    end

    active_index = index

    local render_key =
        tostring(index)
        .. ":"
        .. tostring(width)
        .. ":"
        .. tostring(height)
        .. ":"
        .. orientation

    if render_key == last_render_key then
        return
    end

    last_render_key = render_key

    overlay.res_x = width
    overlay.res_y = height

    local panel_left = 0
    local panel_top = 0
    local panel_width = width
    local panel_height = height

    if orientation == "portrait" then
        panel_top =
            math.floor(
                height
                * (
                    1
                    - o.portrait_panel_ratio
                )
            )

        panel_height =
            height
            - panel_top

    else
        panel_left =
            math.floor(
                width
                * (
                    1
                    - o.landscape_panel_ratio
                )
            )

        panel_width =
            width
            - panel_left
    end

    local x =
        panel_left
        + o.margin_x

    local usable_width =
        math.max(
            1,
            panel_width
            - o.margin_x * 2
        )

    -- Allow a configurable correction because ASS font metrics
    -- differ from our lightweight width estimate.
    local max_text_width =
        usable_width * o.wrap_width_scale

    local first =
        math.max(
            1,
            index - o.prev_count
        )

    local last =
        math.min(
            #cues,
            index + o.next_count
        )

    local blocks = {}
    local total_height = 0

    for i = first, last do
        local is_current =
            (i == index)

        local marker =
            is_current
            and o.current_marker
            or ""

        local font_size =
            is_current
            and o.current_font_size
            or o.font_size

        local lines =
            wrap_text(
                marker
                .. cues[i].text,
                font_size,
                max_text_width
            )

        local block_height =
            #lines
            * (
                font_size
                + o.line_gap
            )
            + o.block_gap

        table.insert(
            blocks,
            {
                lines = lines,
                font_size = font_size,
                height = block_height,
                current = is_current,
            }
        )

        total_height =
            total_height
            + block_height
    end

    local y

    if orientation == "portrait" then
        y =
            panel_top
            + math.max(
                o.margin_y,
                math.floor(
                    (
                        panel_height
                        - total_height
                    )
                    / 2
                )
            )

    else
        y =
            math.max(
                o.margin_y,
                math.floor(
                    (
                        height
                        - total_height
                    )
                    / 2
                )
            )
    end

    local ass = {}

    for _, block in ipairs(blocks) do
        local escaped_lines = {}

        for _, line in ipairs(block.lines) do
            table.insert(
                escaped_lines,
                ass_escape(line)
            )
        end

        local display_text =
            table.concat(
                escaped_lines,
                "\\N"
            )

        local style

        if block.current then
            style =
                string.format(
                    "{\\an7"
                    .. "\\q2"
                    .. "\\pos(%d,%d)"
                    .. "\\fs%d"
                    .. "\\b0"
                    .. "\\c&H80FFFF&"
                    .. "\\bord1.5"
                    .. "\\shad0"
                    .. "}",
                    x,
                    y,
                    block.font_size
                )
        else
            style =
                string.format(
                    "{\\an7"
                    .. "\\q2"
                    .. "\\pos(%d,%d)"
                    .. "\\fs%d"
                    .. "\\b0"
                    .. "\\c&HC8C8C8&"
                    .. "\\bord1"
                    .. "\\shad0"
                    .. "}",
                    x,
                    y,
                    block.font_size
                )
        end

        table.insert(
            ass,
            style
            .. display_text
        )

        y =
            y
            + block.height
    end

    overlay.data =
        table.concat(
            ass,
            "\n"
        )

    overlay:update()
end

local function load_subtitles()
    cues = {}
    active_index = nil
    last_render_key = ""

    local subtitle_path = choose_external_srt() or choose_matching_srt()

    if not subtitle_path then
        mp.osd_message("English subtitles: matching SRT not found",3)
        return
    end

    cues = parse_srt(subtitle_path)

    if #cues == 0 then
        mp.osd_message("English subtitles: SRT could not be parsed",3)
        return
    end

    render()
end

local function jump_to(index)
    if #cues == 0 then return end
    index = math.max(1,math.min(#cues,index))
    mp.commandv("seek",tostring(cues[index].start),"absolute+exact")
    last_render_key = ""
    render()
end

local function previous_subtitle()
    local time_pos = mp.get_property_number("time-pos",0)
    local index = find_active_index(time_pos) or 1

    if cues[index] and time_pos - cues[index].start > 0.7 then
        jump_to(index)
    else
        jump_to(index-1)
    end
end

local function next_subtitle()
    local index = find_active_index(mp.get_property_number("time-pos",0)) or 1
    jump_to(index+1)
end

local function replay_subtitle()
    local index = find_active_index(mp.get_property_number("time-pos",0)) or 1
    jump_to(index)
end

local function toggle_panel()
    enabled = not enabled
    last_render_key = ""
    render()
end

mp.register_event("file-loaded",function()
    mp.add_timeout(0.30,load_subtitles)
end)

mp.observe_property("time-pos","number",function()
    local index = find_active_index(mp.get_property_number("time-pos",0))
    if index ~= active_index then
        last_render_key = ""
        render()
    end
end)

mp.observe_property("osd-width","number",function()
    last_render_key = ""
    render()
end)

mp.observe_property("osd-height","number",function()
    last_render_key = ""
    render()
end)

mp.register_script_message("english-subs-prev",previous_subtitle)
mp.register_script_message("english-subs-next",next_subtitle)
mp.register_script_message("english-subs-replay",replay_subtitle)
mp.register_script_message("english-subs-toggle",toggle_panel)

mp.register_event("end-file",function()
    cues = {}
    active_index = nil
    last_render_key = ""
    last_orientation = nil
    overlay.data = ""
    overlay:update()
end)

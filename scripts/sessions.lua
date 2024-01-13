--[[
    This script automatically saves the current playlist and can reload it if the player is started in idle mode (specifically
    if there are 0 files in the playlist), or if the correct command is sent via script-messages.
    It remembers the playlist position the player was in when shutdown and reloads the playlist at that entry.
    This can be disabled with script-opts

    The script saves a text file containing the the full playlist of 5 sessions (can be changed by `max_sessions`) in the watch_later directory (changeable via opts)
    This file is saved in plaintext with the exact file paths of each playlist entry.
    Note that since it uses the same file, only the latest mpv window to be closed will be saved

    The script attempts to correct relative playlist paths using the utils.join_path function. I've tried to automatically
    detect when any non-files are loaded (if it has the sequence :// in the path), so that it'll work with URLs

    You can disable the automatic stuff and use script messages to load/save playlists as well

    save session in specified file, if nil, will use session_file in config file
    script-message save-session [session-file]

    restart mpv process
    @param disable_watch_later A bool, indicates whether to turn off watch later with --no-resume-playback, default: "yes".
    @param saving A bool, indicates whether to run save_sessions before loading the new session
    script-message restart-mpv [disable_watch_later] [saving]

    load-session will restart mpv all setting will be reload
    @param disable_watch_later A bool, indicates whether to turn off watch later with --no-resume-playback, default: "no".
    @param saving A bool, indicates whether to run save_sessions before loading the new session
    @param load_playlist A bool, indicates whether to run load whole playlist, if false, the file specified in
           maintain_pos will be loaded. Default: use the script config option
    @param maintain_pos A bool or a number, indicates the start of the playlist, if true ("yes" can be okay),
           the original position will be used as the start point, if false ("no" will be the same), the first file
           of the playlist will be used as the start point. Default: use the script config option
    script-message load-session [session-index] [disable_watch_later] [saving] [load_playlist] [maintain_pos]
    script-message load-session-prev [disable_watch_later] [saving] [load_playlist] [maintain_pos]
    script-message load-session-next [disable_watch_later] [saving] [load_playlist] [maintain_pos]


    attach-session will attach the whole session playlist in current session, all setting will remain unchanged
    script-message attach-session [session-index] [load_playlist] [maintain_pos]
    script-message attach-session-prev [load_playlist] [maintain_pos]
    script-message attach-session-next [load_playlist] [maintain_pos]

    If not included `session-file` will use the default file specified in script-opts.
    `load_playlist` controls whether the whole playlist should be restored or just the one file,
    the value can be `yes` or `no`. If not included it defaults to the value of the `load_playlist` script opt.

    modified from: https://github.com/CogentRedTester/mpv-scripts/blob/master/keep-session.lua
]]
--

local mp = require 'mp'
local utils = require 'mp.utils'
local opt = require 'mp.options'
local msg = require 'mp.msg'

local o = {
    --automatically save the prev session
    auto_save = true,

    --runs the script automatically when started in idle mode and no files are in the playlist
    auto_load = true,

    --reloads the full playlist from the previous session
    --can be individually overwritten when sending script-messages
    load_playlist = true,

    --file path of the default session file
    --save it as a .pls file to be able to open directly (though it will not maintain the playlist positions)
    session_file = "",

    -- the maximal number of sessions to save
    max_sessions = 5,

    -- only keep the same session once (session with same playlist, list order matters)
    allow_duplicated_session = false,

    -- maintain position in the playlist, do nothing if load_playlist is disabled
    maintain_pos = true,

    -- if previous session is empty, but we do have history sessions, should the empty playlist be restored?
    -- this occur if you quit manually with stop command.
    restore_empty = true,

    -- the default action to switch video via uosc menu, "attach-session" (attach_session or attach)
    -- or "load-session" (load_session or load)
    switch_action = "attach",

    -- the default execution of mpv, usage for restart_mpv
    mpv_bin = "mpv",
}

-- prepare global variables ----------------------------
script_name = mp.get_script_name()
sessions = {}
cur_session = 0 -- 0 means empty session
old_session = 0 -- 0 means empty session


-- utils function --------------------------------------
local function set_default(x, default)
    if x == "" or x == nil then
        return default
    else
        return x
    end
end

local function check_bool(arg, default)
    if arg == 'yes' or arg == true then
        return true
    elseif arg == 'no' or arg == false then
        return false
    else
        return default
    end
end

-- user api, check user argument
local function check_session_index(i)
    -- if no sessions, nothing to do
    local n = #sessions
    if n == 0 then
        mp.osd_message("no history sessions")
        return nil
    end
    -- if session index must be smaller than n ang greater than 0
    if not i then
        mp.osd_message("Please provide the session index")
        return nil
    end
    if i > n or i <= 0 then
        mp.osd_message('no session ' .. i)
        return nil
    end
    return i
end

-- internal api
local function index_session(i)
    return sessions[i]
end

local function empty_session()
    return mp.get_property_number('playlist-count', 0) == 0
end

local function match_session(session)
    local value = table.concat(session, ";", 2)
    local out = {}
    for i, v in ipairs(sessions) do
        if table.concat(v, ";", 2) == value then
            table.insert(out, i)
        end
    end
    return out
end

-- prepare arguments and set defaults ------------------------------
opt.read_options(o)

if o.switch_action == "load-session" or o.switch_action == "load_session" or o.switch_action == "load" then
    o.switch_action = "load"
else
    o.switch_action = "attach"
end
o.auto_save = check_bool(o.auto_save, true)
o.auto_load = check_bool(o.auto_load, true)
o.load_playlist = check_bool(o.load_playlist, true)
o.max_sessions = set_default(o.max_sessions, 5)
o.max_sessions = tonumber(o.max_sessions)
o.allow_duplicated_session = check_bool(o.allow_duplicated_session, false)
-- for the config file, maintain_pos can only be a bool
-- since it don't make sense to start every session with the same position
-- but we can directly pass a numeric argument in load_session or attach_session
o.maintain_pos = check_bool(o.maintain_pos, true)
o.restore_empty = check_bool(o.restore_empty, true)
o.mpv_bin = set_default(o.mpv_bin, "mpv")

-- sets the default session file to the watch_later directory or ~~/watch_later/
if o.session_file == "" or o.session_file == nil then
    local watch_later_dir = mp.get_property('watch-later-directory', "")
    if watch_later_dir == "" then watch_later_dir = "~~state/watch_later/" end
    if not watch_later_dir:find("[/\\]$") then watch_later_dir = watch_later_dir .. '/' end
    o.session_file = watch_later_dir .. "mpv-sessions"
end

o.session_file = mp.command_native({ "expand-path", o.session_file })

-- internal usage, as a flag indicating current session was run by `session_load`
o.__by_loading__ = mp.get_opt(script_name .. "-__by_loading__")
msg.debug("getting option __by_loading__:", o.__by_loading__)
o.__by_loading__ = set_default(o.__by_loading__, false)

-- helper function to change `cur_session`
-- 1. when switching session: session_attach, initialize_load
-- 2. when open new windows: initialize_open
local function set_current_session(session_index)
    msg.debug('setting session index:', session_index)
    cur_session = session_index
    if cur_session > 0 then
        sessions[cur_session][1] = mp.get_property_number("playlist-pos")
    end
    mp.osd_message("Session " .. cur_session .. "/" .. #sessions)
end

-- turns the session_file into a table and adds all the files to the playlist
-- return: adverse effect, modify global variable: sessions.
local function read_history_sessions(file)
    file = set_default(file, o.session_file)
    --loads the session file
    msg.debug('reading history sessions from', file)
    local oo = io.open(file, "r")

    --this should only occur when loading the script for the first time,
    --or if someone manually deletes the previous session file
    if not oo then
        msg.debug('no session, cancelling load')
        return
    end
    -- read session index firstly
    msg.debug('reading session index')
    -- if zero, means last session is empty
    old_session = tonumber(string.match(oo:read(), '^OldSession=(%d+)$')) or 0

    local session
    local wait_position = true

    while true do
        local line = oo:read()
        msg.debug('Debugging line:', line)
        if line == "[playlist]" or line == nil then
            if session ~= nil then
                -- check duplicates
                if not o.allow_duplicated_session then
                    local matches = match_session(session)
                    if #matches > 0 then
                        msg.debug('skip duplicated sessions')
                        return nil
                    end
                end
                -- save the previous session of read
                table.insert(sessions, session)
            end
            if line == nil then break end
            -- prepare the reading of the next session
            if #sessions == o.max_sessions then
                msg.debug('excessive sessions')
                break
            end
            wait_position = true
        elseif wait_position then
            -- the first one should be the position of current playlist
            local pos = tonumber(line)
            msg.debug('adding one session')
            session = {}
            msg.debug('playlist position at', pos)
            table.insert(session, pos)
            wait_position = false
        else
            local file_path = string.match(line, 'File=(.+)')
            msg.debug('adding file:', file_path)
            table.insert(session, file_path)
        end
    end
    msg.debug('reading', #sessions, 'sessions')
    oo:close()
end

-- return: nil if no playlist, otherwise, a table for current session
local function read_current_session()
    -- if empty session, return nil
    if empty_session() then
        return nil
    end
    -- otherwise, return a table
    local session = {}
    -- mpv uses 0 based array indices, but lua uses 1-based
    local working_directory = mp.get_property('working-directory')
    local playlist = mp.get_property_native('playlist')
    local pos = mp.get_property_number("playlist-pos")
    msg.debug('playlist position at', pos)
    table.insert(session, pos)
    for _, v in ipairs(playlist) do
        msg.debug('adding', v.filename, 'to playlist')

        --if the file is available then it attempts to expand the path in-case of relative playlists
        --presumably if the file contains a protocol then it shouldn't be expanded
        if not v.filename:find("^%a*://") then
            v.filename = utils.join_path(working_directory, v.filename)
            msg.debug('expanded path:', v.filename)
        end
        table.insert(session, v.filename)
    end
    return session
end

-- refresh current session
-- 1. when exit: save_hook
-- 2. when switch session: session_attach, session_load
-- 3. when query uosc menu
local function update_session()
    local session = read_current_session()
    if session ~= nil then
        msg.debug("refreshing current session", cur_session)
        sessions[cur_session] = session
    end
end

local function sessions_save(file)
    file = set_default(file, o.session_file)
    local oo = io.open(file, 'w')
    if not oo then return msg.error("Failed to write to file", file) end
    msg.debug('saving sessions to', file)
    if empty_session() then
        oo:write("OldSession=" .. 0 .. "\n")
    else
        oo:write("OldSession=" .. cur_session .. "\n")
    end
    for _, session in ipairs(sessions) do
        oo:write("[playlist]\n")
        for i, v in ipairs(session) do
            if i == 1 then
                oo:write(v .. "\n")
            else
                oo:write("File=" .. v .. "\n")
            end
        end
    end
    oo:close()
end

local function save_sessions(file)
    update_session()
    sessions_save(file)
end

local function save_hook()
    if o.auto_save then save_sessions() end
end
mp.register_event("shutdown", save_hook)

-- mpv use 0-based index
local function check_position(maintain_pos, pos)
    if maintain_pos == nil then maintain_pos = o.maintain_pos end
    if maintain_pos == 'yes' or maintain_pos == true then
        return pos
    elseif maintain_pos == 'no' or maintain_pos == false then
        return 0
    else
        maintain_pos = tonumber(maintain_pos)
        if maintain_pos == nil then
            if o.maintain_pos then
                return pos
            else
                return 0
            end
        else
            return maintain_pos - 1
        end
    end
end

-- session can be nil, which indicates empty session, in this way, will do nothing.
-- add the session playlist in current session, won't restart mpv process
local function session_attach(session_index, load_playlist, maintain_pos)
    local session = index_session(session_index)
    if session ~= nil and #session > 0 then
        update_session()
        msg.debug('session with', #session - 1, "videos")
        local playlist = {}
        local pos = 0
        for ii, v in ipairs(session) do
            if ii == 1 then
                pos = v
            else
                table.insert(playlist, v)
            end
        end
        load_playlist = check_bool(load_playlist, o.load_playlist)
        pos = check_position(maintain_pos, pos)
        if load_playlist then
            msg.debug('reloading playlist')
            for ii, v in ipairs(playlist) do
                if ii == 1 then
                    msg.debug('adding file:', v)
                    mp.commandv('loadfile', v)
                else
                    msg.debug('adding file:', v)
                    mp.commandv('loadfile', v, "append")
                end
            end
            if mp.get_property_number("playlist-pos") ~= pos then
                msg.debug('setting playlist-pos:', pos)
                mp.set_property('playlist-pos', pos)
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            mp.commandv('loadfile', playlist[pos + 1])
        end
        set_current_session(session_index)
    end
end

-- will start a new mpv process with the specified session playlist
-- session can be nil, which indicates empty session
-- @param disable_watch_later A bool, indicates whether to turn off watch later with --no-resume-playback
-- @param saving A bool, indicates whether to run save_sessions before loading the new session
local function session_load(session_index, disable_watch_later, saving, load_playlist, maintain_pos, args)
    update_session()
    mp.unregister_event(save_hook)
    mp.register_event("shutdown", function()
        if o.auto_save then sessions_save() end
    end)
    local session = index_session(session_index)
    local session_args = {
        o.mpv_bin,
        -- __by_loading__ as a hook, we can set cur_session in the new opened mpv process
        "--script-opts-append=" .. script_name .. "-__by_loading__=" .. session_index,
        "--volume=" .. mp.get_property("volume"),
    }
    if disable_watch_later then
        msg.debug("setting --no-resume-playback")
        table.insert(session_args, "--no-resume-playback")
    end

    if args ~= nil and #args > 0 then
        for _, v in ipairs(args) do
            msg.debug("setting", v)
            table.insert(session_args, v)
        end
    end
    if session ~= nil and #session > 0 then
        -- 0-based index
        local pos = check_position(maintain_pos, session[1])
        msg.debug('session with', #session - 1, "videos")
        load_playlist = check_bool(load_playlist, o.load_playlist)
        if load_playlist then
            for i, v in ipairs(session) do
                if i == 1 then
                    msg.debug('setting --playlist-start=' .. pos)
                    table.insert(session_args, "--playlist-start=" .. pos)
                else
                    msg.debug('adding file:', v)
                    table.insert(session_args, v)
                end
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            local file = session[pos + 1]
            msg.debug('starting file:', file)
            table.insert(session_args, file)
        end
    end

    msg.debug('quiting current session')
    mp.command("quit")
    msg.debug('starting new session')
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        detach = true,
        args = session_args,
    })
end

local function attach_session(i, load_playlist, maintain_pos)
    local session_index = check_session_index(tonumber(i))
    if session_index ~= nil then
        msg.debug("attaching session", session_index)
        session_attach(session_index, load_playlist, maintain_pos)
    end
end

local function load_session(i, disable_watch_later, saving, load_playlist, maintain_pos)
    local session_index = check_session_index(tonumber(i))
    if session_index ~= nil then
        msg.debug("loading session", session_index)
        disable_watch_later = check_bool(disable_watch_later, false)
        session_load(session_index, disable_watch_later, saving, load_playlist, maintain_pos)
    end
end

local function define_prev()
    local i = cur_session + 1
    if i > #sessions then
        mp.osd_message("no previous session")
        return nil
    end
    return i
end

local function define_next()
    local i = cur_session - 1
    if i <= 0 then
        mp.osd_message("no next session")
        return nil
    end
    return i
end

local function load_session_prev(disable_watch_later, saving, load_playlist, maintain_pos)
    local i = define_prev()
    if i then
        load_session(i, disable_watch_later, saving, load_playlist, maintain_pos)
    end
end

local function load_session_next(disable_watch_later, saving, load_playlist, maintain_pos)
    local i = define_next()
    if i then
        load_session(i, disable_watch_later, saving, load_playlist, maintain_pos)
    end
end

local function attach_session_prev(load_playlist, maintain_pos)
    local i = define_prev()
    if i then
        attach_session(i, load_playlist, maintain_pos)
    end
end

local function attach_session_next(load_playlist, maintain_pos)
    local i = define_next()
    if i then
        attach_session(i, load_playlist, maintain_pos)
    end
end

----- Restart mpv
local function restart_mpv(disable_watch_later, saving)
    local args, session_index
    if empty_session() then session_index = 0 else session_index = cur_session end
    if session_index > 0 then
        args = {}
        table.insert(args, "--start=" .. mp.get_property("time-pos"))
        table.insert(args, "--pause=" .. mp.get_property("pause"))
    else
        args = nil
    end
    disable_watch_later = check_bool(disable_watch_later, true)
    msg.debug("restarting")
    session_load(session_index, disable_watch_later, saving, true, true, args)
end

-- intializing session start by open mpv, prepare old_session and cur_session
local function initialize_open()
    msg.debug("reading current playlist")
    local session = read_current_session()
    -- intialize session by adding current session or reloading previous session
    if session ~= nil then
        msg.debug("initializing by adding current playlist")
        -- for session with playlist, add it into the first
        local function read_hook()
            if not o.allow_duplicated_session then
                local matches = match_session(session)
                for _, i in ipairs(matches) do
                    msg.debug('removing session', i, 'since duplication')
                    table.remove(sessions, i)
                end
            end
            if #sessions == o.max_sessions then
                msg.debug('removing last session')
                table.remove(sessions)
            end
            table.insert(sessions, 1, session)
            set_current_session(1)
            msg.debug("unregistering read_hook")
            mp.unregister_event(read_hook)
        end
        mp.register_event("file-loaded", read_hook)
        -- for empty session
    elseif o.auto_load then
        msg.debug("initializing by loading previous session")
        if not o.restore_empty and old_session == 0 then
            old_session = 1
        end
        if old_session > 0 then
            --Load the previous session if auto_load is enabled and the playlist is empty
            --the function is not called until the first property observation is triggered to let everything initialise
            --otherwise modifying playlist-start becomes unreliable
            local function load_hook()
                load_session(old_session, false, false)
                msg.debug("unregistering load_hook")
                mp.unobserve_property(load_hook)
            end
            mp.observe_property("idle", "string", load_hook)
        else
            set_current_session(0)
            msg.debug("nothing to do, since previous session is empty")
        end
    else
        msg.debug("initializing by loading previous session")
        set_current_session(0)
    end
end

local function initialize_load()
    msg.debug("intializing session created by `session_load`")
    local function session_load_set()
        local session_index = tonumber(o.__by_loading__)
        set_current_session(session_index) -- for session_load
    end
    if not empty_session() then
        local function session_load_hook()
            session_load_set()
            msg.debug("unregistering session_load_hook")
            mp.unregister_event(session_load_hook)
        end
        mp.register_event("file-loaded", session_load_hook)
    else
        local function session_load_hook()
            session_load_set()
            msg.debug("unregistering session_load_hook")
            mp.unobserve_property(session_load_hook)
        end
        mp.observe_property("idle", "string", session_load_hook)
    end
end

local function intializing()
    read_history_sessions()
    if o.__by_loading__ then
        initialize_load()
    else
        initialize_open()
    end
end

intializing()

-- define uosc menu ----------------------------------------
local function command(str)
    return string.format('script-message-to %s %s', script_name, str)
end

local function session_menu_add_file(menu, session, session_index)
    local active_position = mp.get_property_number("playlist-pos") + 1
    for position, v in ipairs(session) do
        -- the first one should be the orginal session start point, not the playlist
        position = position - 1
        if position > 0 then
            table.insert(menu, {
                title = string.match(tostring(v), "([^\\]+)$"),
                hint = tostring(position),
                active = session_index == cur_session and active_position == position,
                value = command("sessions-set-video " .. position .. " " .. session_index)
            })
        end
    end
end

local function sessions_menu()
    update_session()
    local menu = {
        type = 'sessions',
        title = 'Playlist',
        keep_open = true,
        items = {}
    }
    msg.debug('menu: reading', #sessions, 'sessions')
    -- add previous session playlist
    local prev_session_index = cur_session + 1
    local prev_session = index_session(prev_session_index)
    if prev_session ~= nil then
        msg.debug('adding previous session playlist from session', prev_session_index .. ",", #prev_session - 1, "files")
        local previous_sessions_menu = {}
        table.insert(menu.items, { title = "Previous Session", hint = "", items = previous_sessions_menu })
        local session_index = prev_session_index + 1
        local session = index_session(session_index)
        if session ~= nil then
            local history_menu = {}
            table.insert(previous_sessions_menu, { title = "History", hint = "", items = history_menu })
            while session ~= nil do
                local session_menu = {}
                table.insert(history_menu, { title = "Session " .. session_index, hint = "", items = session_menu })
                session_menu_add_file(session_menu, session, session_index)
                session_index = session_index + 1
                session = index_session(session_index)
            end
        end
        session_menu_add_file(previous_sessions_menu, prev_session, prev_session_index)
    end

    -- add next session playlist
    local next_session_index = cur_session - 1
    local next_session = index_session(next_session_index)
    if next_session ~= nil then
        msg.debug('adding next session playlist from session', next_session_index .. ",", #next_session - 1, "files")
        local next_sessions_menu = {}
        table.insert(menu.items, { title = "Next Session", hint = "", items = next_sessions_menu })
        local session_index = next_session_index - 1
        local session = index_session(session_index)
        if session ~= nil then
            local future_menu = {}
            table.insert(next_sessions_menu, { title = "Time machine", hint = "", items = future_menu, align = "right" })
            while session ~= nil do
                local session_menu = {}
                table.insert(future_menu, { title = "Session " .. session_index, hint = "", items = session_menu })
                session_menu_add_file(session_menu, session, session_index)
                session_index = session_index - 1
                session = index_session(session_index)
            end
        end
        session_menu_add_file(next_sessions_menu, next_session, next_session_index)
    end

    -- add current playlist
    msg.debug('adding current session playlist')
    local session = index_session(cur_session)
    if session then session_menu_add_file(menu.items, session, cur_session) end
    return menu
end

local function close_menu()
    mp.unregister_script_message("sessions-set-video")
    mp.commandv('script-message-to', 'uosc', 'close-menu', "sessions")
end

local function open_menu()
    mp.register_script_message('sessions-set-video', function(video_index, session_index)
        close_menu()
        session_index = tonumber(session_index)
        video_index = tonumber(video_index)
        if session_index == cur_session then
            -- mpv use 0-based index but sessions-script and lua use 1-based index
            mp.set_property('playlist-pos', video_index - 1)
        else
            if o.switch_action == "load" then
                session_load(session_index, false, true, true, video_index)
            else
                session_attach(session_index, true, video_index)
            end
        end
    end)
    local json = utils.format_json(sessions_menu())
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end

-- expose functions
mp.register_script_message('save-session', save_sessions)
mp.register_script_message('load-session', load_session)
mp.register_script_message('attach-session', attach_session)
mp.register_script_message('load-session-prev', load_session_prev)
mp.register_script_message('load-session-next', load_session_next)
mp.register_script_message('attach-session-prev', attach_session_prev)
mp.register_script_message('attach-session-next', attach_session_next)
mp.register_script_message("restart-mpv", restart_mpv)
mp.register_script_message('uosc-version', function(version)
    ---Like the comperator for table.sort, this returns v1 < v2
    ---Assumes two valid semver strings
    ---@param v1 string
    ---@param v2 string
    ---@return boolean
    local function semver_comp(v1, v2)
        local v1_iterator = v1:gmatch('%d+')
        local v2_iterator = v2:gmatch('%d+')
        for v2_num_str in v2_iterator do
            local v1_num_str = v1_iterator()
            if not v1_num_str then return true end
            local v1_num = tonumber(v1_num_str)
            local v2_num = tonumber(v2_num_str)
            if v1_num < v2_num then return true end
            if v1_num > v2_num then return false end
        end
        return false
    end
    local min_version = '4.6.0'
    local uosc_available = not semver_comp(version, min_version)
    if not uosc_available then return end
    mp.add_key_binding('h', 'sessions-open-menu', open_menu)
end)

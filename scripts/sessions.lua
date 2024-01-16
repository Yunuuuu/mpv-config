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
    script-message sessions-save [session-file]

    restart mpv process
    @param disable_watch_later A bool, indicates whether to turn off watch later with --no-resume-playback, default: "yes".
    @param saving A bool, indicates whether to run sessions_save before loading the new session
    script-message session-restart [disable_watch_later] [saving]

    session-load will start another mpv process
    @param disable_watch_later A bool, indicates whether to turn off watch later with --no-resume-playback, default: "no".
    @param saving A bool, indicates whether to run sessions_save before loading the new session
    @param load_playlist A bool, indicates whether to run load whole playlist, if false, the file specified in
           maintain_pos will be loaded. Default: use the script config option
    @param maintain_pos A bool or a number, indicates the start of the playlist, if true ("yes" can be okay),
           the original position will be used as the start point, if false ("no" will be the same), the first file
           of the playlist will be used as the start point. Default: use the script config option
    script-message session-load [session-index] [disable_watch_later] [saving] [load_playlist] [maintain_pos]
    script-message session-load-prev [disable_watch_later] [saving] [load_playlist] [maintain_pos]
    script-message session-load-next [disable_watch_later] [saving] [load_playlist] [maintain_pos]


    session-attach will attach the whole session playlist in current session, all setting will remain unchanged
    script-message session-attach [session-index] [load_playlist] [maintain_pos]
    script-message session-attach-prev [load_playlist] [maintain_pos]
    script-message session-attach-next [load_playlist] [maintain_pos]

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
    -- this occur if you quit manually with the `stop` command.
    restore_empty = true,

    -- the default action to switch video via uosc menu, "attach-session" (attach_session or attach)
    -- or "load-session" (load_session or load)
    switch_action = "attach",

    -- the default execution of mpv, usage for session_restart
    mpv_bin = "mpv",
}

-- prepare global variables ----------------------------
local script_name = mp.get_script_name()
local sessions = {}
local current_session = 0 -- 0 means empty session
-- last_valid_session should be the last non-empty session index
local last_valid_session = 1

-- utils function --------------------------------------
local function tointeger(x)
    return math.floor(tonumber(x) or error("provided must be a integer number"))
end

local function set_default(x, default)
    if x == "" or x == nil then
        if type(default) == "function" then
            return default(x)
        else
            return default
        end
    else
        return x
    end
end

local function check_bool(arg, default, name)
    if arg == 'yes' or arg == 'true' or arg == true then
        return true
    elseif arg == 'no' or arg == 'false' or arg == false then
        return false
    elseif arg == nil or arg == "" then
        return default
    else
        name = name or "Provided"
        error(name .. " must be a bool")
    end
end

local function empty_session()
    return mp.get_property_number('playlist-count', 0) == 0
end

-- user api, check user argument
local function use_index(i)
    i = tointeger(i)
    -- use index 0 to represent empty session
    if i == 0 then return i end
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
    if i > n or i < 0 then
        mp.osd_message('no session ' .. i)
        return nil
    end
    return i
end

-- return: A table of session index match provided session
local function match_session(session)
    local value = table.concat(session, ";")
    local out = {}
    for i, v in ipairs(sessions) do
        if table.concat(v, ";") == value then
            table.insert(out, i)
        end
    end
    return out
end

-- prepare arguments and set defaults ------------------------------
opt.read_options(o)

if o.switch_action == "session-load" or o.switch_action == "session_load" or o.switch_action == "load" then
    o.switch_action = "load"
else
    o.switch_action = "attach"
end

o.auto_save = check_bool(o.auto_save, true, "auto_save")
o.auto_load = check_bool(o.auto_load, true, "auto_load")
o.load_playlist = check_bool(o.load_playlist, true, "load_playlist")
o.max_sessions = set_default(o.max_sessions, 5)
o.max_sessions = tonumber(o.max_sessions)
o.allow_duplicated_session = check_bool(o.allow_duplicated_session, false, "allow_duplicated_session")
-- for the config file, maintain_pos can only be a bool
-- since it don't make sense to start every session with the same position
-- but we can directly pass a numeric argument in load_session or attach_session
o.maintain_pos = check_bool(o.maintain_pos, true, "maintain_pos")
o.restore_empty = check_bool(o.restore_empty, true, "restore_empty")
o.mpv_bin = set_default(o.mpv_bin, "mpv")

-- sets the default session file to the watch_later directory or ~~/watch_later/
o.session_file = set_default(o.session_file, function(_)
    local watch_later_dir = mp.get_property('watch-later-directory', "")
    if watch_later_dir == "" then watch_later_dir = "~~state/watch_later/" end
    if not watch_later_dir:find("[/\\]$") then watch_later_dir = watch_later_dir .. '/' end
    return watch_later_dir .. "mpv-sessions"
end)
o.session_file = mp.command_native({ "expand-path", o.session_file })

-- internal usage, as a flag indicating current session was run by `session_load`
o.__by_loading__ = mp.get_opt(script_name .. "-__by_loading__")
msg.debug("getting option __by_loading__:", o.__by_loading__)
o.__by_loading__ = set_default(o.__by_loading__, false)

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
    local session_index = oo:read()
    last_valid_session = tonumber(string.match(session_index, '^(%d+):%d+$')) or last_valid_session
    current_session = tonumber(string.match(session_index, '^%d+:(%d+)$')) or current_session

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
            session["pos"] = pos
            wait_position = false
        else
            local file_path = string.match(line, 'File=(.+)')
            msg.debug('adding file:', file_path)
            table.insert(session, file_path)
        end
    end
    msg.debug('imported', #sessions, 'sessions')
    oo:close()
end

-- Notes:
-- 1. We should always check if current session is empty (empty_session()) before reading current session
--    since we don't want to save empty session
-- 2. We use session index of 0 to indicate empty session
-- return: A table
local function read_current_session()
    local session = {}
    -- mpv uses 0 based array indices, but lua uses 1-based
    local working_directory = mp.get_property('working-directory')
    local playlist = mp.get_property_native('playlist')
    local pos = mp.get_property_number("playlist-pos")
    msg.debug('playlist position at', pos)
    session["pos"] = pos
    for _, v in ipairs(playlist) do
        msg.debug('adding', v.filename, 'to playlist')

        --if the file is available then it attempts to expand the path in-case of relative playlists
        --presumably if the file contains a protocol then it shouldn't be expanded
        if not v.filename:find("^%a*://") then
            msg.debug('expanded path:', v.filename)
            v.filename = utils.join_path(working_directory, v.filename)
        end
        table.insert(session, v.filename)
    end
    return session
end

local function set_session(index)
    msg.debug('updating session index:', index)
    if current_session ~= 0 then last_valid_session = current_session end
    current_session = index
    if index > 0 then
        local pos = mp.get_property_number("playlist-pos")
        msg.debug('updating playlist-pos:', pos)
        sessions[current_session]["pos"] = pos
    end
end

-- refresh current session, for empty session, update session index
-- 1. when exit: save_hook
-- 2. when switch session: attach_session, session_load
-- 3. when query uosc menu
local function refresh_session()
    if not empty_session() then
        msg.debug("refreshing current session", current_session)
        sessions[current_session] = read_current_session()
    else
        set_session(0)
    end
end

-- helper function to set `current_session` and display osd message
-- 1. when switching session: attach_session, initialize_load
-- 2. when open new windows: initialize_open
local function osd_session(index)
    mp.osd_message("Session " .. index .. "/" .. #sessions)
end

-- always remember to refresh current session before running `sessions_save`
local function save_sessions(file)
    file = set_default(file, o.session_file)
    local oo = io.open(file, 'w')
    if not oo then return msg.error("Failed to write to file", file) end
    msg.debug('saving sessions to', file)
    oo:write(last_valid_session .. ":" .. current_session .. "\n")
    for _, session in ipairs(sessions) do
        oo:write("[playlist]\n")
        oo:write(session["pos"] .. "\n")
        for _, v in ipairs(session) do
            oo:write("File=" .. v .. "\n")
        end
    end
    oo:close()
end

--@export
local function sessions_save(file)
    refresh_session()
    save_sessions(file)
end

local function save_hook() sessions_save() end

-- Notes for arguments:
-- maintain_pos: user api, 1-based index
-- pos: mpv api, 0-based index
local function check_position(maintain_pos, pos)
    if maintain_pos == nil then maintain_pos = o.maintain_pos end
    if maintain_pos == 'yes' or maintain_pos == 'true' or maintain_pos == true then
        return pos
    elseif maintain_pos == 'no' or maintain_pos == 'false' or maintain_pos == false then
        return 0
    else
        maintain_pos = tointeger(maintain_pos)
        return maintain_pos - 1
    end
end

-- session can be nil, which indicates empty session, in this way, will do nothing.
-- add the session playlist in current session, won't restart mpv process
local function attach_session(index, load_playlist, maintain_pos)
    refresh_session()
    local session = sessions[index]
    if session ~= nil then -- we don't allow blank session exist in global sessions
        msg.debug("attaching session with", #session, "videos")
        load_playlist = check_bool(load_playlist, o.load_playlist, "load_playlist")
        local pos = check_position(maintain_pos, session["pos"])
        if load_playlist then
            for i, v in ipairs(session) do
                if i == 1 then
                    msg.debug('adding file:', v)
                    mp.commandv('loadfile', v)
                else
                    msg.debug('adding file:', v)
                    mp.commandv('loadfile', v, "append")
                end
            end
            if mp.get_property_number("playlist-pos") ~= pos then
                msg.debug('setting playlist-pos:', pos)
                mp.set_property_number('playlist-pos', pos)
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            mp.commandv('loadfile', session[pos + 1])
        end
    else
        msg.debug("attaching empty session")
        mp.command("stop")
    end
    set_session(index)
    osd_session(index)
end

-- will start a new mpv process with the specified session playlist
-- session can be nil, which indicates empty session
-- @param disable_watch_later A bool, indicates whether to turn off watch later with --no-resume-playback
-- @param saving A bool, indicates whether to run `sessions_save` before loading the new session
local function load_session(index, disable_watch_later, saving, load_playlist, maintain_pos, args)
    refresh_session()
    if o.auto_save then mp.unregister_event(save_hook) end
    if check_bool(saving, o.auto_save, "saving") then
        mp.register_event("shutdown", function() save_sessions() end)
    end
    local session = sessions[index]
    local session_args = {
        o.mpv_bin,
        -- __by_loading__ as a hook, we can set current_session in the new opened mpv process
        "--script-opts-append=" .. script_name .. "-__by_loading__=" .. index,
        "--volume=" .. mp.get_property("volume"),
    }
    if disable_watch_later then
        msg.debug("setting --no-resume-playback")
        table.insert(session_args, "--no-resume-playback")
    end

    if args then
        for _, v in ipairs(args) do
            msg.debug("setting", v)
            table.insert(session_args, v)
        end
    end
    local loading_msg
    if session then
        local n = #session
        loading_msg = "loading session with " .. n .. " videos"
        msg.debug('session with', n, "videos")
        local pos = check_position(maintain_pos, session["pos"]) -- 0-based index
        load_playlist = check_bool(load_playlist, o.load_playlist, "load_playlist")
        if load_playlist then
            msg.debug('setting --playlist-start=' .. pos)
            table.insert(session_args, "--playlist-start=" .. pos)
            for _, v in ipairs(session) do
                msg.debug('adding file:', v)
                table.insert(session_args, v)
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            local file = session[pos + 1]
            msg.debug('starting file:', file)
            table.insert(session_args, file)
        end
    else
        loading_msg = "loading empty session"
    end

    msg.debug('quiting current session')
    mp.command("quit")
    msg.debug(loading_msg)
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        detach = true,
        args = session_args,
    })
end

-- intializing session start when openning a new mpv window, prepare `last_valid_session` and `current_session`
local function initialize_open()
    -- intialize session by adding current session or reloading previous session
    if not empty_session() then
        msg.debug("initializing by adding current playlist")
        -- for session with playlist, add it into the first
        -- the function is not called until the file-loaded completed to let everything initialise
        -- otherwise reading current playlist becomes unreliable
        local function read_hook()
            msg.debug("reading current playlist")
            local session = read_current_session()
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
            table.insert(sessions, session)
            set_session(#sessions)
            msg.debug("unregistering read_hook")
            mp.unregister_event(read_hook)
        end
        mp.register_event("file-loaded", read_hook)
        -- for empty session
    elseif o.auto_load then
        msg.debug("initializing by loading previous session")
        local index
        if not o.restore_empty and current_session == 0 then
            -- `last_valid_session` is the last non-empty session index
            index = last_valid_session
        else
            index = current_session
        end
        if index > 0 then
            -- Load the previous session if auto_load is enabled and the playlist is empty
            -- the function is not called until the first property observation is triggered to let everything initialise
            -- otherwise modifying playlist-start becomes unreliable
            local function load_hook()
                -- no need to save sessions
                load_session(index, false, false)
                msg.debug("unregistering load_hook")
                mp.unobserve_property(load_hook)
                index = nil
            end
            mp.observe_property("idle", "string", load_hook)
        else
            msg.debug("nothing to do, since previous session is empty")
            set_session(0)
            index = nil
        end
    else
        msg.debug("initializing by loading previous session")
        set_session(0)
    end
end

local function initialize_load()
    msg.debug("intializing session created by `session_load`")
    local function session_load_index()
        local index = tonumber(o.__by_loading__)
        set_session(index) -- for session_load
        osd_session(index)
    end
    if not empty_session() then
        local function session_load_hook()
            session_load_index()
            msg.debug("unregistering session_load_hook")
            mp.unregister_event(session_load_hook)
        end
        mp.register_event("file-loaded", session_load_hook)
    else
        local function session_load_hook()
            session_load_index()
            msg.debug("unregistering session_load_hook")
            mp.unobserve_property(session_load_hook)
        end
        mp.observe_property("idle", "string", session_load_hook)
    end
end

local function intializing()
    read_history_sessions()
    if o.auto_save then mp.register_event("shutdown", save_hook) end
    if o.__by_loading__ then
        initialize_load()
    else
        initialize_open()
    end
end

-- define uosc menu ----------------------------------------
local function command(str)
    return string.format('script-message-to %s %s', script_name, str)
end

local function menu_add_file(menu, session, session_index)
    local active_position = mp.get_property_number("playlist-pos") + 1
    local active = session_index == current_session
    for position, v in ipairs(session) do
        -- remove trailing / or \\ and keep the basename
        local basename = string.match(string.gsub(v, "[\\/]+$", ""), "([^\\/]+)$")
        table.insert(menu, {
            title = basename,
            hint = tostring(position),
            active = active and active_position == position,
            value = command("sessions-set-video " .. position .. " " .. session_index)
        })
    end
end

local function load_menu()
    local menu = {
        type = 'sessions',
        title = 'Playlist',
        keep_open = true,
        items = {}
    }
    msg.debug('menu: reading', #sessions, 'sessions')
    -- add previous session playlist
    local prev_index = current_session - 1
    local prev_session = sessions[prev_index]
    if prev_session then
        msg.debug('adding previous session playlist from session', prev_index .. ",", #prev_session, "files")
        local previous_sessions_menu = {}
        table.insert(menu.items, { title = "Previous Session", hint = "", items = previous_sessions_menu })
        local index = prev_index - 1
        local session = sessions[index]
        if session then
            local history_menu = {}
            table.insert(previous_sessions_menu, { title = "History", hint = "", items = history_menu })
            while session do
                local session_menu = {}
                table.insert(history_menu, { title = "Session " .. index, hint = "", items = session_menu })
                menu_add_file(session_menu, session, index)
                index = index - 1
                session = sessions[index]
            end
        end
        menu_add_file(previous_sessions_menu, prev_session, prev_index)
    end

    -- add next session playlist
    local next_index = current_session + 1
    local next_session = sessions[next_index]
    if next_session then
        msg.debug('adding next session playlist from session', next_index .. ",", #next_session, "files")
        local next_sessions_menu = {}
        table.insert(menu.items, { title = "Next Session", hint = "", items = next_sessions_menu })
        local index = next_index + 1
        local session = sessions[index]
        if session then
            local future_menu = {}
            table.insert(next_sessions_menu, { title = "Future History", hint = "", items = future_menu })
            while session do
                local session_menu = {}
                table.insert(future_menu, { title = "Session " .. index, hint = "", items = session_menu })
                menu_add_file(session_menu, session, index)
                index = index + 1
                session = sessions[index]
            end
        end
        menu_add_file(next_sessions_menu, next_session, next_index)
    end

    -- add current playlist
    msg.debug('adding current session playlist')
    local session = sessions[current_session]
    if session then menu_add_file(menu.items, session, current_session) end
    return menu
end

local function close_menu()
    mp.unregister_script_message("sessions-set-video")
    mp.commandv('script-message-to', 'uosc', 'close-menu', "sessions")
end

local function open_menu()
    mp.register_script_message('sessions-set-video', function(position, index)
        close_menu()
        index = tonumber(index)
        position = tonumber(position)
        if index == current_session then
            -- mpv use 0-based index but sessions-script and lua use 1-based index
            mp.set_property_number('playlist-pos', position - 1)
        else
            if o.switch_action == "load" then
                load_session(index, false, nil, true, position)
            else
                attach_session(index, true, position)
            end
        end
    end)
    -- always update current session data when open menu
    refresh_session()
    local json = utils.format_json(load_menu())
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end

-- function to export for users -----------------------------------------
local function define_prev()
    local index = current_session - 1
    if index <= 0 then
        mp.osd_message("no previous session")
        return nil
    end
    return index
end

local function define_next()
    local index = current_session + 1
    if index > #sessions then
        mp.osd_message("no next session")
        return nil
    end
    return index
end

local function session_attach(session_index, load_playlist, maintain_pos)
    local index = use_index(session_index)
    if index then
        attach_session(index, load_playlist, maintain_pos)
    end
end

local function session_load(session_index, disable_watch_later, saving, load_playlist, maintain_pos)
    local index = use_index(session_index)
    if index then
        disable_watch_later = check_bool(disable_watch_later, false, "disable_watch_later")
        load_session(index, disable_watch_later, saving, load_playlist, maintain_pos)
    end
end

local function session_load_prev(disable_watch_later, saving, load_playlist, maintain_pos)
    local index = define_prev()
    if index then
        disable_watch_later = check_bool(disable_watch_later, false, "disable_watch_later")
        load_session(index, disable_watch_later, saving, load_playlist, maintain_pos)
    end
end

local function session_load_next(disable_watch_later, saving, load_playlist, maintain_pos)
    local index = define_next()
    if index then
        disable_watch_later = check_bool(disable_watch_later, false, "disable_watch_later")
        load_session(index, disable_watch_later, saving, load_playlist, maintain_pos)
    end
end

local function session_attach_prev(load_playlist, maintain_pos)
    local index = define_prev()
    if index then
        attach_session(index, load_playlist, maintain_pos)
    end
end

local function session_attach_next(load_playlist, maintain_pos)
    local index = define_next()
    if index then
        attach_session(index, load_playlist, maintain_pos)
    end
end

----- Restart mpv
local function session_restart(disable_watch_later, saving)
    local args, index
    if empty_session() then index = 0 else index = current_session end
    if index > 0 then
        args = {}
        table.insert(args, "--start=" .. mp.get_property("time-pos"))
        table.insert(args, "--pause=" .. mp.get_property("pause"))
    else
        args = nil
    end
    disable_watch_later = check_bool(disable_watch_later, true, "disable_watch_later")
    msg.debug("restarting")
    load_session(index, disable_watch_later, saving, true, true, args)
end

-- intializing script -----------------------------------------
intializing()

-- expose functions -------------------------------------------
mp.register_script_message('sessions-save', sessions_save)
mp.register_script_message('session-load', session_load)
mp.register_script_message('session-attach', session_attach)
mp.register_script_message('session-load-prev', session_load_prev)
mp.register_script_message('session-load-next', session_load_next)
mp.register_script_message('session-attach-prev', session_attach_prev)
mp.register_script_message('session-attach-next', session_attach_next)
mp.register_script_message("session-restart", session_restart)
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

--[[
    This script automatically saves the current playlist and can reload it if the player is started in idle mode (specifically
    if there are 0 files in the playlist), or if the correct command is sent via script-messages.
    It remembers the playlist position the player was in when shutdown and reloads the playlist at that entry.
    This can be disabled with script-opts

    The script saves a text file containing the the full playlist of 10 sessions (can be changed by `max_sessions`) in the watch_later directory (changeable via opts)
    This file is saved in plaintext with the exact file paths of each playlist entry.
    Note that since it uses the same file, only the latest mpv window to be closed will be saved

    The script attempts to correct relative playlist paths using the utils.join_path function. I've tried to automatically
    detect when any non-files are loaded (if it has the sequence :// in the path), so that it'll work with URLs

    You can disable the automatic stuff and use script messages to load/save playlists as well

    save session in specified file, if nil, will use session_file in config file
    script-message save-session [session-file]
    script-message restart-mpv [watch-later: a bool indicate whether turn off watch-later using no-resume-playback, if no, will turn on no-resume-playback] [load_playlist] [maintain_pos]

    load-session will restart mpv all setting will be reload
    script-message load-session [session-index] [load_playlist] [maintain_pos]
    script-message load-session-prev [load_playlist] [maintain_pos]
    script-message load-session-next [load_playlist] [maintain_pos]

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
    max_sessions = 10,

    -- only keep the same session once (session with same playlist, list order matters)
    allow_duplicated_session = false,

    -- maintain position in the playlist, do nothing if load_playlist is disabled
    maintain_pos = true,

    -- if previous session is empty, but we do have history sessions, should the empty playlist be restored?
    -- this occur if you quit manually with quit / stop command.
    restore_empty = true,

    -- the default execution of mpv, usage for restart_mpv
    mpv_bin = "mpv",
}


-- prepare global variables ----------------------------
sessions = {}
cur_session = 0


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

local function print_session_index()
    mp.osd_message("Session " .. cur_session .. "/" .. #sessions)
end

local function check_session_index(i)
    -- if no sessions, nothing to do
    local n = #sessions
    if n == 0 then
        msg.debug("no history sessions")
        mp.osd_message("no history sessions")
        return nil
    end
    -- if session index must be smaller than n ang greater than 0
    if not i then
        mp.osd_message("Please provide the session index")
        msg.debug("Please provide the session index")
        return nil
    end
    if i > n or i <= 0 then
        msg.debug('no session', i)
        mp.osd_message('no session ' .. i)
        return nil
    end
    return i
end

local function index_session(i)
    i = check_session_index(i)
    if not i then
        return nil
    else
        return sessions[i]
    end
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
-- internal usage, as a flag indicating current session was run by `session_load`
o.__by_loading__ = "no"
opt.read_options(o)

o.max_sessions = set_default(o.max_sessions, 10)
o.max_sessions = tonumber(o.max_sessions)
o.allow_duplicated_session = check_bool(o.allow_duplicated_session, false)
o.restore_empty = check_bool(o.restore_empty, true)
o.auto_load = check_bool(o.auto_load, true)
o.auto_save = check_bool(o.auto_save, true)
o.mpv_bin = set_default(o.mpv_bin, "mpv")
o.__by_loading__ = check_bool(o.__by_loading__, false)

-- sets the default session file to the watch_later directory or ~~/watch_later/
if o.session_file == "" or o.session_file == nil then
    local watch_later_dir = mp.get_property('watch-later-directory', "")
    if watch_later_dir == "" then watch_later_dir = "~~state/watch_later/" end
    if not watch_later_dir:find("[/\\]$") then watch_later_dir = watch_later_dir .. '/' end
    o.session_file = watch_later_dir .. "mpv-sessions"
end

o.session_file = mp.command_native({ "expand-path", o.session_file })

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
    cur_session = tonumber(string.match(oo:read(), '^SessionIndex=(%d+)$')) or 0
    msg.debug('setting session index:', cur_session)

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
    local pos = mp.get_property('playlist-pos')
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

local function save_sessions(file)
    file = set_default(file, o.session_file)
    msg.debug('saving current session to', file)
    local oo = io.open(file, 'w')
    if not oo then return msg.error("Failed to write to file", file) end
    if o.restore_empty and empty_session() then
        oo:write("SessionIndex=" .. 0 .. "\n")
    else
        oo:write("SessionIndex=" .. cur_session .. "\n")
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

-- session can be nil, which indicates empty session, in this way, will do nothing.
-- add the session playlist in current session, won't restart mpv process
local function session_attach(session, load_playlist, maintain_pos)
    if session ~= nil and #session > 0 then
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
            maintain_pos = check_bool(maintain_pos, o.maintain_pos)
            if maintain_pos then
                -- restore the original value unless the `playlist-start` property has been otherwise modified
                if mp.get_property_number('playlist-start') ~= pos then
                    msg.debug('setting playlist-start:', pos)
                    mp.set_property('playlist-start', pos)
                end
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            mp.commandv('loadfile', playlist[pos + 1])
        end
    end
end

-- will start a new mpv process with the specified session playlist
-- session can be nil, which indicates empty session
local function session_load(session, watch_later, load_playlist, maintain_pos, args)
    local session_args = {
        o.mpv_bin,
        "--script-opts-append=" .. mp.get_script_name() .. "-__by_loading__=yes",
        "--volume=" .. mp.get_property("volume"),
    }
    watch_later = check_bool(watch_later, false)
    if not watch_later then
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
        msg.debug('session with', #session - 1, "videos")
        load_playlist = check_bool(load_playlist, o.load_playlist)
        if load_playlist then
            maintain_pos = check_bool(maintain_pos, o.maintain_pos)
            for i, v in ipairs(session) do
                if i == 1 and maintain_pos then
                    msg.debug('setting --playlist-start=' .. v)
                    table.insert(session_args, "--playlist-start=" .. v)
                else
                    msg.debug('adding file:', v)
                    table.insert(session_args, v)
                end
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            local file = session[session[1] + 1]
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
    local session = index_session(i)
    if session ~= nil then
        msg.debug("attaching session", i)
        session_attach(session, load_playlist, maintain_pos)
        msg.debug('Setting current session index into', i)
        cur_session = i
        print_session_index()
    end
end

local function load_session(i, load_playlist, maintain_pos)
    local session = index_session(i)
    if session ~= nil then
        msg.debug("loading session", i)
        session_load(session, true, load_playlist, maintain_pos)
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

local function load_session_prev(load_playlist, maintain_pos)
    local i = define_prev()
    if i then
        load_session(i, load_playlist, maintain_pos)
    end
end

local function load_session_next(load_playlist, maintain_pos)
    local i = define_next()
    if i then
        load_session(i, load_playlist, maintain_pos)
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
local function restart_mpv(watch_later, load_playlist, maintain_pos)
    msg.debug("reading current session")
    local session = read_current_session()
    msg.debug("restarting")
    local args
    if session ~= nil then
        args = {}
        table.insert(args, "--start=" .. mp.get_property("time-pos"))
        table.insert(args, "--pause=" .. mp.get_property("pause"))
    else
        args = nil
    end
    session_load(session, watch_later, load_playlist, maintain_pos, args)
end

read_history_sessions()

if not o.__by_loading__ then
    -- intialize session by adding current session or reloading previous session
    if not empty_session() then
        -- if current playlist is not from load_session, add it into the first
        msg.debug("reading current playlist")
        local function read_hook()
            local session = read_current_session()
            if session ~= nil then
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
                cur_session = 1
            end
            msg.debug("unregistering read_hook")
            mp.unregister_event(read_hook)
        end
        mp.register_event("file-loaded", read_hook)
    elseif o.auto_load then
        msg.debug("loading previous session")
        if not o.restore_empty and cur_session == 0 then
            cur_session = 1
        end
        if cur_session > 0 then
            --Load the previous session if auto_load is enabled and the playlist is empty
            --the function is not called until the first property observation is triggered to let everything initialise
            --otherwise modifying playlist-start becomes unreliable
            local function load_hook()
                load_session(cur_session)
                msg.debug("unregistering load_hook")
                mp.unobserve_property(load_hook)
            end
            mp.observe_property("idle", "string", load_hook)
        else
            msg.debug("nothing to do, since previous session is empty")
        end
    end
else
    msg.debug("found session created by `session_load`, skip intializing")
end

mp.register_event('shutdown', function()
    if o.auto_save then
        save_sessions()
    end
end)

mp.register_script_message('save-session', save_sessions)
mp.register_script_message('load-session', load_session)
mp.register_script_message('attach-session', attach_session)
mp.register_script_message('load-session-prev', load_session_prev)
mp.register_script_message('load-session-next', load_session_next)
mp.register_script_message('attach-session-prev', attach_session_prev)
mp.register_script_message('attach-session-next', attach_session_next)
mp.register_script_message("restart-mpv", restart_mpv)

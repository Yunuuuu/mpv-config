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

    --maintain position in the playlist
    --does nothing if load_playlist is disabled
    maintain_pos = true,

    -- the default execution of mpv, usage for restart_mpv
    mpv_bin = "mpv",
}

opt.read_options(o)

--sets the default session file to the watch_later directory or ~~/watch_later/
if o.session_file == "" then
    local watch_later = mp.get_property('watch-later-directory', "")
    if watch_later == "" then watch_later = "~~state/watch_later/" end
    if not watch_later:find("[/\\]$") then watch_later = watch_later .. '/' end

    o.session_file = watch_later .. "mpv-sessions"
end

o.max_sessions = tonumber(o.max_sessions)
o.session_file = mp.command_native({ "expand-path", o.session_file })
sessions = {}
cur_session = 0

local function check_bool(arg, default)
    if arg == 'yes' or arg == true then
        arg = true
    elseif arg == 'no' or arg == false then
        arg = false
    else
        arg = default
    end
    return arg
end

local function print_session_index()
    mp.osd_message("Session index " .. cur_session .. "/" .. #sessions)
end

--turns the json string into a table and adds all the files to the playlist
local function read_sessions(file)
    if not file or file == '' then file = o.session_file end
    --loads the session file
    msg.debug('loading previous session from', file)
    local oo = io.open(file, "r")

    --this should only occur when loading the script for the first time,
    --or if someone manually deletes the previous session file
    if not oo then
        msg.debug('no session, cancelling load')
        return
    end

    local playlist
    local idx = 1
    for line in oo:lines() do
        msg.debug('Debugging line: ' .. line)
        if line == "[playlist]" then
            if #sessions == o.max_sessions then
                msg.debug('excessive sessions')
                break
            end
            idx = 1
        elseif idx == 1 then
            -- the first one should be the position of current playlist
            local pos = tonumber(line)
            msg.debug('adding one session ...')
            playlist = {}
            table.insert(playlist, pos)
            table.insert(sessions, playlist)
            idx = idx + 1
        else
            table.insert(playlist, string.match(line, 'File=(.+)'))
        end
    end
    msg.debug('reading ' .. #sessions .. ' sessions')
    if oo then oo:close() end
end

local function read_playlist()
    local session = {}
    -- mpv uses 0 based array indices, but lua uses 1-based
    local working_directory = mp.get_property('working-directory')
    local playlist = mp.get_property_native('playlist')
    local pos = mp.get_property('playlist-pos')
    if pos == -1 then
        pos = mp.get_property('playlist-playing-pos')
    end
    msg.debug('playlist position ' .. pos)
    table.insert(session, pos)
    for _, v in ipairs(playlist) do
        msg.debug('adding ' .. v.filename .. ' to playlist')

        --if the file is available then it attempts to expand the path in-case of relative playlists
        --presumably if the file contains a protocol then it shouldn't be expanded
        if not v.filename:find("^%a*://") then
            v.filename = utils.join_path(working_directory, v.filename)
            msg.debug('expanded path: ' .. v.filename)
        end
        table.insert(session, v.filename)
    end
    return session
end


local function save_sessions(file)
    if not file then file = o.session_file end
    msg.debug('saving current session to', file)
    local oo = io.open(file, 'w')
    if not oo then return msg.error("Failed to write to file", file) end

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

local function start_session(session, watch_later, time_pos, load_playlist, maintain_pos)
    local session_args = {
        o.mpv_bin,
        "--pause=" .. mp.get_property("pause"),
        "--volume=" .. mp.get_property("volume"),
    }
    watch_later = check_bool(watch_later, false)
    if not watch_later then
        table.insert(session_args, "--no-resume-playback")
    end
    msg.debug('session with ' .. #session - 1 .. " videos")
    if #session > 0 then
        if time_pos ~= nil then
            msg.debug('setting video start: ' .. time_pos)
            table.insert(session_args, "--start=" .. time_pos)
        end

        load_playlist = check_bool(load_playlist, o.load_playlist)
        if load_playlist then
            maintain_pos = check_bool(maintain_pos, o.maintain_pos)
            for i, v in ipairs(session) do
                if i == 1 and maintain_pos then
                    msg.debug('setting playlist-start: ' .. v)
                    table.insert(session_args, "--playlist-start=" .. v)
                else
                    msg.debug('add file: ' .. v)
                    table.insert(session_args, v)
                end
            end
        else
            table.insert(session_args, session[session[1] + 1])
        end
    end
    msg.debug('starting new session')
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        detach = true,
        args = session_args,
    })
    msg.debug('quiting')
    mp.command("quit")
end


local function check_i(i)
    if not i then
        mp.osd_message("Please provide the session index")
        msg.debug("Please provide the session index")
        return nil
    end
    -- if no sessions, nothing to do
    local n = #sessions
    if n == 0 then
        msg.debug("no history sessions")
        mp.osd_message("no history sessions")
        return nil
    end
    -- if session index must be smaller than n
    if i > n or i <= 0 then
        msg.debug('no session ' .. i)
        mp.osd_message('no session ' .. i)
        return nil
    end
    return i
end


-- attach a session and don't restart mpv
local function attach_session(i, load_playlist, maintain_pos)
    i = check_i(i)
    if i then
        msg.debug("attaching session " .. i)
        local session = {}
        local pos = 0
        for ii, v in ipairs(sessions[i]) do
            if ii == 1 then
                pos = v
            else
                table.insert(session, v)
            end
        end

        load_playlist = check_bool(load_playlist, o.load_playlist)
        if load_playlist then
            msg.debug('reloading playlist')
            for ii, v in ipairs(session) do
                if ii == 1 then
                    msg.debug('adding file: ' .. v)
                    mp.commandv('loadfile', v)
                else
                    msg.debug('adding file: ' .. v)
                    mp.commandv('loadfile', "append", v)
                end
            end
            maintain_pos = check_bool(maintain_pos, o.maintain_pos)
            if maintain_pos then
                -- restore the original value unless the `playlist-start` property has been otherwise modified
                if mp.get_property_number('playlist-start') ~= pos then
                    msg.debug('setting playlist-start: ' .. pos)
                    mp.set_property('playlist-start', pos)
                end
            end
        else
            -- mpv uses 0 based array indices, but lua uses 1-based
            mp.commandv('loadfile', session[pos])
        end
        msg.debug('Setting current session index into ' .. i)
        cur_session = i
        print_session_index()
    end
end

local function load_session(i, load_playlist, maintain_pos)
    i = check_i(i)
    if i then
        msg.debug("loading session " .. i)
        start_session(sessions[i], true, nil, load_playlist, maintain_pos)
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
    local session = read_playlist()
    msg.debug("restarting...")
    start_session(session, watch_later, mp.get_property("time-pos"), load_playlist, maintain_pos)
end

read_sessions()

o.allow_duplicated_session = check_bool(o.allow_duplicated_session, false)
o.auto_load = check_bool(o.auto_load, true)
o.auto_save = check_bool(o.auto_save, true)

if mp.get_property_number('playlist-count', 0) > 0 then
    -- if current playlist is not from sessions, add it into the first
    if cur_session == 0 then
        msg.debug("reading current playlist...")
        local function read_hook()
            local session = read_playlist()
            -- check duplciates
            local value = table.concat(session, ";", 2)
            if not o.allow_duplicated_session then
                for i, v in ipairs(sessions) do
                    if table.concat(v, ";", 2) == value then
                        msg.debug('removing session ' .. i .. ' since duplication')
                        table.remove(sessions, i)
                    end
                end
            end
            -- insert current playlist
            if #sessions == o.max_sessions then
                msg.debug('removing last session')
                table.remove(sessions)
            end
            table.insert(sessions, 1, session)
            cur_session = 1
            msg.debug("unregistering read_hook")
            mp.unregister_event(read_hook)
        end
        mp.register_event("file-loaded", read_hook)
    end
elseif o.auto_load then
    msg.debug("loading previous session...")
    --Load the previous session if auto_load is enabled and the playlist is empty
    --the function is not called until the first property observation is triggered to let everything initialise
    --otherwise modifying playlist-start becomes unreliable
    local function load_hook()
        load_session(1)
        msg.debug("unregistering load_hook")
        mp.unobserve_property(load_hook)
    end
    mp.observe_property("idle", "string", load_hook)
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

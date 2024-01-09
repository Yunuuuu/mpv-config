-- https://www.reddit.com/r/mpv/comments/weapx1/how_to_replay_video_with_spacebar_after_video/
function pause_replay()
    if mp.get_property_native("pause") == true then
	    if mp.get_property("eof-reached") == "yes" then
		    mp.command("seek 0 absolute-percent")
	    end
	    mp.set_property("pause", "no")
    else
	    mp.set_property("pause", "yes")
    end
end

mp.add_key_binding(nil, "pause-replay", pause_replay)

-- source get from: https://github.com/mpv-player/mpv/issues/3869#issuecomment-264771991
-- Rotates the video while maintaining 0 <= prop < 360
function add_video_rotate(amt)
	-- Ensure that amount is a base 10 integer.
	amt = tonumber(amt, 10)
	if amt == nil then
		mp.osd_message("Rotate: Invalid rotation amount")
		return nil -- abort
	end
	-- Calculate what the next rotation value should be,
	-- and wrap value to correct range (0 (aka 360) to 359).
	local rot = mp.get_property_number("video-rotate")
	rot = ( rot + amt ) % 360
	-- Change rotation and tell the user.
	mp.set_property_number("video-rotate", rot)
	mp.osd_message("Rotate: " .. rot)
end

mp.add_key_binding(nil, "add-video-rotate", add_video_rotate)

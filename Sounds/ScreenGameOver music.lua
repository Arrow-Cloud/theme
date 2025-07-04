local audio_file = "fold.ogg"

local style = ThemePrefs.Get("VisualStyle")
if style == "SRPG9" then
	audio_file = "SRPG9-GameOver.ogg"
end

return THEME:GetPathS("", audio_file)

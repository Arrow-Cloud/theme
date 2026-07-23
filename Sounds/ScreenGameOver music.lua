local audio_file = "fold.ogg"

local style = ThemePrefs.Get("VisualStyle")
if style == "SRPG10" then
	audio_file = "SRPG10-GameOver.ogg"
elseif style == "Transistor" then
	audio_file = "paper boats.ogg"
end

return THEME:GetPathS("", audio_file)

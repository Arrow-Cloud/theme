-- This handles user input while in the Arrow Cloud Leaderboard overlay.
local function input(event)
	if not (event and event.PlayerNumber and event.button) then
		return false
	end
	-- Don't handle input for a non-joined player.
	if not GAMESTATE:IsSideJoined(event.PlayerNumber) then
		return false
	end

	SOUND:StopMusic()

	local screen   = SCREENMAN:GetTopScreen()
	local overlay  = screen:GetChild("Overlay")

	-- Broadcast event data using MESSAGEMAN for the ACLeaderboard overlay to listen for.
	if event.type ~= "InputEventType_Repeat" then
		MESSAGEMAN:Broadcast("ACLeaderboardInputEvent", event)
	end

	-- Pressing Start or Back will dismiss the overlay.
	if (event.GameButton == "Start" or event.GameButton == "Back") and event.type ~= "InputEventType_Release" then
		overlay:queuecommand("DirectInputToEngine")
	end

	return false
end

return input
